import Foundation

/// `.bkc` — karakter n-gram paketi.
///
/// `.bkt` (form trie) ve `.bkr` (kök sözlüğü) ile **aynı sözleşme**: açık byte
/// offset'leri, little-endian, sınır kontrollü okuma, FNV-1a checksum, yapısal
/// doğrulama.
///
/// Ayrı dosya olmasının sebebi `.bkt`'ye bölüm eklemenin format sürümünü
/// kırması ve dil paketlerinin bağımsız evrilebilmesi. Yükleme opsiyonel:
/// paket yoksa literal kanalı yedek sabite düşer ve bunu **söyler**.
///
/// ```
/// Başlık (40 bayt)
///   0  magic            u32   "BKC1"
///   4  version          u16
///   6  flags            u16
///   8  alphabetSize     u16   N (toplam sembol S = N + 2)
///  10  maxScoredLength  u16
///  12  wOovChar         f32
///  16  wTail            f32
///  20  reserved         u32
///  24  reserved         u32
///  28  reserved         u32
///  32  checksum         u64   FNV-1a, yük üzerinden
///
/// Yük
///   alphabet : N × u32     Unicode skaler
///   table    : S³ × u16    kuantize −log P(c | h₁, h₂)
/// ```
public enum CharNGramPackFormat {
    public static let magic: UInt32 = 0x3143_4B42   // "BKC1"
    public static let version: UInt16 = 1
    public static let headerSize = 40
}

public extension CharNGram {

    enum PackError: Error, CustomStringConvertible {
        case badMagic(UInt32)
        case badVersion(UInt16)
        case checksumMismatch(expected: UInt64, actual: UInt64)
        case truncated(need: Int, have: Int)
        case badScalar(UInt32)
        case emptyAlphabet
        case alphabetNotSorted(index: Int)
        case badMaxLength(UInt16)
        case badWeight(name: String, value: Double)

        public var description: String {
            switch self {
            case let .badMagic(m):            return "geçersiz magic: \(String(m, radix: 16))"
            case let .badVersion(v):          return "desteklenmeyen sürüm: \(v)"
            case let .checksumMismatch(e, a): return "checksum uyuşmuyor: beklenen \(e), bulunan \(a)"
            case let .truncated(n, h):        return "paket kesik: \(n) bayt gerekli, \(h) mevcut"
            case let .badScalar(v):           return "geçersiz Unicode skaler: \(v)"
            case .emptyAlphabet:              return "alfabe boş"
            case let .alphabetNotSorted(i):   return "alfabe sıralı değil: [\(i)]"
            case let .badMaxLength(v):        return "geçersiz maxScoredLength: \(v)"
            case let .badWeight(n, v):        return "geçersiz ağırlık \(n): \(v)"
            }
        }
    }

    // MARK: - Okuma

    init(packData data: Data, verifyChecksum: Bool = true) throws {
        let raw = [UInt8](data)
        let r = ByteReader(raw)

        let magic = try r.u32(0)
        guard magic == CharNGramPackFormat.magic else { throw PackError.badMagic(magic) }
        let version = try r.u16(4)
        guard version == CharNGramPackFormat.version else { throw PackError.badVersion(version) }

        let n = Int(try r.u16(8))
        guard n > 0 else { throw PackError.emptyAlphabet }
        // Yapısal doğrulama iddiası ancak bu alanlar da denetlenirse doğru.
        // `maxScoredLength == 0` bütün token'ları taşma korumasına sokar; NaN
        // bir ağırlık §0'ın "cost(literal) her zaman sonlu" garantisini kırar
        // ve hata **sessiz** olur — commit kararı kilitlenir, çökme olmaz.
        let rawMaxLen = try r.u16(10)
        guard rawMaxLen > 0 else { throw PackError.badMaxLength(rawMaxLen) }
        let maxLen = Int(rawMaxLen)
        let wOov = Double(try r.f32(12))
        guard wOov.isFinite, wOov >= 0 else {
            throw PackError.badWeight(name: "wOovChar", value: wOov)
        }
        let wTail = Double(try r.f32(16))
        guard wTail.isFinite, wTail >= 0 else {
            throw PackError.badWeight(name: "wTail", value: wTail)
        }
        let checksum = try r.u64(32)

        if verifyChecksum {
            let head = CharNGramPackFormat.headerSize
            guard raw.count > head else {
                throw PackError.truncated(need: head + 1, have: raw.count)
            }
            let actual = FNV1a.hash(raw[head...])
            guard actual == checksum else {
                throw PackError.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        var off = CharNGramPackFormat.headerSize
        var alphabet: [Unicode.Scalar] = []
        alphabet.reserveCapacity(n)
        for i in 0..<n {
            let v = try r.u32(off + i * 4)
            guard let sc = Unicode.Scalar(v) else { throw PackError.badScalar(v) }
            // Sıralılık `symbolOf` eşlemesinin paket üretimindekiyle aynı
            // olduğunun ucuz kanıtı; bozulursa tablo indeksleri kayar ve
            // hata **sessiz** olur (yanlış maliyet, çökme yok).
            if i > 0 && sc.value <= alphabet[i - 1].value {
                throw PackError.alphabetNotSorted(index: i)
            }
            alphabet.append(sc)
        }
        off += n * 4

        let s = n + 2
        let entries = s * s * s
        guard off + entries * 2 <= raw.count else {
            throw PackError.truncated(need: off + entries * 2, have: raw.count)
        }
        var table = [UInt16](repeating: 0, count: entries)
        for i in 0..<entries { table[i] = try r.u16(off + i * 2) }

        self.init(alphabet: alphabet, table: table,
                  wOovChar: wOov, wTail: wTail, maxScoredLength: maxLen)
    }

    // MARK: - Yazma

    func packBytes() -> [UInt8] {
        var w = ByteWriter()
        w.u32(CharNGramPackFormat.magic)
        w.u16(CharNGramPackFormat.version)
        w.u16(0)
        w.u16(UInt16(alphabet.count))
        w.u16(UInt16(maxScoredLength))
        w.f32(Float(wOovChar))
        w.f32(Float(wTail))
        w.u32(0); w.u32(0); w.u32(0)
        let checksumOffset = w.bytes.count
        w.u64(0)

        for s in alphabet { w.u32(s.value) }
        let s = symbolCount
        for i in 0..<(s * s * s) { w.u16(rawTableEntry(i)) }

        let h = FNV1a.hash(w.bytes[CharNGramPackFormat.headerSize...])
        w.replaceU64(at: checksumOffset, h)
        return w.bytes
    }
}
