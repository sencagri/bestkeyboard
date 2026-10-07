import Foundation
import KBRuntime

/// Fontlu yazı kipi (tasarım 24): açık mı, hangi stil, çubuktaki çipler.
///
/// Klavye yalnız sonucu kullanıyor (`transform`, `spaceTitle`, `samples`);
/// stil listesi, adları ve son seçimin hatırlanması burada.
struct FancyTextMode {
    /// Tasarımdaki yedi çip; ilki "Normal". El yazısı kalın çeşidi: ince olan
    /// küçük puntoda okunmuyor.
    static let styles: [FancyText.Style?] = [nil, .bold, .boldScript, .fraktur, .doubleStruck, .mono, .circled]

    /// Seçili stil; `nil` = normal yazı.
    private(set) var style: FancyText.Style?
    private(set) var isOpen = false

    private static let lastKey = KeyboardSettingsStore.LocalKey.fancyLast

    static func name(_ s: FancyText.Style?) -> String {
        guard let s else { return "Normal" }
        return s == .boldScript ? "El yazısı" : s.title
    }

    mutating func toggle() {
        isOpen.toggle()
        // Son seçilen stil hatırlanıyor; ilk açılışta El yazısı.
        style = isOpen ? KeyboardSettingsStore.local.string(forKey: Self.lastKey)
            .flatMap(FancyText.Style.init(rawValue:)) ?? .boldScript : nil
    }

    mutating func pick(_ i: Int) {
        guard Self.styles.indices.contains(i) else { return }
        style = Self.styles[i]
        if let style { KeyboardSettingsStore.local.set(style.rawValue, forKey: Self.lastKey) }
    }

    /// Çubuktaki çipler, her biri kendi stiliyle yazılmış; kip kapalıysa `nil`.
    var samples: [String]? {
        guard isOpen else { return nil }
        return Self.styles.map { s in s.map { FancyText.apply($0, to: Self.name($0)) } ?? Self.name(nil) }
    }

    var selectedIndex: Int { Self.styles.firstIndex { $0 == style } ?? 0 }

    /// Yazılacak metnin stilli hâli; stil yoksa `nil`.
    func styled(_ text: String) -> String? { style.map { FancyText.apply($0, to: text) } }
}
