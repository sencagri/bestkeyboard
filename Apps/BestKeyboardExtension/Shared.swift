import Foundation
import UIKit

// Uygulama ile eklentilerin (klavye, paylaşım, Mesajlar) ortak sabitleri ve
// küçük yardımcıları — her biri **yalnız burada** tanımlı. Hepsi bu dosyayı derliyor.

/// Uygulamanın kimlikleri — paket öneki, ekip, anahtar zinciri. Diğer bütün
/// kimlikler (App Group, bildirim adları, kontrol türleri) bunlardan türüyor.
enum AppIdentity {
    static let bundlePrefix = "com.sencagri.bestkeyboard"
    static let teamID = "KQQ4W7T779"
    /// Uygulama ile klavyenin ortak anahtar zinciri grubu (entitlements ile aynı).
    static let keychainGroup = "\(teamID).\(bundlePrefix).shared"
    /// Yapay zeka anahtarları ve diğer sırların servis adı.
    static let keychainService = "\(bundlePrefix).ai"
    /// `com.sencagri.bestkeyboard.<ad>`.
    static func id(_ name: String) -> String { "\(bundlePrefix).\(name)" }
}

/// Ortak klasör (App Group).
enum AppGroup {
    static let id = "group.\(AppIdentity.bundlePrefix)"

    /// Ortak `UserDefaults`; ortak klasöre erişilemiyorsa (izin yok ya da
    /// klavyede Tam Erişim kapalı) `nil` — `UserDefaults(suiteName:)` o durumda
    /// da nesne döndürüyor ama yazılan değer öbür tarafa ulaşmıyordu.
    static var defaults: UserDefaults? { container == nil ? nil : UserDefaults(suiteName: id) }

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
    }

    /// Ortak klasör; izin yoksa `nil`.
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    /// Ortak klasördeki dosya adları.
    enum File {
        static let dictation = "dictation.json"
        static let historyImport = "history-import.json"
        static let aiLog = "ai-log.json"
        static let customThemes = "themes"
        static let media = "media"
        static let controlPending = "control-pending.json"
    }

    static func file(_ name: String) -> URL? { container?.appendingPathComponent(name) }

    /// Süreçler arası bırakılan işin (✦ aktarımı, dikte metni, Kontrol Merkezi
    /// basışı) geçerlilik süresi: bundan eskisi çalıştırılmıyor — yanlış yere
    /// ya da artık istenmeyen bir iş düşmesin.
    static let handoffTTL: TimeInterval = 10 * 60
    /// Kullanıcıya: "10 dakika".
    static var handoffTTLText: String { "\(Int(handoffTTL / 60)) dakika" }

    /// Bir süreçten bırakılıp ötekinde **bir kez** alınan dosyayı sahiplenir:
    /// atomik taşıma, sonra okuma. Okumayla silme arasında yeni bir dosya
    /// yazılırsa o silinmiyor, sıradaki sahiplenmeye kalıyor.
    static func claim(_ name: String) -> Data? {
        guard let url = file(name) else { return nil }
        let mine = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".claimed")
        guard (try? FileManager.default.moveItem(at: url, to: mine)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: mine) }
        return try? Data(contentsOf: mine)
    }

    /// Süreçler arası kilit: uygulama ve eklentiler aynı dosyayı
    /// oku–değiştir–yaz yaparken biri ötekinin yazdığını ezmesin. Kısa tutulmalı.
    /// - Returns: `nil` — ortak klasör var ama kilit alınamadı; iş **yapılmadı**
    ///   (kilitsiz yazmak başka sürecin kaydını ezebilirdi). Ortak klasör yoksa
    ///   dosya da paylaşılmıyor, iş kilitsiz yapılıyor.
    static func withLock<T>(_ name: String, _ body: () throws -> T) rethrows -> T? {
        guard let url = file(name + ".lock") else { return try body() }
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var r: Int32
        repeat { r = flock(fd, LOCK_EX) } while r != 0 && errno == EINTR
        guard r == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Bu sürecin **kendi** (paylaşılmayan) Application Support klasörü. Klavyenin
/// öğrendikleri (kalibrasyon, kişisel sözlük, yazma geçmişi, pano) yalnız
/// burada: Tam Erişim açılıp kapanabildiği için ortak klasörde iki yazar olurdu.
enum LocalStore {
    enum Name {
        static let calibration = "calibration"
        static let personal = "personal"
        static let history = "history.json"
        static let clipboard = "clipboard"
    }

    static func url(_ name: String, isDirectory: Bool = false) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name, isDirectory: isDirectory)
    }
}

/// Küçük `Codable` kayıtların JSON dosyası — bütün depolar aynı yoldan okuyup
/// yazıyor (klasörü kur, kodla, atomik yaz).
enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `protected`: cihaz ilk açılışta kilit açılana kadar okunamaz (kişisel veri).
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL?, protected: Bool = false) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(value) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        if protected { options.insert(.completeFileProtectionUntilFirstUserAuthentication) }
        return (try? data.write(to: url, options: options)) != nil
    }
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
        /// Dış uygulama hata ya da iptalle döndü (`hata=1`).
        static let error = "hata"
        /// TickTick zincirinin tek kullanımlık jetonu.
        static let token = "z"
        /// Kestirmeler'in sonuç ve hata açıklaması (kendi adlarıyla).
        static let shortcutResult = "result"
        static let shortcutError = "errorMessage"
    }

    /// Adrese konan metnin üst sınırı (dış uygulamaya giden istem, kestirme girdisi).
    static let maxTextLength = 4000

    /// Bir `x-callback-url` isteğinin dönüş adresleri: başarıda `host`, hata ve
    /// iptalde aynısı `hata=1` ile.
    static func callbacks(_ host: Host, _ items: [URLQueryItem] = [], cancel: Bool = true) -> [URLQueryItem] {
        let failed = url(host, items + [URLQueryItem(name: Param.error, value: "1")])?.absoluteString
        return [URLQueryItem(name: "x-success", value: url(host, items)?.absoluteString),
                URLQueryItem(name: "x-error", value: failed)]
            + (cancel ? [URLQueryItem(name: "x-cancel", value: failed)] : [])
    }

    /// Adresteki parametre değeri.
    static func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static func has(_ name: String, in url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == name } ?? false
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
    static let notification = AppIdentity.id("dictation")

    struct Payload: Codable {
        var text: String
        var at: TimeInterval
        var isFresh: Bool { Date().timeIntervalSince1970 - at < AppGroup.handoffTTL }
    }

    /// Bekleyen metni **sahiplenir** (`AppGroup.claim`).
    static func claim() -> Payload? {
        AppGroup.claim(AppGroup.File.dictation).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
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
    /// Kişi kartının baş harf dairesi (Kişiler'deki gri).
    static let avatar = Pair(light: 0x8F94A3, dark: 0x8F94A3)
    /// Yüzen kartın gölgesi.
    static let shadow: UInt32 = 0x141228

    static let pink = Tint(ink: Pair(light: 0xB3264E, dark: 0xFF8FB0), chip: Pair(light: 0xFFE1EA, dark: 0x3A1A26))
    static let teal = Tint(ink: Pair(light: 0x0E7A68, dark: 0x5FD8C2), chip: Pair(light: 0xDDF4EF, dark: 0x12302B))
    static let orange = Tint(ink: Pair(light: 0xB4520F, dark: 0xFFAD6B), chip: Pair(light: 0xFFE9D6, dark: 0x3A2412))
    static let green = Tint(ink: Pair(light: 0x2F7A1F, dark: 0x8FDB7A), chip: Pair(light: 0xE2F5DC, dark: 0x1B2E16))
    static let blue = Tint(ink: Pair(light: 0x1F5FBF, dark: 0x86B4FF), chip: Pair(light: 0xDDEBFF, dark: 0x172640))
    static let purple = Tint(ink: Pair(light: 0x5B3FD0, dark: 0xB4A2FF), chip: Pair(light: 0xEDE7FF, dark: 0x251E44))
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: Double = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: CGFloat(alpha))
    }

    /// `#RRGGBB` — geçersiz dizgi magenta veriyor ki tasarım hatası göze
    /// batsın, sessizce siyaha dönmesin.
    convenience init(hex: String, alpha: Double = 1) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self.init(rgb: 0xFF00FF); return }
        self.init(rgb: v, alpha: alpha)
    }
}

extension UIImage {
    /// En uzun kenarı `maxSide` pikseli geçmeyecek şekilde küçültür (1x).
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let k = maxSide / longest
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension UUID {
    /// Dosya adlarında kullanılan kısa kimlik ("3f9a1c2e").
    static var short: String { String(UUID().uuidString.prefix(8)).lowercased() }
}

/// Başlatma argümanları — UI testleri, ekran görüntüleri ve öz-testler
/// (`-bkScreen silme`, `-controlRun event`…) hep bu yoldan okunuyor.
enum LaunchArgs {
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    /// Bayraktan sonraki değer (`-bkScreen silme` → "silme").
    static func value(_ flag: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
}

// MARK: - Ortak cümleler

/// Kullanıcıya birden çok yerde (klavye, uygulama, paylaşım) söylenen cümleler.
enum CommonText {
    /// Uygulama açıkken sohbete dönüş ipucu.
    static let backToChat = "Sol üstteki ◀ ile sohbete dön"
    static let app = "Uygulama"
    /// Yapay zeka ayarlarının ekran adı (yol tarifleri bundan: "Yapay zeka tuşları › Bağla").
    static let aiScreen = "Yapay zeka tuşları"
    /// "WhatsApp açılamadı. Yüklü mü?"
    static func notInstalled(_ app: String) -> String { "\(app) açılamadı. Yüklü mü?" }
    /// İçe aktarılan klavyeye bir sonraki açılışında geçiyor.
    static let keyboardPicksUpNext = "klavye bir sonraki açılışta alacak"
    /// "Kestirmeler açılamadı — Tam Erişim gerekli".
    static func fullAccess(open what: String) -> String { "\(what) açılamadı — Tam Erişim gerekli" }
    /// "Kaydedilemedi — Tam Erişim gerekli".
    static func fullAccess(failed what: String) -> String { "\(what) — Tam Erişim gerekli" }
}

/// "Panoda, şimdi yapıştır" ipuçları — iOS klavyenin belgeye resim koymasına
/// izin vermiyor; resim ve uzun istemler panodan gidiyor.
enum PasteHint {
    static let howTo = "basılı tut › Yapıştır"
    static let placed = "Panoya kondu — \(howTo)"
    static let copied = "Kopyalandı — mesaj kutusuna \(howTo)"
    static func image(in app: String? = nil) -> String {
        "Resim panoda — " + (app.map { "\($0)'de " } ?? "") + "kutuya \(howTo)"
    }
    static func text(in app: String) -> String { "Metin panoda — \(app)'de yapıştır" }
    static func prompt(in app: String) -> String { "İstem panoda — \(app)'de yapıştır" }
}

// MARK: - Türkçe metin ve tarih

extension Locale {
    /// Türkçe (`i/İ`, `ı/I`, gün ve ay adları). Çekirdekteki karşılığı `TurkishText.locale`.
    static let turkish = Locale(identifier: "tr_TR")
}

extension String {
    /// Boşsa `nil` ("yoksa hiç gösterme" için).
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// İmlecin önündeki metne yapışmasın: önceki karakter boşluk değilse başa boşluk.
    func spaced(after before: String?) -> String {
        guard let last = before?.last, !last.isWhitespace else { return self }
        return " " + self
    }
    var trUppercased: String { uppercased(with: .turkish) }
    /// Arama için: büyük/küçük harf ve aksan farkı yok ("Kibar" ~ "kıbar").
    var trFolded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .turkish) }
    /// Ad eşleştirme (liste, takvim, proje): büyük/küçük harf ve aksan farkı yok.
    /// `trFolded` ile aynı kural (aramada eşleşen, adda da eşleşsin).
    func trEquals(_ other: String) -> Bool { trFolded == other.trFolded }
}

/// Tarih biçimleyiciler — biçim başına **bir** tane (oluşturmak pahalı; aynı
/// ayarların her yerde elle yazılması da farklılaşmaya açıktı).
enum DateFormats {
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    private static var isoCache: [String: ISO8601DateFormatter] = [:]

    /// Önbellek anahtarında saat dilimi de var: uygulama açıkken dilim
    /// değişirse (yolculuk) eski dilimle biçimlenmesin.
    private static func formatter(_ key: String, locale: Locale, format: String) -> DateFormatter {
        let zone = TimeZone.current
        let key = key + "|" + zone.identifier
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = format
        cache[key] = f
        return f
    }

    /// Makine biçimi (API, model, adres): `en_US_POSIX`, yerel saat dilimi.
    static func posix(_ format: String) -> DateFormatter {
        formatter("posix|" + format, locale: Locale(identifier: "en_US_POSIX"), format: format)
    }

    /// Kullanıcıya gösterilen Türkçe biçim ("Cmt 10 Eki · 19:00").
    static func turkish(_ format: String) -> DateFormatter {
        formatter("tr|" + format, locale: .turkish, format: format)
    }

    /// ISO 8601, yerel saat dilimiyle ("2026-10-07T14:30:00+03:00").
    static var iso8601: ISO8601DateFormatter {
        let zone = TimeZone.current
        lock.lock(); defer { lock.unlock() }
        if let f = isoCache[zone.identifier] { return f }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = zone
        isoCache[zone.identifier] = f
        return f
    }
}
