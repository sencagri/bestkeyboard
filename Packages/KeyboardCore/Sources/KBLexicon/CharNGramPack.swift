import Foundation
import KBFoundation

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
    public static let container = BinaryContainer(
        magic: 0x3143_4B42,   // "BKC1"
        version: 1, headerSize: 40)
}

public extension CharNGram {

    /// Pakete özgü hatalar. Ortak durumlar (magic, sürüm, checksum, kesiklik,
    /// alfabe) `BinaryFormatError`.
    enum PackError: Error, CustomStringConvertible {
        case emptyAlphabet
        case badMaxLength(UInt16)
        case badWeight(name: String, value: Double)

        public var description: String {
            switch self {
            case .emptyAlphabet:              return "alfabe boş"
            case let .badMaxLength(v):        return "geçersiz maxScoredLength: \(v)"
            case let .badWeight(n, v):        return "geçersiz ağırlık \(n): \(v)"
            }
        }
    }

    // MARK: - Okuma

    init(packData data: Data, verifyChecksum: Bool = true) throws {
        let r = try CharNGramPackFormat.container.open(data, verifyChecksum: verifyChecksum)

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

        var off = CharNGramPackFormat.container.headerSize
        // Sıralılık `symbolOf` eşlemesinin paket üretimindekiyle aynı
        // olduğunun ucuz kanıtı (`ByteReader.alphabet`).
        let alphabet = try r.alphabet(at: off, count: n)
        off += n * 4

        let s = n + 2
        let entries = s * s * s
        try r.requireRange(off, entries * 2)
        var table = [UInt16](repeating: 0, count: entries)
        for i in 0..<entries { table[i] = r.unchecked(UInt16.self, off + i * 2) }

        self.init(alphabet: alphabet, table: table,
                  wOovChar: wOov, wTail: wTail, maxScoredLength: maxLen)
    }

    // MARK: - Yazma

    func packBytes() -> [UInt8] {
        let format = CharNGramPackFormat.container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u16(UInt16(alphabet.count))
            w.u16(UInt16(maxScoredLength))
            w.f32(Float(wOovChar))
            w.f32(Float(wTail))
            w.u32(0); w.u32(0); w.u32(0)              // reserved
        }
        w.alphabet(alphabet.map(\.value))
        let s = symbolCount
        for i in 0..<(s * s * s) { w.u16(rawTableEntry(i)) }
        return format.seal(w)
    }
}
