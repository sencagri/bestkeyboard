import Foundation
import KBFoundation
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

    public static let container = BinaryContainer(
        magic: 0x3150_4B42,   // "BKP1"
        version: 1, headerSize: 24)
    public static let fileName = "personal.bkp"

    // MARK: - Yazma

    public static func save(_ lexicon: PersonalLexicon, to directory: URL) throws {
        // Sıralı yazım: aynı sözlük daima aynı baytları üretsin (Dictionary
        // sırası koşudan koşuya değişir ve dosya gereksiz yere farklılaşırdı).
        let ordered = lexicon.entries.sorted { $0.key < $1.key }

        let format = container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(ordered.count))
            w.u32(0)                                  // reserved
        }
        for (word, entry) in ordered {
            let utf8 = Array(word.utf8)
            // `UInt16` sınırı: 40 skalerlik yüzey UTF-8'de en fazla 160 bayt.
            guard utf8.count <= Int(UInt16.max) else { continue }
            w.u16(UInt16(clamping: entry.points))
            w.u32(entry.seq)
            w.u16(UInt16(utf8.count))
            w.append(contentsOf: utf8)
        }

        let target = directory.appendingPathComponent(fileName)
        try AtomicFile.publish(Data(format.seal(w)), to: target)
        // Kullanıcının yazdığı kelimeler kişisel veridir: yedeğe gitmemeli ve
        // cihaz kilitliyken de okunabilir olmalı (klavye kilit ekranında da açılır).
        try AtomicFile.protectPersonalData(target)
    }

    public static func delete(from directory: URL) throws {
        try AtomicFile.removeIfExists(directory.appendingPathComponent(fileName))
    }

    // MARK: - Okuma

    /// Depoya özgü durumlar. Ortak durumlar (magic, sürüm, checksum, kesiklik,
    /// boyut) `BinaryFormatError`.
    public enum LoadError: Error, CustomStringConvertible {
        case missing
        case badEntry(index: Int)

        public var description: String {
            switch self {
            case .missing:           return "kişisel sözlük dosyası yok"
            case let .badEntry(i):   return "geçersiz girdi: [\(i)]"
            }
        }
    }

    public static func load(from directory: URL) throws -> PersonalLexicon {
        let url = directory.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LoadError.missing
        }
        let r = try container.open(data)
        let count = Int(try r.u32(8))

        var entries: [String: PersonalLexicon.Entry] = [:]
        var offset = container.headerSize
        for i in 0..<count {
            let points = Int(try r.u16(offset))
            let seq = try r.u32(offset + 2)
            let len = Int(try r.u16(offset + 6))
            offset += 8
            guard let word = try r.utf8(offset, length: len) else {
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
        guard offset == r.count else {
            throw BinaryFormatError.sizeMismatch(expected: offset, have: r.count)
        }

        return PersonalLexicon(entries: entries)
    }

    /// Yükler; dosya yoksa ya da bozuksa **boş** sözlük döndürür.
    public static func loadOrEmpty(from directory: URL) -> PersonalLexicon {
        (try? load(from: directory)) ?? PersonalLexicon()
    }
}
