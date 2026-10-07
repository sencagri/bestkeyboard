import Foundation
import KBGeometry

/// Kişisel sözlüğün kalıcı deposu — sözleşme §8.7.
///
/// ## Tek yazar, uzantı sandbox'ı
///
/// `CalibrationStore` ile **aynı** gerekçe: Tam Erişim açılıp kapanabildiği
/// için iki yazılabilir depo split-brain üretir. Klavyenin öğrendiği her şey
/// uzantının kendi sandbox'ında.
///
/// ## Profil YOK
///
/// Kalibrasyon geometri başına ayrı dosyada tutuluyor, çünkü öğrenilen şey
/// tuş merkezlerine göre parmak sapması. Kişisel sözlüğün öğrendiği şey bir
/// **yüzey**; `⇧` genişleyince değişmiyor. Profil anahtarı koymak, klavye
/// ölçüsünü değiştiren kullanıcıya kendi adını yeniden öğretirdi.
///
/// ## Dosya formatı
///
/// ```
/// Başlık (24 bayt)
///   0  magic     u32   "BKP1"
///   4  version   u16
///   6  flags     u16
///   8  count     u32   girdi sayısı
///  12  reserved  u32
///  16  checksum  u64   FNV-1a, yük üzerinden
///
/// Yük  count × (2 + 4 + 2 + n)
///   points    u16
///   seq       u32
///   byteCount u16
///   utf8      byteCount bayt   — kanonik (NFC, küçük harf) yüzey
/// ```
///
/// Yazma geçici dosya + atomik rename; okuma checksum doğrular. Bozuksa dosya
/// **yok sayılır** ve sözlük boş başlar: bozuk bir kişisel sözlükle çalışmak
/// aktif zarardır (`θ = ∞` yanlış yüzeylere gider), boş başlamak yalnız
/// faydayı erteler.
public enum PersonalLexiconStore {

    public static let magic: UInt32 = 0x3150_4B42   // "BKP1"
    public static let version: UInt16 = 1
    public static let headerSize = 24
    public static let fileName = "personal.bkp"

    // MARK: - Yazma

    public static func save(_ lexicon: PersonalLexicon, to directory: URL) throws {
        var bytes = [UInt8]()

        func u16(_ v: UInt16) { bytes.append(UInt8(truncatingIfNeeded: v))
                                bytes.append(UInt8(truncatingIfNeeded: v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }

        // Sıralı yazım: aynı sözlük daima aynı baytları üretsin (Dictionary
        // sırası koşudan koşuya değişir ve dosya gereksiz yere farklılaşırdı).
        let ordered = lexicon.entries.sorted { $0.key < $1.key }

        u32(magic); u16(version); u16(0)
        u32(UInt32(ordered.count)); u32(0)
        let checksumOffset = bytes.count
        u64(0)

        for (word, entry) in ordered {
            let utf8 = Array(word.utf8)
            // `UInt16` sınırı: 40 skalerlik yüzey UTF-8'de en fazla 160 bayt.
            guard utf8.count <= Int(UInt16.max) else { continue }
            u16(UInt16(clamping: entry.points))
            u32(entry.seq)
            u16(UInt16(utf8.count))
            bytes.append(contentsOf: utf8)
        }

        let h = FNV1a.hash(bytes[headerSize...])
        for i in 0..<8 { bytes[checksumOffset + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }

        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(fileName)
        let tmp = directory.appendingPathComponent(".\(fileName).tmp")
        try Data(bytes).write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
        try protect(target)
    }

    public static func delete(from directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Kullanıcının yazdığı kelimeler kişisel veridir: yedeğe gitmemeli ve
    /// cihaz kilitliyken de okunabilir olmalı (klavye kilit ekranında da açılır).
    private static func protect(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }

    // MARK: - Okuma

    public enum LoadError: Error, CustomStringConvertible {
        case missing
        case badMagic
        case badVersion(UInt16)
        case truncated
        case checksumMismatch
        case badEntry(index: Int)

        public var description: String {
            switch self {
            case .missing:           return "kişisel sözlük dosyası yok"
            case .badMagic:          return "geçersiz magic"
            case let .badVersion(v): return "desteklenmeyen sürüm: \(v)"
            case .truncated:         return "dosya kesik"
            case .checksumMismatch:  return "checksum uyuşmuyor"
            case let .badEntry(i):   return "geçersiz girdi: [\(i)]"
            }
        }
    }

    public static func load(from directory: URL) throws -> PersonalLexicon {
        let url = directory.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LoadError.missing
        }
        let b = [UInt8](data)
        guard b.count >= headerSize else { throw LoadError.truncated }

        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * UInt32(i)) }
            return v
        }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            return v
        }

        guard u32(0) == magic else { throw LoadError.badMagic }
        let v = u16(4)
        guard v == version else { throw LoadError.badVersion(v) }
        let count = Int(u32(8))
        let stored = u64(16)

        guard FNV1a.hash(b[headerSize...]) == stored else { throw LoadError.checksumMismatch }

        var entries: [String: PersonalLexicon.Entry] = [:]
        var offset = headerSize
        for i in 0..<count {
            guard offset + 8 <= b.count else { throw LoadError.truncated }
            let points = Int(u16(offset))
            let seq = u32(offset + 2)
            let len = Int(u16(offset + 6))
            offset += 8
            guard offset + len <= b.count else { throw LoadError.truncated }
            guard let word = String(bytes: b[offset..<(offset + len)], encoding: .utf8) else {
                throw LoadError.badEntry(index: i)
            }
            offset += len
            // Yüzey **yeniden** kanonikleştiriliyor: dosya elle ya da eski bir
            // sürümle yazılmış olabilir ve kanonik olmayan bir anahtar
            // `isAdmitted` ile `admitted` arasında sessiz bir ayrışma üretirdi.
            guard let key = PersonalLexicon.canonical(word), key == word,
                  points > 0 else {
                throw LoadError.badEntry(index: i)
            }
            entries[key] = .init(points: min(points, PersonalLexicon.maxPoints), seq: seq)
        }
        // Fazlalık bayta izin verilmiyor: aynı içeriğin ikinci bir kanonik
        // temsili doğar ve checksum onu kapsadığı için fark sessizce geçerdi.
        guard offset == b.count else { throw LoadError.truncated }

        return PersonalLexicon(entries: entries)
    }

    /// Yükler; dosya yoksa ya da bozuksa **boş** sözlük döndürür.
    public static func loadOrEmpty(from directory: URL) -> PersonalLexicon {
        (try? load(from: directory)) ?? PersonalLexicon()
    }
}
