import SwiftUI
import PhotosUI
import UIKit
import KBGeometry

/// Tema düzenleyici — tasarım tuvali "BestKeyboard Temaları › Tema
/// düzenleyici" ile aynı bölümler: hazır temadan başla, arka plan (renk /
/// gradyan / fotoğraf + karartma), harf tuşları (renk, opaklık, yazı),
/// işlev tuşları ve Enter, biçim (köşe, kenarlık, gölge). Üstteki klavye
/// her değişiklikte canlı güncelleniyor.
struct ThemeEditorView: View {
    let model: KeyboardSettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var spec: ThemeSpec
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var mode: Mode

    enum Mode: String, CaseIterable { case solid = "Renk", gradient = "Gradyan", photo = "Fotoğraf" }

    init(model: KeyboardSettingsModel, editing: ThemeSpec? = nil) {
        self.model = model
        var s = editing ?? ThemeSpec.preset(id: "manzara")!
        // Fotoğraf kimlik değişmeden yükleniyor: yeni taslağın kimliği
        // `custom-` ve özel klasörde henüz dosyası yok.
        _photo = State(initialValue: Self.image(for: s))
        if editing == nil { s.id = ThemeSpec.newCustomID(); s.name = "Benim temam" }
        _spec = State(initialValue: s)
        switch s.background {
        case .solid: _mode = State(initialValue: .solid)
        case .gradient: _mode = State(initialValue: .gradient)
        case .photo: _mode = State(initialValue: .photo)
        }
    }

    private static func image(for s: ThemeSpec) -> UIImage? {
        guard case let .photo(file, _) = s.background else { return nil }
        return s.isCustom ? CustomThemeStore.image(file) : ThemeSpec.bundleImage(file)
    }

    private var resolved: KeyboardTheme { spec.resolved(loadImage: { _ in photo }) }

    // Tasarımdaki paletler.
    private let bgColors = ["#D1D3D9", "#1E1F22", "#000000", "#1B3326", "#E3DDF4", "#E7DCCB", "#34373C", "#0B2545"]
    /// Fotoğraf dosyasının yer tutucu adı (kayıtta gerçek adla değişiyor) ve varsayılan karartma.
    private static let photoFile = "photo"
    private static let defaultDim = 0.25
    private let gradients: [(String, String)] = [("#0B3D6B", "#0E6E8C"), ("#FF8A5B", "#E5487A"), ("#141E30", "#243B55"),
                                                 ("#1F7A6D", "#2A9D8F"), ("#3A1C71", "#6A3093"), ("#FFD3A5", "#FD6585")]
    private let keyColors = ["#FFFFFF", "#4A4B50", "#1C1C1E", "#2E5240", "#FBF7F0", "#575B62", "#FFD60A", "#0A66D6"]
    private let fnColors = ["#ADB3BC", "#2F3034", "#0E0E10", "#142A1F", "#C7BDE6", "#D3C3AA", "#FFFFFF", "#000000"]
    private let accents = ["#0A66D6", "#2F7DF6", "#FF9F0A", "#3FD0C9", "#7BD389", "#5B3FD0", "#E5487A", "#FFB38A"]

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(settings: model.settings, themeOverride: resolved)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Tema adı", text: $spec.name)
                        .font(.headline)
                        .padding(12).background(BK.card, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 8) {
                        BKSectionTitle(text: "Hazır temadan başla", color: BK.sub)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ThemeSpec.presets, id: \.id) { p in
                                    Button(p.name) { start(from: p) }
                                        .font(.subheadline)
                                        .padding(.horizontal, 14).frame(height: 36)
                                        .background(BK.card, in: Capsule())
                                        .overlay(Capsule().strokeBorder(BK.line))
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    BKCard {
                        Text("Arka plan").font(.headline)
                        Picker("Arka plan", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { _, m in applyMode(m) }
                        switch mode {
                        case .solid:
                            swatches(bgColors, selected: solidColor) { c in spec.background = .solid(c) }
                        case .gradient:
                            HStack(spacing: 10) {
                                ForEach(Array(gradients.enumerated()), id: \.offset) { _, g in
                                    let on = gradientPair == g.0 + g.1
                                    Button { spec.background = .gradient(g.0, g.1) } label: {
                                        LinearGradient(colors: [Color(UIColor(hex: g.0)), Color(UIColor(hex: g.1))],
                                                       startPoint: .top, endPoint: .bottom)
                                            .frame(width: 46, height: 34)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? BK.accent : .clear, lineWidth: 3))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        case .photo:
                            HStack(spacing: 12) {
                                Group {
                                    if let photo { Image(uiImage: photo).resizable().scaledToFill() }
                                    else { BK.line }
                                }
                                .frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    Text("Fotoğraf seç").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 14).frame(height: 36)
                                        .background(BK.accent, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            BKSliderRow(title: "Karartma", value: SettingsFormat.percent(dim), tint: BK.accent,
                                        x: Binding(get: { dim }, set: { spec.background = .photo(file: Self.photoFile, dim: $0) }),
                                        range: 0...0.7, step: 0.01)
                        }
                    }

                    BKCard {
                        Text("Harf tuşları").font(.headline)
                        swatches(keyColors, selected: spec.key) { spec.key = $0 }
                        BKSliderRow(title: "Opaklık", value: SettingsFormat.percent(spec.keyAlpha), tint: BK.accent,
                                    x: $spec.keyAlpha, range: 0.1...1, step: 0.01)
                        HStack {
                            Text("Yazı rengi").font(.body.weight(.semibold))
                            Spacer()
                            Picker("Yazı rengi", selection: Binding(get: { spec.isDark }, set: setTextLight)) {
                                Text("Koyu").tag(false); Text("Açık").tag(true)
                            }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }

                    BKCard {
                        Text("İşlev tuşları").font(.headline)
                        swatches(fnColors, selected: spec.function) { spec.function = $0 }
                        Text("Enter (⏎) rengi").font(.body.weight(.semibold))
                        swatches(accents, selected: spec.accent) { c in
                            spec.accent = c
                            spec.accentText = Self.luminance(c) > 0.35 ? ThemeSpec.darkText : ThemeSpec.lightText
                        }
                    }

                    BKCard {
                        Text("Biçim").font(.headline)
                        BKSliderRow(title: "Köşe yuvarlaklığı", value: "\(Int(spec.cornerRadius)) pt", tint: BK.accent,
                                    x: $spec.cornerRadius, range: 0...16, step: 1)
                        Toggle("Tuş kenarlığı", isOn: $spec.border).tint(BK.accent)
                        Toggle("Tuş gölgesi", isOn: $spec.shadow).tint(BK.accent)
                    }

                    // Tasarım 25: tuş yazı tipi + kalınlık.
                    BKCard(padding: 16) {
                        BKSectionTitle(text: "Tuş yazı tipi", color: BK.accent)
                        ForEach(Self.keyFonts, id: \.0) { id, title, design in
                            Button { spec.keyFont = id } label: {
                                HStack(spacing: 12) {
                                    Text("Aa").font(.system(size: 19, design: design))
                                        .frame(width: 52, height: 40)
                                        .background(BK.ground, in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(title).font(.body.weight(.semibold))
                                        Text("ç ğ ı ö ş ü · 123").font(.system(size: 12, design: design)).foregroundStyle(BK.sub)
                                    }
                                    Spacer()
                                    Image(systemName: spec.keyFont == id ? "largecircle.fill.circle" : "circle")
                                        .font(.title3).foregroundStyle(spec.keyFont == id ? BK.accent : BK.sub)
                                }
                                .frame(minHeight: 56).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(spec.keyFont == id ? .isSelected : [])
                        }
                        BKFieldLabel("Kalınlık")
                        Picker("Kalınlık", selection: Binding(get: { spec.keyWeight ?? "regular" },
                                                             set: { spec.keyWeight = $0 == "regular" ? nil : $0 })) {
                            Text("İnce").tag("light")
                            Text("Normal").tag("regular")
                            Text("Kalın").tag("bold")
                        }
                        .pickerStyle(.segmented)
                        Text("Yalnız tuşların üstündeki harfler değişir; mesajı stilli göndermek için klavyede “Aa”.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    }

                    if spec.isCustom, CustomThemeStore.load().contains(where: { $0.id == spec.id }) {
                        Button("Bu temayı sil", role: .destructive) {
                            CustomThemeStore.remove(id: spec.id)
                            if model.theme.rawValue == spec.id { model.theme = .system }
                            dismiss()
                        }
                        .buttonStyle(.bkCard(BK.pink.ink))
                    }
                }
                .padding(16)
            }
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Tema düzenle")
        #if DEBUG
        .onAppear {
            // `-temaFont rounded`: tasarım 25'i ekran görüntüsüyle karşılaştırmak için.
            if let font = LaunchArgs.value("-temaFont") { spec.keyFont = font; spec.keyWeight = "bold" }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Kaydet") { save() }.font(.body.weight(.bold))
            }
        }
        .onChange(of: photoItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                photo = img
                spec.background = .photo(file: Self.photoFile, dim: dim)
            }
        }
    }

    // MARK: - Durum

    private static let keyFonts: [(String?, String, Font.Design)] = [
        (nil, "Sistem", .default), ("rounded", "Yuvarlak", .rounded), ("serif", "Klasik", .serif),
        ("mono", "Daktilo", .monospaced), ("condensed", "Dar", .default),
    ]

    private var solidColor: String { if case let .solid(c) = spec.background { return c }; return "" }
    private var gradientPair: String { if case let .gradient(a, b) = spec.background { return a + b }; return "" }
    private var dim: Double { if case let .photo(_, d) = spec.background { return d }; return Self.defaultDim }

    private func applyMode(_ m: Mode) {
        switch m {
        case .solid: if case .solid = spec.background {} else { spec.background = .solid(bgColors[1]) }
        case .gradient: if case .gradient = spec.background {} else { spec.background = .gradient(gradients[0].0, gradients[0].1) }
        case .photo: if case .photo = spec.background {} else { spec.background = .photo(file: Self.photoFile, dim: Self.defaultDim) }
        }
    }

    private func start(from p: ThemeSpec) {
        let id = spec.id, name = spec.name
        spec = p
        spec.id = id; spec.name = name
        photo = Self.image(for: p)
        switch p.background {
        case .solid: mode = .solid
        case .gradient: mode = .gradient
        case .photo: mode = .photo
        }
    }

    private func setTextLight(_ light: Bool) {
        spec.isDark = light
        spec.keyText = light ? ThemeSpec.lightText : ThemeSpec.darkText
        spec.functionText = light ? ThemeSpec.lightText : ThemeSpec.darkText
    }

    private func save() {
        if case let .photo(_, d) = spec.background {
            if let photo, let file = CustomThemeStore.writePhoto(photo, for: spec.id) {
                spec.background = .photo(file: file, dim: d)
            } else {
                spec.background = .solid(bgColors[1])
            }
        }
        CustomThemeStore.upsert(spec)
        model.theme = ThemeChoice(rawValue: spec.id)
        dismiss()
    }

    private func swatches(_ list: [String], selected: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(list, id: \.self) { c in
                let on = c.uppercased() == selected.uppercased()   // onaltılık renk kodu
                Button { pick(c) } label: {
                    Circle().fill(Color(UIColor(hex: c)))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
                        .overlay(Circle().strokeBorder(on ? BK.accent : .clear, lineWidth: 3).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    static func luminance(_ hex: String) -> Double {
        let c = UIColor(hex: hex)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }
}
