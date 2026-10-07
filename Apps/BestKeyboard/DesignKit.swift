import SwiftUI
import UIKit

// Uygulamanın görsel dili (renkler, kart, başlık, simge) — uygulama ve
// paylaşım eklentisi (BestKeyboardAction) ortak kullanıyor.

/// SwiftUI renkleri — değerler `BKPalette`'te (eklentilerle ortak).
enum BK {
    static func color(_ p: BKPalette.Pair) -> Color { Color(p.ui) }
    static let ground = color(BKPalette.ground)
    static let card = color(BKPalette.card)
    static let ink = color(BKPalette.ink)
    static let sub = color(BKPalette.sub)
    static let line = color(BKPalette.line)
    static let accent = color(BKPalette.accent)

    struct Tint { let ink: Color; let chip: Color }
    private static func tint(_ t: BKPalette.Tint) -> Tint { Tint(ink: color(t.ink), chip: color(t.chip)) }
    static let pink = tint(BKPalette.pink)
    static let teal = tint(BKPalette.teal)
    static let orange = tint(BKPalette.orange)
    static let green = tint(BKPalette.green)
    static let blue = tint(BKPalette.blue)
    static let purple = tint(BKPalette.purple)
}

struct BKCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BK.card, in: RoundedRectangle(cornerRadius: BK.Radius.card, style: .continuous))
    }
}

struct BKSectionTitle: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.trUppercased)
            .font(.footnote.weight(.bold)).tracking(0.5).foregroundStyle(color)
    }
}

struct BKIcon: View {
    let systemName: String
    let tint: BK.Tint
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint.ink)
            .frame(width: size, height: size)
            .background(tint.chip, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

extension View {
    func bkScreen(_ title: String) -> some View {
        self.background(BK.ground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Ortak parçalar
//
// Ekranlarda aynı düğme, satır ve kutu ayrı ayrı yazılıyordu; ölçüler ve
// renkler burada bir kez.

extension BK {
    enum Radius {
        static let card: CGFloat = 18
        static let button: CGFloat = 14
        static let field: CGFloat = 12
    }
}

/// Tam genişlikte dolu düğme. `.bkPrimary` ana iş, `.bkSecondary` yanındaki
/// ikinci seçenek, `.bkCard` sayfadaki tek ikincil iş (Varsayılana dön…).
struct BKButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color
    var minHeight: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: BK.Radius.button))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == BKButtonStyle {
    static var bkPrimary: BKButtonStyle { BKButtonStyle(fill: BK.accent, text: .white) }
    static func bkPrimary(_ tint: Color) -> BKButtonStyle { BKButtonStyle(fill: tint, text: .white) }
    static var bkSecondary: BKButtonStyle { BKButtonStyle(fill: BK.line, text: BK.ink) }
    /// Renkli zeminli ikincil (Gönder — WhatsApp…).
    static func bkTinted(_ t: BK.Tint) -> BKButtonStyle { BKButtonStyle(fill: t.chip, text: t.ink) }
    /// Kart renginde; silme gibi işlerde yazı rengi verilir.
    static func bkCard(_ text: Color = BK.ink) -> BKButtonStyle { BKButtonStyle(fill: BK.card, text: text, minHeight: 48) }
}

/// Yeşil "eklendi" şeridi.
struct BKDoneBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy))
            Text(text).font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(BK.green.ink)
        .padding(.horizontal, 14).frame(minHeight: 46)
        .background(BK.green.chip, in: RoundedRectangle(cornerRadius: BK.Radius.button))
    }
}

/// Formun altındaki hata cümlesi.
struct BKErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(BK.orange.ink) }
}

/// Alan başlığı ("Nereye", "Liste", "Maddeler").
struct BKFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote.weight(.bold)).foregroundStyle(BK.sub) }
}

/// Kişinin baş harf dairesi.
struct BKAvatar: View {
    let initials: String
    var size: CGFloat = 44
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.37, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(BK.color(BKPalette.avatar), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Satırı silen ⊖.
struct BKRemoveButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle").font(.title3).foregroundStyle(BK.pink.ink).frame(width: 36, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Seçilebilir hap (seçili = dolu).
struct BKChip: View {
    let title: String
    let on: Bool
    var tint: Color = BK.accent
    var off: Color = BK.ground
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .white : BK.ink)
                .padding(.horizontal, 12).frame(height: 34)
                .background(on ? tint : off, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    /// Metin alanı kutusu (zemin renginde, yuvarlak).
    func bkField() -> some View {
        padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: BK.Radius.field))
    }
}

/// Yapay zeka tuşları ızgarası (3 sütun, simge + ad) — paylaşım ve dikte
/// ekranı aynı tuşlar. `isOn` dolu (vurgulu) çizilecek tuşlar.
struct BKActionKeyGrid: View {
    let actions: [AIAction]
    var height: CGFloat = 72
    var isOn: (AIAction) -> Bool = { _ in false }
    var disabled = false
    let run: (AIAction) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(actions) { a in
                let on = isOn(a)
                Button { run(a) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: a.icon).font(.system(size: height > 64 ? 18 : 16, weight: .semibold))
                        Text(a.name).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(on ? .white : BK.purple.ink)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(on ? BK.accent : BK.purple.chip,
                                in: RoundedRectangle(cornerRadius: BK.Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }
}
