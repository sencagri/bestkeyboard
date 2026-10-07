import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

@ViewBuilder
func appIcon(_ name: String) -> some View {
    if let p = Bundle.main.path(forResource: name, ofType: "png"), let img = UIImage(contentsOfFile: p) {
        Image(uiImage: img).resizable().scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: BK.Radius.mini, style: .continuous))
    } else {
        RoundedRectangle(cornerRadius: BK.Radius.mini).fill(BK.line)
    }
}

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
/// Ekranın üstünde sabit duran klavye önizlemesi — içerik altından kayar.
struct PreviewHeader: View {
    let settings: KeyboardSettings
    /// Kaydedilmemiş tema (düzenleyicideki taslak).
    var themeOverride: KeyboardTheme? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            ScaledKeyboardPreview(settings: settings, scheme: scheme, width: g.size.width, themeOverride: themeOverride)
        }
        .frame(height: ThemedKeyboardPreview.height(settings) * UIScreen.main.bounds.width / ThemedKeyboardPreview.width)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .zIndex(1)
    }
}

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

/// Canlı önizleme — uzantının çizdiği `KeyboardView`'ın ta kendisi.
///
/// Ayrı bir "önizleme çizici" yazmak, önizlemenin gerçekten çizilenden
/// ayrışmasına açık kapı bırakırdı; bu ekranın bütün değeri o ikisinin aynı
/// olmasında.
struct KeyboardPreview: UIViewRepresentable {
    let settings: KeyboardSettings
    let colorScheme: ColorScheme
    /// Arka plan dışarıda (öneri çubuğuyla ortak) çiziliyorsa `false`.
    var drawsBackdrop = true
    /// Kaydedilmemiş bir tema (düzenleyicideki taslak).
    var themeOverride: KeyboardTheme? = nil

    /// Uzantıyla aynı satır yüksekliği (216 pt / 4 satır).
    static func height(for metrics: KeyboardMetrics) -> CGFloat {
        KeyboardView.height(for: metrics)
    }

    func makeUIView(context: Context) -> KeyboardView {
        let v = KeyboardView(layout: TurkishQ.layout(metrics: settings.metrics),
                             metrics: settings.metrics)
        // Önizleme yazmıyor: dokunma decoder'a gitmediği için tuşları basılabilir
        // göstermek yanıltıcı olurdu.
        v.isUserInteractionEnabled = false
        // Face ID'li telefonlarda 🌐 tuşu yok; önizleme gerçek alt satırı
        // göstermeli.
        v.showsGlobeKey = KeyboardSettingsModel.showsGlobe
        v.drawsBackdrop = drawsBackdrop
        return v
    }

    func updateUIView(_ v: KeyboardView, context: Context) {
        // Ölçü gerçekten değiştiyse yeniden kur: sürgü sürüklenirken her karede
        // 32 katmanı yıkıp kurmanın gereği yok.
        if v.metrics != settings.metrics {
            v.apply(layout: TurkishQ.layout(metrics: settings.metrics),
                    metrics: settings.metrics)
        }
        v.theme = themeOverride ?? settings.theme.resolved(
            for: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }
}
