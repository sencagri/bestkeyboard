import SwiftUI
import UIKit

// Uygulamanın görsel dili (renkler, kart, başlık, simge) — uygulama ve
// paylaşım eklentisi (BestKeyboardAction) ortak kullanıyor.

enum BK {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
    static let ground = dyn(0xF4F2FA, 0x0F0E14)
    static let card = dyn(0xFFFFFF, 0x1C1B24)
    static let ink = dyn(0x16151C, 0xF3F2F8)
    static let sub = dyn(0x55536A, 0xA9A6BA)
    static let line = dyn(0xECEAF3, 0x2C2A36)
    static let accent = dyn(0x4B3FD6, 0x8F86FF)

    struct Tint { let ink: Color; let chip: Color }
    static let pink = Tint(ink: dyn(0xB3264E, 0xFF8FB0), chip: dyn(0xFFE1EA, 0x3A1A26))
    static let teal = Tint(ink: dyn(0x0E7A68, 0x5FD8C2), chip: dyn(0xDDF4EF, 0x12302B))
    static let orange = Tint(ink: dyn(0xB4520F, 0xFFAD6B), chip: dyn(0xFFE9D6, 0x3A2412))
    static let green = Tint(ink: dyn(0x2F7A1F, 0x8FDB7A), chip: dyn(0xE2F5DC, 0x1B2E16))
    static let blue = Tint(ink: dyn(0x1F5FBF, 0x86B4FF), chip: dyn(0xDDEBFF, 0x172640))
    static let purple = Tint(ink: dyn(0x5B3FD0, 0xB4A2FF), chip: dyn(0xEDE7FF, 0x251E44))
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
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
        Text(text.uppercased(with: Locale(identifier: "tr")))
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
