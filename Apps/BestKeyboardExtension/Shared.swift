import Foundation
import UIKit

// Uygulama ile eklentilerin (klavye, paylaşım, Mesajlar) ortak sabitleri ve
// küçük yardımcıları — her biri **yalnız burada** tanımlı. Hepsi bu dosyayı derliyor.

/// Ortak klasör (App Group).
enum AppGroup {
    static let id = "group.com.sencagri.bestkeyboard"

    /// Ortak `UserDefaults`; izin (entitlement) yoksa `nil`.
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

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
