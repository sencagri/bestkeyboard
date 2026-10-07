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
            .background(BK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
