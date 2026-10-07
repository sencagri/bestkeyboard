import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

// Ana uygulamanın ekranları — tasarım tuvali "BestKeyboard Uygulama
// Ekranları" ile birebir. Her bölümün kendi rengi var (tema pembe, düzen
// turkuaz, silme turuncu, öğrenme yeşil, ses mavi); gri yerine gruplanmış
// beyaz kartlar.

// MARK: - Stil

/// Değer satırı: etiket solda, renkli değer sağda, altında kaydırıcı ve ipucu.
extension BKSliderRow {
    /// Ortak tanımdan (`SettingsSliders`): başlık, aralık, adım ve biçim tek yerde.
    init(_ spec: SliderSpec, tint: Color, x: Binding<Double>, hint: String? = nil, ends: (String, String)? = nil) {
        self.init(title: spec.title, value: spec.format(x.wrappedValue), tint: tint, x: x,
                  range: spec.range, step: spec.step, hint: hint, ends: ends)
    }
}

struct BKSliderRow: View {
    let title: String
    let value: String
    let tint: Color
    @Binding var x: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var hint: String? = nil
    var ends: (String, String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.weight(.bold)).foregroundStyle(tint).monospacedDigit()
            }
            Slider(value: $x, in: range, step: step).tint(tint)
                .accessibilityLabel(title).accessibilityValue(value)
            if let ends {
                HStack { Text(ends.0); Spacer(); Text(ends.1) }.font(.caption).foregroundStyle(BK.sub)
            }
            if let hint { Text(hint).font(.footnote).foregroundStyle(BK.sub) }
        }
        .padding(.vertical, 6)
    }
}

/// Uygulama ayarları henüz klavyeye ulaşamıyorsa söyleyen şerit.
struct SharedStoreNotice: View {
    var body: some View {
        if !KeyboardSettingsStore.isShared {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(BK.orange.ink)
                Text("Buradaki değişiklikler şimdilik yalnız önizlemeyi etkiliyor; klavyede ⚙︎'den aynı ayarlar var. Uygulama ile klavye bağlanınca buradan yönetilecek.")
                    .font(.footnote).foregroundStyle(BK.ink)
            }
            .padding(12)
            .background(BK.orange.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}


// MARK: - Ana sayfa

struct HomeView: View {
    @State private var model = KeyboardSettingsModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    /// WhatsApp'ın paylaşım menüsünden gelen sohbet dosyası.
    @State private var sharedFile: URL?
    /// Klavyedeki 🎤 → `bestkeyboard://dikte`.
    @State private var dictating = false
    /// ✦ kartından hatırlatıcı (`bestkeyboard://hatirlatici`).
    @State private var reminder: ReminderHandoff?
    /// ✦ kartından Takvim etkinliği / kişi (`bestkeyboard://etkinlik`, `…://kisi`).
    @State private var event: EventHandoff?
    @State private var contact: ContactHandoff?
    /// Kestirme sonucu (`bestkeyboard://kestirme-sonuc`).
    @State private var shortcutResult: ShortcutResultPayload?
    /// Ekran görüntüsü ve UI testi için: `-bkScreen silme` o ekranı açar.
    @State private var path: [String] = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-bkScreen"), i + 1 < a.count else { return [] }
        return [a[i + 1]]
    }()

    /// Klavye eklenmiş mi. iOS bunu doğrudan sormuyor; uygulamanın kendi
    /// ayar alanında görünen `AppleKeyboards` listesi yaygın kullanılan yol.
    private var keyboardAdded: Bool {
        let list = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return list.contains { $0.hasPrefix("com.sencagri.bestkeyboard") }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Logo tasarımı (B tuşu): simge + "Best" kalın, "Keyboard" normal.
                        HStack(spacing: 12) {
                            Image("Logo").resizable().frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            (Text("Best").font(.system(size: 34, weight: .heavy))
                             + Text("Keyboard").font(.system(size: 34, weight: .medium)))
                                .tracking(-0.5)
                                .accessibilityLabel("BestKeyboard")
                        }
                        Text("Türkçe için akıllı klavye").foregroundStyle(BK.sub)
                    }
                    .padding(.horizontal, 4)

                    BKCard {
                        HStack {
                            Text("Klavye durumu").font(.headline)
                            Spacer()
                            NavigationLink("Kurulum") { SetupView() }.font(.subheadline.weight(.semibold))
                        }
                        statusRow(ok: keyboardAdded,
                                  title: keyboardAdded ? "Klavye eklendi" : "Klavye eklenmedi",
                                  detail: keyboardAdded ? "Uygulamalarda 🌐 ile seçebilirsin"
                                                        : "Kurulum'daki adımları izle")
                        statusRow(ok: nil, title: "Tam Erişim",
                                  detail: "Ses, titreşim, pano ve kendi temaların için açık olmalı")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BKSectionTitle(text: "Dene", color: BK.sub).padding(.horizontal, 4)
                        TextField("Buraya yazıp klavyeyi dene…", text: $text, axis: .vertical)
                            .lineLimit(2...6)
                            .padding(14)
                            .background(BK.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        tile("Temalar", "11 hazır tema, kendi fotoğrafın", "paintpalette", BK.pink) { ThemesView(model: model) }
                        tile("Klavye düzeni", "Tuş boyları, sayı satırı", "keyboard", BK.teal) { LayoutSettingsView(model: model) }
                        tile("Silme tuşu", "Basılı tutunca nasıl silsin", "delete.left", BK.orange) { DeleteSettingsView(model: model) }
                        tile("Öğrenme", "Kelimelerin ve önerilerin", "lightbulb", BK.green) { LearningView(model: model) }
                        tile("Ses ve titreşim", "Basışta ses ve titreşim", "speaker.wave.2", BK.blue) { SoundSettingsView(model: model) }
                        tile("Kısayollar", "tr → 🇹🇷, lol → 😂, uygulamalar", "bolt", BK.pink) { ShortcutsView(model: model) }
                        tile("Stüdyo", "Videodan GIF, fotoğraftan çıkartma", "face.smiling", BK.purple) { StudioView() }
                        tile("Yapay zeka", "Çevir, düzelt, resim üret", "sparkles", BK.blue) { AIActionsView(model: model) }
                    }

                    VStack(spacing: 0) {
                        NavigationLink { DeveloperView() } label: { linkRow("Geliştirici araçları") }
                        Divider().overlay(BK.line)
                        NavigationLink { LicensesView() } label: { linkRow("Lisanslar") }
                    }
                    .background(BK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(16)
            }
            .background(BK.ground.ignoresSafeArea())
            .foregroundStyle(BK.ink)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.reload()
                    // Klavyenin "uygun listeyi seç"i için liste adları (izin varsa).
                    Task { await ReminderMaker.refreshListNames() }
                    EventMaker.refreshCalendarNames()
                    Handoff.purge()
                    ControlRunner.requestPhotosIfNeeded()
                    ControlRunner.runPendingIfAny()
                    BestKeyboardShortcuts.updateAppShortcutParameters()
                    TodoDestination.refreshInstalled()
                }
            }
            .onChange(of: model.settings.aiActions) { _, _ in
                // Tuş eklenip silinince Siri'nin tanıdığı liste de değişsin.
                BestKeyboardShortcuts.updateAppShortcutParameters()
            }
            .onOpenURL { url in
                if url.isFileURL { sharedFile = url }
                else if DeepLink.matches(url, .dictation) { dictating = true }
                else if let r = ReminderHandoff(url: url) { reminder = r }
                else if let e = EventHandoff(url: url) { event = e }
                else if let c = ContactHandoff(url: url) { contact = c }
                else if DeepLink.matches(url, .tickTickNext) { TodoRouter.tickTickReturned(url) }
                else if DeepLink.matches(url, .shortcutResult) {
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    shortcutResult = ShortcutResultPayload(
                        result: items.first { $0.name == "result" }?.value,
                        failed: items.contains { $0.name == "hata" || $0.name == "errorMessage" },
                        errorMessage: items.first { $0.name == "errorMessage" }?.value)
                }
            }
            .sheet(item: $reminder) { r in ReminderSheet(handoff: r) }
            .sheet(item: $event) { e in EventSheet(handoff: e) }
            .sheet(item: $contact) { c in ContactSheet(handoff: c) }
            .sheet(item: $shortcutResult) { r in
                ShortcutResultSheet(result: r.result, failed: r.failed, errorMessage: r.errorMessage)
            }
            .fullScreenCover(isPresented: $dictating) { DictationView(model: model) }
            .sheet(item: $sharedFile) { _ in ChatImportFlow(pendingURL: $sharedFile) }
            .navigationDestination(for: String.self) { id in
                switch id {
                case "kurulum": SetupView()
                case "temalar": ThemesView(model: model)
                case "duzen": LayoutSettingsView(model: model)
                case "silme": DeleteSettingsView(model: model)
                case "ogrenme": LearningView(model: model)
                case "ses": SoundSettingsView(model: model)
                case "kisayol": ShortcutsView(model: model)
                case "tezgah": HarnessView()
                case "tema": ThemeEditorView(model: model)
                case "studyo": StudioView()
                case "gif": GifMakerView()
                case "cikartma": StickerMakerView()
                case "yz": AIActionsView(model: model)
                case "yzbagla": Color.clear.sheet(isPresented: .constant(true)) { AIConnectSheet() }
                case "yztus": AIActionEditor(model: model, actionID: "cevir")
                case "yzhat":
                    AIActionEditor(model: model, actionID: "hatirlatici")
                        .onAppear {
                            if !model.settings.aiActions.contains(where: { $0.id == "hatirlatici" }),
                               let r = AIAction.defaults.first(where: { $0.id == "hatirlatici" }) {
                                model.update { $0.aiActions.append(r) }
                            }
                        }
                #if DEBUG
                case "yzkart": AIPanelThemePreview()
                case "yzgunluk": AILogView()
                case "dikte": DictationView(model: model)
                case "yzbaglanti": ScrollView { IntegrationsCard().padding(16) }.background(BK.ground)
                case "yzetkinlik", "yzkisi":
                    // Düzenleme sayfaları örnek veriyle (ekran görüntüsü).
                    Color.clear.sheet(isPresented: .constant(true)) {
                        if id == "yzetkinlik" { EventSheet(handoff: .sample) } else { ContactSheet(handoff: .sample) }
                    }
                #endif
                default: DeveloperView()
                }
            }
        }
        .tint(BK.accent)
    }

    private func statusRow(ok: Bool?, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            let tint = ok == true ? BK.green : BK.orange
            Image(systemName: ok == true ? "checkmark" : (ok == false ? "xmark" : "exclamationmark"))
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(tint.ink)
                .frame(width: 32, height: 32)
                .background(tint.chip, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(BK.sub)
            }
        }
    }

    private func tile<D: View>(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint,
                               @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink(destination: dest) {
            VStack(alignment: .leading, spacing: 10) {
                BKIcon(systemName: icon, tint: tint, size: 40)
                Spacer(minLength: 0)
                Text(title).font(.headline).foregroundStyle(BK.ink)
                Text(sub).font(.footnote).foregroundStyle(BK.sub).multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(BK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ title: String) -> some View {
        HStack {
            Text(title).foregroundStyle(BK.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BK.sub)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }
}

struct ComingSoonView: View {
    var body: some View {
        VStack(spacing: 12) {
            BKIcon(systemName: "face.smiling", tint: BK.purple, size: 64)
            Text("Stüdyo yakında").font(.title2.weight(.bold))
            Text("Videodan GIF ve fotoğraftan çıkartma yapıp klavyeden paylaşabileceksin.")
                .multilineTextAlignment(.center).foregroundStyle(BK.sub)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bkScreen("Stüdyo")
    }
}

// MARK: - Kurulum

struct SetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dört adımda hazır").font(.title.weight(.heavy))
                    Text("Bir kere yapman yeterli.").foregroundStyle(BK.sub)
                }
                .padding(.horizontal, 4)

                BKCard(padding: 16) {
                    step(1, BK.accent, "Klavyeler ayarını aç") {
                        HStack(spacing: 6) {
                            ForEach(["Ayarlar", "Genel", "Klavye", "Klavyeler"], id: \.self) { s in
                                Text(s).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(BK.line, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    Divider().overlay(BK.line)
                    step(2, BK.accent, "BestKeyboard'u ekle") {
                        Text("\"Yeni Klavye Ekle…\" listesinde bul ve dokun.").font(.subheadline).foregroundStyle(BK.sub)
                    }
                    Divider().overlay(BK.line)
                    step(3, BK.orange.ink, "Tam Erişim'i aç") {
                        HStack {
                            Text("Tam Erişime İzin Ver").font(.subheadline)
                            Spacer()
                            Capsule().fill(Color.green).frame(width: 44, height: 26)
                                .overlay(Circle().fill(.white).padding(2), alignment: .trailing)
                        }
                        .padding(10)
                        .background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Divider().overlay(BK.line)
                    step(4, BK.accent, "Klavyeyi seç") {
                        Text("Herhangi bir uygulamada klavyenin altındaki küre simgesine basılı tut, BestKeyboard'u seç.")
                            .font(.subheadline).foregroundStyle(BK.sub)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Tam Erişim neden gerekiyor?").font(.headline).foregroundStyle(BK.orange.ink)
                    Text("• Basışta ses ve titreşim\n• Kendi fotoğraflı temaların ve uygulamada yaptığın ayarlar\n• Pano geçmişi, GIF ve çıkartmalar")
                        .font(.subheadline)
                    Text("iOS bu izni açarken \"her şeyi gönderebilir\" uyarısı gösterir. BestKeyboard'da internet bağlantısı yok; yazdıkların telefonundan çıkmaz.")
                        .font(.subheadline)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BK.orange.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Ayarları aç").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Kurulum")
    }

    private func step<C: View>(_ n: Int, _ color: Color, _ title: String,
                               @ViewBuilder _ body: () -> C) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline.weight(.heavy)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(color, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                body()
            }
        }
    }
}

// MARK: - Temalar

struct ThemesView: View {
    let model: KeyboardSettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ScaledKeyboardPreview(settings: model.settings, scheme: scheme, width: g.size.width)
            }
            .frame(height: ThemedKeyboardPreview.height(model.settings) * UIScreen.main.bounds.width / ThemedKeyboardPreview.width)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .zIndex(1)
            ScrollView {
                VStack(spacing: 12) {
                    SharedStoreNotice()
                    NavigationLink { ThemeEditorView(model: model) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Kendi temanı oluştur")
                        }
                        .font(.headline).foregroundStyle(BK.pink.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BK.pink.ink, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(ThemeChoice.allCases, id: \.rawValue) { choice in
                            themeTile(choice)
                        }
                    }
                }
                .padding(16)
            }
        }
        .bkScreen("Temalar")
    }

    private func themeTile(_ choice: ThemeChoice) -> some View {
        var s = model.settings
        s.theme = choice
        let on = model.theme == choice
        return Button { model.theme = choice } label: {
            VStack(spacing: 0) {
                GeometryReader { g in
                    ScaledKeyboardPreview(settings: s, scheme: scheme, width: g.size.width)
                }
                .aspectRatio(ThemedKeyboardPreview.width / ThemedKeyboardPreview.height(s), contentMode: .fit)
                HStack {
                    Text(choice.title).font(.subheadline.weight(.bold)).foregroundStyle(BK.ink).lineLimit(1)
                    Spacer()
                    if let custom = ThemeSpec.find(id: choice.rawValue), custom.isCustom {
                        NavigationLink("Düzenle") { ThemeEditorView(model: model, editing: custom) }
                            .font(.footnote.weight(.semibold))
                    } else if on {
                        Image(systemName: "checkmark").font(.subheadline.weight(.heavy)).foregroundStyle(BK.accent)
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
            }
            .background(BK.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? BK.accent : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Klavye düzeni

struct LayoutSettingsView: View {
    let model: KeyboardSettingsModel
    @Environment(\.colorScheme) private var scheme

    private func pt(_ units: Double) -> String { "\(Int((units * 393 / 11).rounded())) pt" }

    var body: some View {
        let m = model.metrics
        VStack(spacing: 0) {
            GeometryReader { g in
                ScaledKeyboardPreview(settings: model.settings, scheme: scheme, width: g.size.width)
            }
            .frame(height: ThemedKeyboardPreview.height(model.settings) * UIScreen.main.bounds.width / ThemedKeyboardPreview.width)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .zIndex(1)
            .animation(.easeOut(duration: 0.16), value: m)
            ScrollView {
                VStack(spacing: 14) {
                    SharedStoreNotice()
                    BKCard {
                        Toggle(isOn: Binding(get: { model.showsNumberRow }, set: { model.showsNumberRow = $0 })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Sayı satırı").font(.body.weight(.semibold))
                                Text("Rakamlar harflerin üstünde dursun").font(.footnote).foregroundStyle(BK.sub)
                            }
                        }
                        .tint(BK.teal.ink)
                        Divider().overlay(BK.line)
                        BKSliderRow(title: "Shift tuşu", value: pt(m.shiftWidth), tint: BK.teal.ink,
                                    x: model.metricBinding(.shift), range: KeyboardMetrics.shiftRange,
                                    step: KeyboardMetrics.step)
                        BKSliderRow(title: "Silme tuşu", value: pt(m.backspaceWidth), tint: BK.teal.ink,
                                    x: model.metricBinding(.backspace), range: KeyboardMetrics.backspaceRange,
                                    step: KeyboardMetrics.step,
                                    hint: "Bu ikisi genişledikçe alt sıradaki harfler daralır: şu an her harf \(pt(m.letterWidthUnitsRow3)).")
                        BKSliderRow(title: "Boşluk tuşu", value: pt(m.effectiveSpaceWidth(showsGlobe: false)),
                                    tint: BK.teal.ink, x: model.metricBinding(.space),
                                    range: KeyboardMetrics.spaceBounds(showsGlobe: false),
                                    step: KeyboardMetrics.step,
                                    hint: "Enter kalan yeri alır: \(pt(m.returnWidth(showsGlobe: false))).")
                        BKSliderRow(title: "Alt satır yüksekliği", value: "\(Int((KeyboardView.rowHeightPoints * m.bottomRowScale).rounded())) pt",
                                    tint: BK.teal.ink, x: model.metricBinding(.bottomRow),
                                    range: KeyboardMetrics.bottomRowRange, step: KeyboardMetrics.bottomRowStep,
                                    hint: "Boşluk satırı uzar, harfler aynı kalır.")
                    }
                    Button("Varsayılana dön") { model.reset() }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
            }
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Klavye düzeni")
    }
}

// MARK: - Silme tuşu

/// ⌫ basılı tutma — animasyonla. Parametre değişince animasyon baştan
/// başlıyor ve zaman çizgisindeki her çentik bir silme anı; kullanıcı
/// ayarın etkisini sayıdan değil gözden okuyor.
struct DeleteSettingsView: View {
    let model: KeyboardSettingsModel
    @State private var start = Date()

    private static let sample = "Yarın akşam yedide buluşalım mı, yoksa hafta sonuna mı bırakalım"

    var body: some View {
        let c = model.cadence
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                (Text("⌫'ye basılı tutunca önce biraz bekler, sonra ")
                 + Text("harf harf").bold().foregroundColor(BK.orange.ink)
                 + Text(", en sonunda ")
                 + Text("kelime kelime").bold().foregroundColor(BK.pink.ink)
                 + Text(" siler. Ayarları değiştir, aşağıda hemen gör."))
                    .font(.subheadline).foregroundStyle(BK.sub)
                    .padding(.horizontal, 4)
                SharedStoreNotice()
                BKCard { TimelineView(.animation) { ctx in demo(c, at: ctx.date) } }
                BKCard {
                    BKSliderRow(title: "Silmeye başlamadan bekle",
                                value: SettingsFormat.seconds(c.initialDelay),
                                tint: BK.blue.ink, x: restart(model.cadenceBinding(.initialDelay)),
                                range: KeyRepeatCadence.initialDelayRange, step: KeyRepeatCadence.initialDelayStep,
                                hint: "Kısa olursa hızlı yazarken istemeden fazla silebilirsin.")
                    Divider().overlay(BK.line)
                    BKSliderRow(title: "Harf silme hızı", value: "saniyede \(Int((1 / c.characterInterval).rounded())) harf",
                                tint: BK.orange.ink, x: restart(reversed(model.cadenceBinding(.characterInterval),
                                                                         KeyRepeatCadence.characterIntervalRange)),
                                range: KeyRepeatCadence.characterIntervalRange, step: KeyRepeatCadence.characterIntervalStep,
                                ends: ("yavaş", "hızlı"))
                    Divider().overlay(BK.line)
                    BKSliderRow(title: "Kaç harften sonra kelimeye geçsin", value: "\(c.charactersBeforeWordStage) harf",
                                tint: BK.orange.ink, x: restart(model.cadenceBinding(.wordStage)),
                                range: Double(KeyRepeatCadence.charactersBeforeWordStageRange.lowerBound)...Double(KeyRepeatCadence.charactersBeforeWordStageRange.upperBound),
                                step: Double(KeyRepeatCadence.charactersBeforeWordStageStep))
                    Divider().overlay(BK.line)
                    BKSliderRow(title: "Kelime silme hızı",
                                value: SettingsFormat.decimal("saniyede %.1f kelime", 1 / c.wordInterval),
                                tint: BK.pink.ink, x: restart(reversed(model.cadenceBinding(.wordInterval),
                                                                       KeyRepeatCadence.wordIntervalRange)),
                                range: KeyRepeatCadence.wordIntervalRange, step: KeyRepeatCadence.wordIntervalStep,
                                ends: ("yavaş", "hızlı"))
                }
                Button("Varsayılana dön") { model.reset(); start = Date() }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Silme tuşu")
    }

    /// Kaydırıcı sağa = hızlı: aralık küçülüyor, o yüzden ters çevriliyor.
    private func reversed(_ b: Binding<Double>, _ r: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { r.lowerBound + r.upperBound - b.wrappedValue },
                set: { b.wrappedValue = r.lowerBound + r.upperBound - $0 })
    }

    private func restart(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; start = Date() })
    }

    @ViewBuilder
    private func demo(_ c: KeyRepeatCadence, at now: Date) -> some View {
        let n = c.charactersBeforeWordStage
        let wordStart = c.initialDelay + Double(n - 1) * c.characterInterval
        let hold = wordStart + c.wordInterval * 4 + 0.25
        let loop = hold + 1.1
        let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: loop)
        let holding = t < hold
        let tt = min(t, hold)
        let events: [(Double, Bool)] = (1...n).map { (c.initialDelay + Double($0 - 1) * c.characterInterval, false) }
            + (1...max(1, Int((hold - wordStart) / c.wordInterval))).map { (wordStart + Double($0) * c.wordInterval, true) }
        let done = events.filter { $0.0 <= tt }
        let text = done.reduce(Self.sample) { s, e in
            if !e.1 { return String(s.dropLast()) }
            let trimmed = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            guard let i = trimmed.lastIndex(of: " ") else { return "" }
            return String(trimmed[...i])
        }
        let lastWord = done.last?.1 == true
        let (phase, sub, color): (String, String, Color) =
            !holding ? ("Parmak kalktı", "Birazdan yeniden başlıyor", BK.sub)
            : tt < c.initialDelay ? ("Bekliyor…", "Kısa dokunuş tek harf siler", BK.blue.ink)
            : lastWord ? ("Kelime kelime siliyor", "Parmağını kaldırana kadar", BK.pink.ink)
            : ("Harf harf siliyor", "\(min(done.count, n)) / \(n) harf", BK.orange.ink)

        VStack(alignment: .leading, spacing: 14) {
            (Text(text) + Text("|").foregroundColor(BK.accent))
                .font(.body).frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 14) {
                Image(systemName: "delete.left").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(holding ? .white : BK.ink)
                    .frame(width: 64, height: 48)
                    .background(holding ? BK.orange.ink : BK.line, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase).font(.headline).foregroundStyle(color)
                    Text(sub).font(.footnote).foregroundStyle(BK.sub)
                }
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        BK.blue.chip.frame(width: w * c.initialDelay / hold)
                        BK.orange.chip.frame(width: w * (wordStart - c.initialDelay) / hold)
                        BK.pink.chip
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(e.1 ? BK.pink.ink : BK.orange.ink)
                            .opacity(e.0 <= tt ? 1 : 0.35)
                            .frame(width: 2, height: 16)
                            .offset(x: w * min(e.0, hold) / hold)
                    }
                    Rectangle().fill(BK.ink).frame(width: 2).offset(x: w * tt / hold)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 26)
            HStack(spacing: 0) {
                GeometryReader { g in
                    let w = g.size.width
                    HStack(spacing: 0) {
                        Text("bekle").foregroundStyle(BK.blue.ink).frame(width: w * c.initialDelay / hold, alignment: .leading)
                        Text("harf harf").foregroundStyle(BK.orange.ink).frame(width: w * (wordStart - c.initialDelay) / hold, alignment: .leading)
                        Text("kelime kelime").foregroundStyle(BK.pink.ink)
                    }
                    .lineLimit(1).font(.caption.weight(.semibold))
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Öğrenme

struct LearningView: View {
    let model: KeyboardSettingsModel
    @State private var picking: [UTType]?
    @State private var importURL: URL?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    BKSectionTitle(text: "Öneriler", color: BK.green.ink)
                    Toggle(isOn: model.binding(\.predictNext)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sonraki kelimeyi öner").font(.body.weight(.semibold))
                            Text("\"dün\" yazınca \"akşam\" gibi, senin alışkanlığınla").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.green.ink)
                    Divider().overlay(BK.line)
                    Toggle(isOn: model.binding(\.recallTokens)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sık yazdıklarımı hatırla").font(.body.weight(.semibold))
                            Text("IP adresi, e-posta, kullanıcı adı — bir iki kullanımda").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.green.ink)
                }
                BKCard {
                    BKSectionTitle(text: "Yazdıklarından öğret", color: BK.green.ink)
                    Button { picking = [.zip, .plainText] } label: {
                        importRow("WhatsApp sohbeti", "Sohbet › Dışa aktar › Medyasız › BestKeyboard", "bubble.left.and.bubble.right", BK.green)
                    }
                    Divider().overlay(BK.line)
                    Button { picking = [.json] } label: {
                        importRow("Telegram sohbeti", "Telegram Desktop'tan result.json", "paperplane", BK.blue)
                    }
                    Divider().overlay(BK.line)
                    Button { pasting = true } label: {
                        importRow("Metin yapıştır", "E-posta, not, ne istersen", "doc.on.clipboard", BK.purple)
                    }
                    if let note { Text(note).font(.footnote.weight(.semibold)).foregroundStyle(BK.green.ink) }
                    Text("Sohbetlerden yalnız **senin** yazdığın satırlar okunur.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Her şey telefonunda kalır", systemImage: "lock.fill")
                        .font(.headline).foregroundStyle(BK.green.ink)
                    Text("Saklanan şey kelimeler ve kaç kez yazıldıkları; mesajların kendisi saklanmaz. Parola alanlarında ve 12'den fazla rakamlı şeylerde (kart, IBAN) hiçbir şey öğrenilmez. Kişisel sözlüğün klavyede ⚙︎ panelinde.")
                        .font(.subheadline)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BK.green.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Öğrenme")
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking ?? [.data]) { r in
            if case let .success(url) = r { importURL = url }
        }
        .sheet(item: $importURL) { _ in ChatImportFlow(pendingURL: $importURL) }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasted).padding()
                    .navigationTitle("Metin yapıştır").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { pasting = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Öğren") {
                                do { try ChatImporter.importText(pasted); note = "Metinden öğrenildi; klavye bir sonraki açılışta alacak." }
                                catch { note = error.localizedDescription }
                                pasted = ""; pasting = false
                            }
                        }
                    }
            }
        }
    }

    private func importRow(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint) -> some View {
        HStack(spacing: 12) {
            BKIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.footnote).foregroundStyle(BK.sub)
            }
            Spacer()
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

// MARK: - Ses ve titreşim

struct SoundSettingsView: View {
    let model: KeyboardSettingsModel
    @State private var typed = ""
    @State private var pressed: Int?

    var body: some View {
        let s = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SharedStoreNotice()
                BKCard {
                    Text("Dene: harflere ve boşluğa bas").font(.subheadline).foregroundStyle(BK.sub)
                    HStack(spacing: 6) {
                        ForEach(Array(["k", "a", "l", "e", "m", " "].enumerated()), id: \.offset) { i, ch in
                            Button {
                                let word = ch == " "
                                if s.soundEnabled { KeySoundPlayer.shared.play(word ? s.wordSound : s.letterSound) }
                                typed = String((typed + ch).suffix(28))
                                pressed = i
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if pressed == i { pressed = nil } }
                            } label: {
                                Text(ch == " " ? "boşluk" : ch)
                                    .font(ch == " " ? .subheadline : .title3)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(pressed == i ? .white : BK.ink)
                                    .background(pressed == i ? BK.accent : BK.line, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: ch == " " ? .infinity : 48)
                        }
                    }
                    (Text(typed) + Text("|").foregroundColor(BK.accent)).font(.body)
                }
                Toggle(isOn: model.binding(\.soundEnabled)) { Text("Basışta ses").font(.body.weight(.semibold)) }
                    .tint(BK.blue.ink)
                    .padding(16).background(BK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                channelCard("Harf yazarken", "Her harf ve rakamda", BK.accent, BK.purple.chip, \.letterSound)
                channelCard("Kelime bitirirken", "Boşluk, nokta, enter", BK.orange.ink, BK.orange.chip, \.wordSound)
                BKCard {
                    Toggle(isOn: model.binding(\.haptics)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Basışta titreşim").font(.body.weight(.semibold))
                            Text("Parmak tuşa değdiği an").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.purple.ink)
                    Picker("Titreşim gücü", selection: model.binding(\.hapticLevel)) {
                        ForEach(HapticLevel.labels.indices, id: \.self) { Text(HapticLevel.labels[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: s.hapticLevel) { _, lv in
                        UIImpactFeedbackGenerator(style: HapticLevel.style(lv)).impactOccurred()
                    }
                }
                Text("Sesler telefonun sessiz moduna uyar. Klavyede ses ve titreşim için Tam Erişim açık olmalı.")
                    .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Ses ve titreşim")
    }

    private func channelCard(_ title: String, _ sub: String, _ ink: Color, _ chip: Color,
                             _ path: WritableKeyPath<KeyboardSettings, KeySoundChannel>) -> some View {
        let ch = model.settings[keyPath: path]
        return BKCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(ink)
                Text(sub).font(.footnote).foregroundStyle(BK.sub)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(KeySoundKind.allCases, id: \.self) { kind in
                    let on = ch.kind == kind
                    Button {
                        model.update { $0[keyPath: path].kind = kind }
                        KeySoundPlayer.shared.play(model.settings[keyPath: path])
                    } label: {
                        Text(kind.title).font(.subheadline.weight(on ? .bold : .medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(on ? ink : BK.ink)
                            .background(on ? chip : BK.ground, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? ink : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            BKSliderRow(SettingsSliders.volume("Şiddet"), tint: ink,
                        x: Binding(get: { model.settings[keyPath: path].volume },
                                   set: { v in model.update { $0[keyPath: path].volume = v } }))
                .onChange(of: ch.volume) { _, _ in KeySoundPlayer.shared.play(model.settings[keyPath: path]) }
        }
    }
}

// MARK: - Geliştirici

struct DeveloperView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    BKSectionTitle(text: "Deneme", color: BK.accent)
                    NavigationLink { HarnessView().navigationTitle("Tezgah").navigationBarTitleDisplayMode(.inline) } label: {
                        row("Klavye tezgahı", "Her tuşta aday ve maliyet dökümü", "terminal", BK.purple)
                    }
                    Divider().overlay(BK.line)
                    row("Kanonik vaka", "l s l e m → kalem · işlem açık farkla elenir", "text.alignleft", BK.purple)
                }
                BKCard {
                    BKSectionTitle(text: "Yazım kaydı", color: BK.pink.ink)
                    NavigationLink { QuickRecordingView() } label: {
                        row("Hızlı kayıt", "Aklındaki cümleyi yaz, sorunu not et", "record.circle", BK.pink)
                    }
                    Divider().overlay(BK.line)
                    NavigationLink { RecordingListView() } label: {
                        row("Kayıt oturumları", "Kayıtlar Mac'ten ./Tools/pull-sessions.sh ile çekilir", "list.bullet.rectangle", BK.pink)
                    }
                }
                BKCard {
                    BKSectionTitle(text: "Yapay zeka", color: BK.blue.ink)
                    NavigationLink { AILogView() } label: {
                        row("Yapay zeka günlüğü", "Son istekler: süre, sonuç, hata", "list.bullet.clipboard", BK.blue)
                    }
                }
                BKCard {
                    BKSectionTitle(text: "Durum", color: BK.teal.ink)
                    LabeledContent("Ayarlar", value: KeyboardSettingsStore.isShared ? "klavyeyle ortak" : "yalnız uygulamada")
                    LabeledContent("Tanı satırı", value: "klavyede ⚙︎")
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Geliştirici")
    }

    private func row(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint) -> some View {
        HStack(spacing: 12) {
            BKIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(BK.ink)
                Text(sub).font(.footnote).foregroundStyle(BK.sub).multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .frame(minHeight: 52)
    }
}

// MARK: - Kısayollar

/// Tasarım tuvali "12 · Kısayollar": hazır doldurulmuş **tek liste**;
/// ekle, dokun-düzenle, ⊖ sil, varsayılanlara dön. Açılıp kapanan grup
/// yok — kullanıcı "her insan farklı yazar, ekleyip çıkarayım" dedi.
struct ShortcutsView: View {
    let model: KeyboardSettingsModel
    @State private var tryText = "lol"
    @State private var newTrigger = ""
    @State private var newOutput = ""
    @State private var editing: Int?
    @State private var editTrigger = ""
    @State private var editOutput = ""
    /// Yeni kısayolun çıktısı: emoji/metin, çıkartma ya da GIF (tasarım 12).
    @State private var newKind: OutKind = .text
    @State private var mediaCategory: String?
    @State private var pickedMedia: String?
    @State private var media = MediaStore.load()
    @State private var tryToast: String?

    enum OutKind: Hashable { case text, sticker, gif }
    private var mediaKind: MediaStore.Item.Kind { newKind == .gif ? .gif : .sticker }
    private var shownMedia: [MediaStore.Item] {
        media.filter { $0.kind == mediaKind && (mediaCategory == nil || $0.category == mediaCategory) }
    }
    private func mediaItem(_ id: String) -> MediaStore.Item? { media.first { $0.id == id } }

    private var list: [TextShortcut] { model.settings.shortcuts }

    private var hits: [TextShortcut] {
        ShortcutLibrary.candidates(before: tryText).flatMap { ShortcutLibrary.matches(token: $0, list: list) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    Text("Yeni kısayol").font(.headline)
                    Text("Yazınca").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                    TextField("ör. kedi", text: $newTrigger)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                        .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    Text("Çıktı").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                    Picker("Çıktı", selection: $newKind) {
                        Text("Emoji / metin").tag(OutKind.text)
                        Text("Çıkartma").tag(OutKind.sticker)
                        Text("GIF").tag(OutKind.gif)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: newKind) { _, _ in pickedMedia = nil }
                    if newKind == .text {
                        TextField("emoji ya da metin", text: $newOutput)
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        CategoryPicker(selection: $mediaCategory, allowsAll: true, tint: BK.pink)
                        if shownMedia.isEmpty {
                            HStack(spacing: 4) {
                                Text("Bu kategoride \(newKind == .gif ? "GIF" : "çıkartma") yok —").foregroundStyle(BK.sub)
                                NavigationLink("Stüdyoda yap") { StudioView() }
                            }
                            .font(.subheadline)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(shownMedia, id: \.id) { item in
                                let on = pickedMedia == item.id
                                Button { pickedMedia = item.id } label: {
                                    MediaThumb(item: item, height: 72)
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? BK.accent : .clear, lineWidth: 3))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.kind == .gif ? "GIF seç" : "Çıkartma seç")
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    Button {
                        let t = newTrigger.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        let sc: TextShortcut
                        if newKind == .text {
                            let o = newOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !o.isEmpty else { return }
                            sc = Self.make(t, o)
                        } else {
                            guard let id = pickedMedia else { return }
                            sc = TextShortcut(trigger: t, output: id, kind: newKind == .gif ? .gif : .sticker)
                        }
                        model.update { $0.shortcuts.insert(sc, at: 0) }
                        tryText = t; newTrigger = ""; newOutput = ""; pickedMedia = nil
                    } label: {
                        Text("+ Ekle").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(BK.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                BKCard {
                    Text("Dene").font(.subheadline).foregroundStyle(BK.sub)
                    TextField("lol, tr, :D…", text: $tryText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    // Öneri çubuğunun kopyası: ilk yuva kısayol (tasarım 12).
                    HStack(spacing: 4) {
                        Button {
                            guard let h = hits.first else { return }
                            if h.isMedia, let item = mediaItem(h.output) {
                                _ = MediaStore.copyToPasteboard(item)
                                tryToast = "Panoya kondu — basılı tut › Yapıştır"
                            } else {
                                tryToast = "“\(h.trigger)” yerine \(h.output) yazıldı"
                            }
                        } label: {
                            Group {
                                if let h = hits.first {
                                    if h.isMedia, let item = mediaItem(h.output) {
                                        MediaThumb(item: item, height: 32, radius: 6).frame(width: 48)
                                    } else {
                                        Text(h.output).font(h.output.count <= 4 ? .title2 : .subheadline.weight(.bold))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text(tryText.isEmpty ? " " : tryText).foregroundStyle(BK.ink)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(hits.isEmpty ? Color.clear : BK.card, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        Text("akşam").frame(maxWidth: .infinity)
                        Text("yarın").frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 4).frame(height: 48)
                    .background(Color(UIColor(hex: "#DCDDE3")), in: RoundedRectangle(cornerRadius: 12))
                    .environment(\.colorScheme, .light)
                    if let tryToast {
                        Text(tryToast).font(.subheadline).foregroundStyle(.white)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor(hex: "#2C2C2E")), in: RoundedRectangle(cornerRadius: 12))
                            .task(id: tryToast) {
                                try? await Task.sleep(for: .seconds(2.6))
                                self.tryToast = nil
                            }
                    }
                    Text("Öneri çubuğunun ilk yuvası. Çıkartma ve GIF klavyeden mesaja konamıyor; dokununca panoya kopyalanır.")
                        .font(.caption).foregroundStyle(BK.sub)
                }

                BKCard(padding: 16) {
                    HStack {
                        BKSectionTitle(text: "Kısayollarım · \(list.count)", color: BK.pink.ink)
                        Spacer()
                        Button("Varsayılanlara dön") { model.update { $0.shortcuts = ShortcutLibrary.defaultList } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BK.accent)
                    }
                    if list.isEmpty {
                        Text("Liste boş — yukarıdan ekle ya da varsayılanlara dön.").font(.subheadline).foregroundStyle(BK.sub)
                    }
                    ForEach(Array(list.enumerated()), id: \.offset) { i, sc in
                        VStack(spacing: 0) {
                            Divider().overlay(BK.line)
                            HStack(spacing: 10) {
                                Button {
                                    editing = i; editTrigger = sc.trigger; editOutput = sc.output
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(sc.trigger).font(.body.monospaced()).foregroundStyle(BK.sub)
                                            .frame(minWidth: 84, alignment: .leading)
                                        Text("→").foregroundStyle(BK.sub)
                                        if sc.isMedia {
                                            if let item = mediaItem(sc.output) {
                                                MediaThumb(item: item, height: 34, radius: 7).frame(width: 48)
                                            }
                                            Text(sc.kind == .gif ? "GIF" : "Çıkartma").font(.footnote).foregroundStyle(BK.sub)
                                        } else {
                                            Text(sc.output).font(sc.output.count <= 4 ? .title3 : .subheadline)
                                                .foregroundStyle(BK.ink).lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(sc.trigger), \(sc.isMedia ? (sc.kind == .gif ? "GIF" : "çıkartma") : sc.output), düzenle")
                                Button { model.update { $0.shortcuts.remove(at: i) } } label: {
                                    Image(systemName: "minus.circle").font(.title3).foregroundStyle(BK.pink.ink)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(sc.trigger) kısayolunu sil")
                            }
                            .frame(minHeight: 52)
                        }
                    }
                    Text("Dokun: düzenle · ⊖: sil. Kısayol kendiliğinden değişmez; öneri olarak çıkar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }

                BKCard {
                    BKSectionTitle(text: "Çubuktaki uygulamalar", color: BK.accent)
                    Text("Seçili metinle ya da panodakiyle açılır. En çok 4.").font(.footnote).foregroundStyle(BK.sub)
                    ForEach(AIApp.all, id: \.id) { app in
                        let on = model.settings.aiApps.contains(app.id)
                        Toggle(isOn: Binding(get: { on }, set: { v in
                            model.update { s in
                                if v, !s.aiApps.contains(app.id), s.aiApps.count < 4 { s.aiApps.append(app.id) }
                                if !v { s.aiApps.removeAll { $0 == app.id } }
                            }
                        })) {
                            HStack(spacing: 12) {
                                appIcon(app.icon).frame(width: 34, height: 34)
                                Text(app.name).font(.body.weight(.semibold))
                            }
                        }
                        .tint(BK.accent)
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Kısayollar")
        .onAppear {
            media = MediaStore.load()
            #if DEBUG
            // `-kisayolDemo`: tasarım 12'yi ekran görüntüsüyle karşılaştırmak için.
            if ProcessInfo.processInfo.arguments.contains("-kisayolDemo"),
               let st = media.first(where: { $0.kind == .sticker }) {
                if !list.contains(where: { $0.isMedia }) {
                    model.update { $0.shortcuts.insert(TextShortcut(trigger: "kedi", output: st.id, kind: .sticker), at: 0) }
                }
                newKind = .sticker; newTrigger = "miyav"; tryText = "kedi"
                DispatchQueue.main.async { pickedMedia = st.id }
            }
            #endif
        }
        .alert("Kısayolu düzenle", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("yazınca", text: $editTrigger).textInputAutocapitalization(.never)
            // Çıkartma/GIF kısayolunda yalnız tetikleyici düzenleniyor.
            if let i = editing, i < list.count, !list[i].isMedia {
                TextField("çıktı", text: $editOutput)
            }
            Button("Kaydet") {
                if let i = editing, i < list.count, !editTrigger.isEmpty {
                    if list[i].isMedia {
                        model.update { $0.shortcuts[i].trigger = editTrigger.trimmingCharacters(in: .whitespaces) }
                    } else if !editOutput.isEmpty {
                        model.update { $0.shortcuts[i] = Self.make(editTrigger, editOutput) }
                    }
                }
                editing = nil
            }
            Button("Vazgeç", role: .cancel) { editing = nil }
        }
    }

    /// Kısa çıktı emoji, uzunu hazır metin.
    static func make(_ t: String, _ o: String) -> TextShortcut {
        TextShortcut(trigger: t.trimmingCharacters(in: .whitespaces),
                     output: o.trimmingCharacters(in: .whitespacesAndNewlines),
                     kind: o.count <= 4 ? .emoji : .text)
    }
}

/// Stüdyo öğesinin küçük resmi — çıkartma şeffaf zeminde, GIF dolu.
struct MediaThumb: View {
    let item: MediaStore.Item
    var height: CGFloat
    var radius: CGFloat = 12
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let t = MediaStore.thumbnail(item) {
                    if item.kind == .gif { Image(uiImage: t).resizable().scaledToFill() }
                    else { Image(uiImage: t).resizable().scaledToFit().padding(4) }
                } else { BK.line }
            }
            .frame(maxWidth: .infinity).frame(height: height).clipped()
            .background(item.kind == .sticker ? BK.ground : .clear)
            if item.kind == .gif, height >= 60 {
                Text("GIF").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Satır sonunda kırılan çip dizisi.
struct FlowChips<Chip: View>: View {
    let items: [TextShortcut]
    let chip: (TextShortcut) -> Chip
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items, id: \.self) { chip($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w == .infinity ? x : w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX, x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

@ViewBuilder
func appIcon(_ name: String) -> some View {
    if let p = Bundle.main.path(forResource: name, ofType: "png"), let img = UIImage(contentsOfFile: p) {
        Image(uiImage: img).resizable().scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
        RoundedRectangle(cornerRadius: 8).fill(BK.line)
    }
}


// MARK: - Temalı önizleme

/// Klavyenin tamamı: öneri çubuğu + tuşlar, ortak arka plan üstünde —
/// tasarım tuvalindeki "Klavye bileşeni" gibi. Tema karolarında **tam
/// boyutta çizilip bütün olarak küçültülüyor**; küçük çerçevede yeniden
/// çizmek tuş boşluklarını sabit punto bırakıp tuşları ufaltıyordu.
struct ThemedKeyboardPreview: View {
    let settings: KeyboardSettings
    let scheme: ColorScheme
    var themeOverride: KeyboardTheme? = nil
    static let width: CGFloat = 390
    static func height(_ s: KeyboardSettings) -> CGFloat { 84 + KeyboardPreview.height(for: s.metrics) }

    var body: some View {
        let t = themeOverride ?? settings.theme.resolved(
            for: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        ZStack(alignment: .top) {
            BackdropRepresentable(theme: t)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(settings.aiApps.compactMap { AIApp.byID[$0] }, id: \.id) { app in
                        appIcon(app.icon).frame(width: 30, height: 30)
                    }
                    Spacer()
                    Image(systemName: "face.smiling").foregroundStyle(Color(t.barSecondaryText)).frame(width: 34)
                    Image(systemName: "gearshape").foregroundStyle(Color(t.barSecondaryText)).frame(width: 34)
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Color(t.barSecondaryText).opacity(0.25).frame(height: 0.5) }
                HStack(spacing: 0) {
                    ForEach(["akşam", "yemeğe", "sonra"], id: \.self) { w in
                        Text(w).font(.system(size: 16, weight: w == "yemeğe" ? .semibold : .regular))
                            .foregroundStyle(Color(t.barText)).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 44)
                KeyboardPreview(settings: settings, colorScheme: scheme, drawsBackdrop: false,
                                themeOverride: themeOverride)
                    .frame(height: KeyboardPreview.height(for: settings.metrics))
            }
        }
        .frame(width: Self.width, height: Self.height(settings))
        .allowsHitTesting(false)
    }
}

/// Önizlemeyi verilen genişliğe sığacak şekilde bütün olarak ölçekler.
struct ScaledKeyboardPreview: View {
    let settings: KeyboardSettings
    let scheme: ColorScheme
    let width: CGFloat
    var themeOverride: KeyboardTheme? = nil
    var body: some View {
        let k = width / ThemedKeyboardPreview.width
        ThemedKeyboardPreview(settings: settings, scheme: scheme, themeOverride: themeOverride)
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: width, height: ThemedKeyboardPreview.height(settings) * k, alignment: .topLeading)
            .clipped()
    }
}

struct BackdropRepresentable: UIViewRepresentable {
    let theme: KeyboardTheme
    func makeUIView(context: Context) -> ThemeBackdropView { ThemeBackdropView() }
    func updateUIView(_ v: ThemeBackdropView, context: Context) { v.apply(theme) }
}
