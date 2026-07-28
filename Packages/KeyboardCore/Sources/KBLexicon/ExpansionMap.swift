import Foundation

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

    public static let magic: UInt32 = 0x3158_4B42   // "BKX1"
    public static let version: UInt16 = 1
    public static let headerSize = 24

    private let table: [String: [String]]

    public var count: Int { table.count }

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

    public enum PackError: Error, CustomStringConvertible {
        case badMagic, badVersion(UInt16), truncated, checksumMismatch, badUTF8(index: Int)

        public var description: String {
            switch self {
            case .badMagic:            return "geçersiz magic"
            case let .badVersion(v):   return "desteklenmeyen sürüm: \(v)"
            case .truncated:           return "paket kesik"
            case .checksumMismatch:    return "checksum uyuşmuyor"
            case let .badUTF8(i):      return "geçersiz UTF-8: [\(i)]"
            }
        }
    }

    public func packBytes() -> [UInt8] {
        // Sıra **deterministik**: sözlük sırası çalışmadan çalışmaya değişir ve
        // aynı girdiden farklı binary üretmek yeniden üretilebilirliği bozar.
        let sorted = table.keys.sorted().flatMap { k in table[k]!.map { (k, $0) } }

        var w = ByteWriter()
        w.u32(Self.magic)
        w.u16(Self.version)
        w.u16(0)
        w.u32(UInt32(sorted.count))
        w.u32(0)
        let checksumOffset = w.bytes.count
        w.u64(0)

        for (k, v) in sorted {
            let kb = Array(k.utf8), vb = Array(v.utf8)
            w.u16(UInt16(kb.count)); w.u16(UInt16(vb.count))
            for b in kb { w.u8(b) }
            for b in vb { w.u8(b) }
        }

        let h = FNV1a.hash(w.bytes[Self.headerSize...])
        w.replaceU64(at: checksumOffset, h)
        return w.bytes
    }

    public init(packData data: Data, verifyChecksum: Bool = true) throws {
        let b = [UInt8](data)
        guard b.count >= Self.headerSize else { throw PackError.truncated }
        let r = ByteReader(b)

        guard try r.u32(0) == Self.magic else { throw PackError.badMagic }
        let v = try r.u16(4)
        guard v == Self.version else { throw PackError.badVersion(v) }
        let count = Int(try r.u32(8))
        let stored = try r.u64(16)

        if verifyChecksum {
            guard b.count > Self.headerSize else { throw PackError.truncated }
            guard FNV1a.hash(b[Self.headerSize...]) == stored else {
                throw PackError.checksumMismatch
            }
        }

        var entries: [(String, String)] = []
        entries.reserveCapacity(count)
        var off = Self.headerSize
        for i in 0..<count {
            guard off + 4 <= b.count else { throw PackError.truncated }
            let kl = Int(try r.u16(off)), vl = Int(try r.u16(off + 2))
            off += 4
            guard off + kl + vl <= b.count else { throw PackError.truncated }
            guard let k = String(bytes: b[off..<(off + kl)], encoding: .utf8),
                  let v = String(bytes: b[(off + kl)..<(off + kl + vl)], encoding: .utf8)
            else { throw PackError.badUTF8(index: i) }
            entries.append((k, v))
            off += kl + vl
        }
        // Tam boyut eşitliği: fazlalık bayt aynı içeriğin ikinci bir temsilini
        // doğururdu ve checksum onu kapsadığı için fark sessizce geçerdi.
        guard off == b.count else { throw PackError.truncated }

        self.init(entries: entries)
    }
}
