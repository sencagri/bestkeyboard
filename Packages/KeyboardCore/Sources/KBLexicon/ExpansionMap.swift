import Foundation
import KBFoundation

/// Genişletme haritası — plan §4.D.
///
/// `slm → selam`, `nbr → ne haber`. Bunlar öneri çubuğunda **ek aday** olarak
/// görünür ve **asla otomatik uygulanmaz**.
///
/// ## Neden otomatik değil
///
/// Plan §4.B: *"Gayrıresmî formlar asla otomatik olarak resmî karşılığına
/// çevrilmez."* Kullanıcı `slm` yazdıysa `slm` demek istemiştir; onu `selam`
/// yapmak yazdığını değiştirmektir. Kısaltma bir üslup tercihidir, yazım
/// hatası değil.
///
/// Zaten mekanizma da buna izin vermiyor: `slm` gayrıresmî sözlükte olduğu
/// için `θ = ∞` alıyor (§8 bilinen kelime koruması). Bu tip yalnız **ek
/// öneri** üretiyor.
///
/// ## Format `.bkx`
///
/// ```
/// Başlık (24 bayt)
///   0  magic     u32   "BKX1"
///   4  version   u16
///   6  flags     u16
///   8  count     u32   giriş sayısı
///  12  reserved  u32
///  16  checksum  u64   FNV-1a, yük üzerinden
///
/// Yük (giriş başına)
///   keyLen    u16 · UTF-8 bayt
///   valueLen  u16 · UTF-8 bayt
/// ```
///
/// Trie kullanılmıyor: birkaç yüz giriş için düz bir sözlük hem daha küçük hem
/// daha hızlı, ve bu arama **sıcak yolda değil** — token başına bir kez.
public struct ExpansionMap: Sendable {

    public static let container = BinaryContainer(
        magic: 0x3158_4B42,   // "BKX1"
        version: 1, headerSize: 24)

    private let table: [String: [String]]

    public var count: Int { table.count }

    /// Deterministik sırada tüm girdiler — doğrulama ve yeniden paketleme için.
    public var entries: [(String, String)] {
        table.keys.sorted().flatMap { k in table[k]!.map { (k, $0) } }
    }

    public init(entries: [(String, String)]) {
        var t: [String: [String]] = [:]
        for (k, v) in entries {
            // Kanonik anahtar: NFC-normalize (§7). Ayrık yazılmış `ç` aynı
            // girdiyi bulmalı.
            let key = k.precomposedStringWithCanonicalMapping
            let value = v.precomposedStringWithCanonicalMapping
            // Aynı kısaltmanın birden çok açılımı olabilir; sıra korunur.
            if var existing = t[key] {
                if !existing.contains(value) { existing.append(value); t[key] = existing }
            } else {
                t[key] = [value]
            }
        }
        table = t
    }

    /// Bu yüzeyin açılımları — yoksa boş.
    public func expansions(of surface: String) -> [String] {
        table[surface.precomposedStringWithCanonicalMapping] ?? []
    }

    // MARK: - Paket

    /// Haritaya özgü hata. Ortak durumlar (magic, sürüm, checksum, kesiklik)
    /// `BinaryFormatError`.
    public enum PackError: Error, CustomStringConvertible {
        case badUTF8(index: Int)

        public var description: String {
            switch self {
            case let .badUTF8(i):      return "geçersiz UTF-8: [\(i)]"
            }
        }
    }

    public func packBytes() -> [UInt8] {
        // Sıra **deterministik**: sözlük sırası çalışmadan çalışmaya değişir ve
        // aynı girdiden farklı binary üretmek yeniden üretilebilirliği bozar.
        let sorted = entries

        let format = Self.container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(sorted.count))
            w.u32(0)                                  // reserved
        }
        for (k, v) in sorted {
            let kb = Array(k.utf8), vb = Array(v.utf8)
            w.u16(UInt16(kb.count)); w.u16(UInt16(vb.count))
            w.append(contentsOf: kb)
            w.append(contentsOf: vb)
        }
        return format.seal(w)
    }

    public init(packData data: Data, verifyChecksum: Bool = true) throws {
        let r = try Self.container.open(data, verifyChecksum: verifyChecksum)
        let count = Int(try r.u32(8))

        var entries: [(String, String)] = []
        entries.reserveCapacity(count)
        var off = Self.container.headerSize
        for i in 0..<count {
            let kl = Int(try r.u16(off)), vl = Int(try r.u16(off + 2))
            off += 4
            guard let k = try r.utf8(off, length: kl),
                  let v = try r.utf8(off + kl, length: vl)
            else { throw PackError.badUTF8(index: i) }
            entries.append((k, v))
            off += kl + vl
        }
        // Tam boyut eşitliği: fazlalık bayt aynı içeriğin ikinci bir temsilini
        // doğururdu ve checksum onu kapsadığı için fark sessizce geçerdi.
        guard off == r.count else {
            throw BinaryFormatError.sizeMismatch(expected: off, have: r.count)
        }

        self.init(entries: entries)
    }
}
