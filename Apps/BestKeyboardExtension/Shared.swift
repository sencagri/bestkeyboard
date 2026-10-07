import Foundation
import UIKit

// Uygulama ile eklentilerin (klavye, paylaşım, Mesajlar) ortak sabitleri ve
// küçük yardımcıları — her biri **yalnız burada** tanımlı. Hepsi bu dosyayı derliyor.

/// Ortak klasör (App Group).
enum AppGroup {
    static let id = "group.com.sencagri.bestkeyboard"

    /// Ortak `UserDefaults`; izin (entitlement) yoksa `nil`.
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    /// Uygulama ile eklentilerin paylaştığı küçük kayıtlar için depo: ortak
    /// klasör yoksa (klavyede Tam Erişim kapalı) bu sürecin kendi deposu.
    /// Ayarlar ayrı: `KeyboardSettingsStore` kendi geçiş kuralıyla.
    static var store: UserDefaults { defaults ?? .standard }

    /// Ortak depodaki anahtarlar — **yalnız burada**. (Ayar anahtarları
    /// `KeyboardSettingsStore`'da, cihaza özel olanlar `LocalKey`'de.)
    enum Key {
        static let aiActions = "kb.ai.actions"
        static let aiOffered = "kb.ai.offered"
        static let aiProvider = "kb.ai.provider"
        /// OpenAI'nin modeli eski adıyla; diğerleri `kb.ai.model.<sağlayıcı>`.
        static func aiModel(_ provider: String) -> String { provider == "openai" ? "kb.ai.model" : "kb.ai.model.\(provider)" }
        static let reminderLists = "kb.reminder.lists"
        static let eventCalendars = "kb.event.calendars"
        static let todoDestination = "kb.todo.dest"
        static let todoInstalled = "kb.todo.installed"
        static let handoffPrefix = "kb.handoff."
        static let dictationActions = "kb.dictation.actions"
        static let controlPending = "kb.control.pending"
        static let photosNeeded = "kb.photos.needed"
    }

    /// Ortak klasör; izin yoksa `nil`.
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    /// Ortak klasördeki dosya adları.
    enum File {
        static let dictation = "dictation.json"
        static let historyImport = "history-import.json"
        static let aiLog = "ai-log.json"
        static let customThemes = "themes"
    }

    static func file(_ name: String) -> URL? { container?.appendingPathComponent(name) }
}

/// `bestkeyboard://` adresleri: klavye ve eklentiler uygulamayı bunlarla açıyor.
enum DeepLink {
    static let scheme = "bestkeyboard"

    enum Host: String {
        case home = ""
        case reminder = "hatirlatici"
        case event = "etkinlik"
        case contact = "kisi"
        case dictation = "dikte"
        case shortcutResult = "kestirme-sonuc"
        case tickTickNext = "ticktick-sonraki"
    }

    static func url(_ host: Host, _ items: [URLQueryItem] = []) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host.rawValue
        if !items.isEmpty { c.queryItems = items }
        return c.url
    }

    /// Sorgu parametreleri.
    enum Param {
        static let id = "id"
        static let edit = "edit"
        static let plan = "plan"
        static let contact = "kisi"
        static let destination = "hedef"
    }

    /// Satır içi verinin parametresi (eski biçim / dışarıdan): kişi `kisi`, diğerleri `plan`.
    static func payloadParam(_ host: Host) -> String { host == .contact ? Param.contact : Param.plan }

    /// Adres bu uygulamanın ve bu `host`un mu.
    static func matches(_ url: URL, _ host: Host) -> Bool {
        url.scheme == scheme && (url.host ?? "") == host.rawValue
    }
}

/// Uygulamanın dikte ekranından klavyeye metin aktarımı: ortak klasörde
/// bekleyen dosya + Darwin bildirimi (klavye açıksa hemen alsın).
enum DictationHandoff {
    static let notification = "com.sencagri.bestkeyboard.dictation"
    /// Bundan eski metin yazılmıyor (yanlış alana eski bir dikte düşmesin).
    static let ttl: TimeInterval = 10 * 60

    struct Payload: Codable {
        var text: String
        var at: TimeInterval
        var isFresh: Bool { Date().timeIntervalSince1970 - at < DictationHandoff.ttl }
    }

    /// Metni bırakır ve haber verir. - Returns: yazılabildi mi.
    static func write(_ text: String) -> Bool {
        guard let url = AppGroup.file(AppGroup.File.dictation),
              let data = try? JSONEncoder().encode(Payload(text: text, at: Date().timeIntervalSince1970)),
              (try? data.write(to: url, options: .atomic)) != nil else { return false }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notification as CFString), nil, nil, true)
        return true
    }

    /// Bekleyen metin (silmeden).
    static func pending() -> Payload? {
        guard let url = AppGroup.file(AppGroup.File.dictation), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func clear() {
        guard let url = AppGroup.file(AppGroup.File.dictation) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension UIResponder {
    /// Eklentiden adres açmak. Eklentide `UIApplication.shared` yok; yanıtlayıcı
    /// zincirindeki uygulama nesnesinin `openURL:options:completionHandler:`
    /// yöntemi çağrılıyor (klavyede yalnız Tam Erişimle çalışıyor).
    @discardableResult
    func bkOpenURL(_ url: URL) -> Bool {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let cur = r {
            if cur.responds(to: sel), String(describing: type(of: cur)).contains("Application") {
                typealias Fn = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                unsafeBitCast(cur.method(for: sel), to: Fn.self)(cur, sel, url, NSDictionary(), nil)
                return true
            }
            r = cur.next
        }
        return false
    }
}

/// Marka renkleri (açık / koyu) — uygulamanın `BK`'si, klavye paneli, Mesajlar
/// ve paylaşım eklentisi bu tablodan okuyor.
enum BKPalette {
    struct Pair {
        let light: UInt32
        let dark: UInt32
        /// Açık / koyu moda göre değişen renk.
        var ui: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) } }
    }
    struct Tint { let ink: Pair; let chip: Pair }

    static let ground = Pair(light: 0xF4F2FA, dark: 0x0F0E14)
    static let card = Pair(light: 0xFFFFFF, dark: 0x1C1B24)
    static let ink = Pair(light: 0x16151C, dark: 0xF3F2F8)
    static let sub = Pair(light: 0x55536A, dark: 0xA9A6BA)
    static let line = Pair(light: 0xECEAF3, dark: 0x2C2A36)
    static let accent = Pair(light: 0x4B3FD6, dark: 0x8F86FF)

    static let pink = Tint(ink: Pair(light: 0xB3264E, dark: 0xFF8FB0), chip: Pair(light: 0xFFE1EA, dark: 0x3A1A26))
    static let teal = Tint(ink: Pair(light: 0x0E7A68, dark: 0x5FD8C2), chip: Pair(light: 0xDDF4EF, dark: 0x12302B))
    static let orange = Tint(ink: Pair(light: 0xB4520F, dark: 0xFFAD6B), chip: Pair(light: 0xFFE9D6, dark: 0x3A2412))
    static let green = Tint(ink: Pair(light: 0x2F7A1F, dark: 0x8FDB7A), chip: Pair(light: 0xE2F5DC, dark: 0x1B2E16))
    static let blue = Tint(ink: Pair(light: 0x1F5FBF, dark: 0x86B4FF), chip: Pair(light: 0xDDEBFF, dark: 0x172640))
    static let purple = Tint(ink: Pair(light: 0x5B3FD0, dark: 0xB4A2FF), chip: Pair(light: 0xEDE7FF, dark: 0x251E44))
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
