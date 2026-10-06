import Foundation

/// Kök sözlüğünün binary paketi.
///
/// Form trie ile **aynı sözleşme** (§4, §11.A): açık byte offset'leri,
/// little-endian, sınır kontrollü okuma, `mmap`'lenebilir, çalışma anında
/// ayrıştırma yok.
///
/// Neden ayrı bir paket: kök sözlüğü ~20-40k giriş ve her birinde POS +
/// fonolojik bayraklar var. Bunları Swift kaynağına gömmek hem derleme
/// süresini hem ikili boyutunu şişirirdi; üstelik dil paketi kod
/// yayınlamadan güncellenemezdi.
///
/// ```
/// Başlık (32 bayt)
///   0  magic          u32   "BKR1"
///   4  version        u16
///   6  flags          u16
///   8  rootCount      u32
///  12  charCount      u32   toplam karakter (yüzeylerin toplam uzunluğu)
///  16  alphabetSize   u16
///  18  maxRootLen     u16
///  20  reserved       u32
///  24  checksum       u64   FNV-1a, yük üzerinden
///
/// Yük
///   alphabet   : alphabetSize × u32   Unicode skaler
///   charOffset : (rootCount+1) × u32  yüzeylerin CSR sınırları
///   chars      : charCount × u16      sembol indeksleri
///   pos        : rootCount × u8
///   flags      : rootCount × u16      bit0-2: alternasyon, bit3: ünlü düşmesi
///                                    bit4-5: geniş zaman sınıfı
///                                    bit6-7: ettirgen sınıfı
///
/// **v2**: `flags` u8'den u16'ya çıktı. Sözlüksel ek sınıfları (geniş zaman,
/// ettirgen) yüzeyden türetilemiyor ve u8'de yalnız 4 bit boştu — ikisi
/// 4 bit istiyor, ama alanı dar tutup sonra yeniden kırmaktansa şimdi
/// genişletmek doğru. v1 paketleri **okunmuyor**: eski pakette sınıf bilgisi
/// yok ve `unknown` varsaymak sessizce yanlış çekim üretirdi.
///   lexCost    : rootCount × f32      ham F_lex = −log(freq/total)
///   pronOffset : (rootCount+1) × u32  okunuş CSR sınırları (v2)
///   pronChars  : × u16                alfabe indeksleri; boş = yazılış okunuş
///
/// Okunuş **ayrı bir bölüm** ve çoğu kök için boş: yalnız kısaltmalar ile
/// yabancı markalarda yazılış ekin uyumunu belirlemiyor (`sql` → `sqlleri`).
/// Alfabe kök yüzeyleriyle okunuşların **birleşiminden** kuruluyor.
/// ```
public enum RootPackFormat {
    public static let magic: UInt32 = 0x3152_4B42   // "BKR1"
    public static let version: UInt16 = 2
    public static let headerSize = 32
}

public struct RootPack: Sendable {
    public let roots: [Root]
    public let alphabet: [Unicode.Scalar]

    public enum PackError: Error, CustomStringConvertible {
        case badMagic(UInt32)
        case badVersion(UInt16)
        case checksumMismatch(expected: UInt64, actual: UInt64)
        case truncated(need: Int, have: Int)
        case badScalar(UInt32)
        case symbolOutOfRange(index: Int, symbol: UInt16, alphabetSize: Int)
        case offsetNotMonotone(index: Int)
        case badPOS(UInt8)

        public var description: String {
            switch self {
            case let .badMagic(m):          return "geçersiz magic: \(String(m, radix: 16))"
            case let .badVersion(v):        return "desteklenmeyen sürüm: \(v)"
            case let .checksumMismatch(e, a): return "checksum uyuşmuyor: beklenen \(e), bulunan \(a)"
            case let .truncated(n, h):      return "paket kesik: \(n) bayt gerekli, \(h) mevcut"
            case let .badScalar(v):         return "geçersiz Unicode skaler: \(v)"
            case let .symbolOutOfRange(i, s, n): return "kök \(i): sembol \(s) alfabe sınırı \(n) dışında"
            case let .offsetNotMonotone(i): return "charOffset monoton değil: [\(i)]"
            case let .badPOS(p):            return "geçersiz POS: \(p)"
            }
        }
    }

    // MARK: - Okuma

    public init(data: Data, verifyChecksum: Bool = true) throws {
        func u16(_ o: Int) throws -> UInt16 {
            guard o + 2 <= data.count else { throw PackError.truncated(need: o + 2, have: data.count) }
            return data.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> UInt16 in
                let a = UInt16(r[o]), b = UInt16(r[o + 1]); return a | (b << 8)
            }
        }
        func u32(_ o: Int) throws -> UInt32 {
            guard o + 4 <= data.count else { throw PackError.truncated(need: o + 4, have: data.count) }
            return data.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> UInt32 in
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(r[o + i]) << (8 * UInt32(i)) }
                return v
            }
        }
        func u64(_ o: Int) throws -> UInt64 {
            guard o + 8 <= data.count else { throw PackError.truncated(need: o + 8, have: data.count) }
            return data.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> UInt64 in
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(r[o + i]) << (8 * UInt64(i)) }
                return v
            }
        }

        let magic = try u32(0)
        guard magic == RootPackFormat.magic else { throw PackError.badMagic(magic) }
        let version = try u16(4)
        guard version == RootPackFormat.version else { throw PackError.badVersion(version) }

        let rootCount = Int(try u32(8))
        let charCount = Int(try u32(12))
        let alphabetSize = Int(try u16(16))
        let checksum = try u64(24)

        if verifyChecksum {
            guard data.count > RootPackFormat.headerSize else {
                throw PackError.truncated(need: RootPackFormat.headerSize + 1, have: data.count)
            }
            let actual = data.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> UInt64 in
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                for i in RootPackFormat.headerSize..<r.count {
                    h ^= UInt64(r[i]); h = h &* 0x0000_0100_0000_01B3
                }
                return h
            }
            guard actual == checksum else {
                throw PackError.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        var off = RootPackFormat.headerSize
        var alpha: [Unicode.Scalar] = []
        alpha.reserveCapacity(alphabetSize)
        for i in 0..<alphabetSize {
            let v = try u32(off + i * 4)
            guard let sc = Unicode.Scalar(v) else { throw PackError.badScalar(v) }
            alpha.append(sc)
        }
        off += alphabetSize * 4

        let offCharOffset = off;  off += (rootCount + 1) * 4
        let offChars = off;       off += charCount * 2
        let offPOS = off;         off += rootCount
        let offFlags = off;       off += rootCount * 2
        let offLexCost = off;     off += rootCount * 4
        let offPronOffset = off;  off += (rootCount + 1) * 4
        // Okunuş bölümü **v2 ile geldi** ve `off` onu okumadan önce zaten
        // ilerletildi; koşul bu yüzden yeni `off` üzerinden kuruluyor.
        // İlk sürüm eski `off`u sınayıp bölümü hep atlıyordu — telaffuz
        // sessizce hiç okunmuyordu ve `sqlleri` üretilemiyordu.
        var pronBounds: [Int] = []
        pronBounds.reserveCapacity(rootCount + 1)
        if off <= data.count {
            for i in 0...rootCount { pronBounds.append(Int(try u32(offPronOffset + i * 4))) }
        }
        let offPronChars = off; off += (pronBounds.last ?? 0) * 2
        guard off <= data.count else { throw PackError.truncated(need: off, have: data.count) }

        // --- Yapısal doğrulama, form trie ile aynı disiplin ---
        var bounds: [Int] = []
        bounds.reserveCapacity(rootCount + 1)
        for i in 0...rootCount { bounds.append(Int(try u32(offCharOffset + i * 4))) }
        for i in 1...max(rootCount, 1) where rootCount > 0 {
            guard bounds[i] >= bounds[i - 1] else { throw PackError.offsetNotMonotone(index: i) }
        }
        guard rootCount == 0 || bounds[rootCount] == charCount else {
            throw PackError.offsetNotMonotone(index: rootCount)
        }

        var out: [Root] = []
        out.reserveCapacity(rootCount)
        for i in 0..<rootCount {
            var chars: [Character] = []
            chars.reserveCapacity(bounds[i + 1] - bounds[i])
            for c in bounds[i]..<bounds[i + 1] {
                let sym = try u16(offChars + c * 2)
                guard Int(sym) < alphabetSize else {
                    throw PackError.symbolOutOfRange(index: i, symbol: sym, alphabetSize: alphabetSize)
                }
                chars.append(Character(alpha[Int(sym)]))
            }
            let posRaw = data.withUnsafeBytes { (r: UnsafeRawBufferPointer) in r[offPOS + i] }
            guard let pos = Root.POS(rawValue: posRaw) else { throw PackError.badPOS(posRaw) }
            let flags = try u16(offFlags + i * 2)
            let cost = Double(Float(bitPattern: try u32(offLexCost + i * 4)))

            var pron: String? = nil
            if pronBounds.count == rootCount + 1, pronBounds[i + 1] > pronBounds[i] {
                var pc: [Character] = []
                for c in pronBounds[i]..<pronBounds[i + 1] {
                    let sym = try u16(offPronChars + c * 2)
                    guard Int(sym) < alphabetSize else {
                        throw PackError.symbolOutOfRange(index: i, symbol: sym,
                                                        alphabetSize: alphabetSize)
                    }
                    pc.append(Character(alpha[Int(sym)]))
                }
                pron = String(pc)
            }
            out.append(Root(String(chars), pos: pos, lexCost: cost,
                            finalAlternation: Self.alternation(fromFlags: flags),
                            dropsVowel: flags & 0b1000 != 0,
                            aoristClass: Root.AoristClass(
                                rawValue: UInt8((flags >> 4) & 0b11)) ?? .unknown,
                            causativeClass: Root.CausativeClass(
                                rawValue: UInt8((flags >> 6) & 0b11)) ?? .unknown,
                            pronunciation: pron))
        }

        self.roots = out
        self.alphabet = alpha
    }

    private static func alternation(fromFlags f: UInt16) -> Phonology.Alternation? {
        switch f & 0b111 {
        case 1: return .pToB
        case 2: return .çToC
        case 3: return .tToD
        case 4: return .kToĞ
        case 5: return .kToG
        default: return nil
        }
    }

    private static func flags(for r: Root) -> UInt16 {
        var f: UInt16 = 0
        switch r.finalAlternation {
        case .pToB?: f = 1
        case .çToC?: f = 2
        case .tToD?: f = 3
        case .kToĞ?: f = 4
        case .kToG?: f = 5
        case nil:    f = 0
        }
        if r.dropsVowel { f |= 0b1000 }
        f |= UInt16(r.aoristClass.rawValue & 0b11) << 4
        f |= UInt16(r.causativeClass.rawValue & 0b11) << 6
        return f
    }

    // MARK: - Yazma

    /// Kök listesini binary'ye serileştirir.
    public static func build(roots: [Root]) -> [UInt8] {
        var scalarSet = Set<UInt32>()
        for r in roots {
            for c in r.surface { for s in c.unicodeScalars { scalarSet.insert(s.value) } }
            for c in r.pronunciation ?? "" { for s in c.unicodeScalars { scalarSet.insert(s.value) } }
        }
        let alphabet = scalarSet.sorted()
        var symbolOf = [UInt32: UInt16]()
        for (i, v) in alphabet.enumerated() { symbolOf[v] = UInt16(i) }

        var charOffset: [UInt32] = [0]
        var chars: [UInt16] = []
        for r in roots {
            for c in r.surface {
                guard let sc = c.unicodeScalars.first, let sym = symbolOf[sc.value] else { continue }
                chars.append(sym)
            }
            charOffset.append(UInt32(chars.count))
        }

        var w = ByteWriter()
        w.u32(RootPackFormat.magic)
        w.u16(RootPackFormat.version)
        w.u16(0)
        w.u32(UInt32(roots.count))
        w.u32(UInt32(chars.count))
        w.u16(UInt16(alphabet.count))
        w.u16(UInt16(roots.map(\.surface.count).max() ?? 0))
        w.u32(0)
        let checksumOffset = w.bytes.count
        w.u64(0)

        for v in alphabet { w.u32(v) }
        for v in charOffset { w.u32(v) }
        for v in chars { w.u16(v) }
        for r in roots { w.u8(r.pos.rawValue) }
        for r in roots { w.u16(flags(for: r)) }
        for r in roots { w.f32(Float(r.lexCost)) }
        var pronOffset: [UInt32] = [0]
        var pronChars: [UInt16] = []
        for r in roots {
            for c in r.pronunciation ?? "" {
                guard let sc = c.unicodeScalars.first, let sym = symbolOf[sc.value] else { continue }
                pronChars.append(sym)
            }
            pronOffset.append(UInt32(pronChars.count))
        }
        for v in pronOffset { w.u32(v) }
        for v in pronChars { w.u16(v) }

        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in w.bytes[RootPackFormat.headerSize...] {
            h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3
        }
        w.replaceU64(at: checksumOffset, h)
        return w.bytes
    }
}

// MARK: - Yerel bayt yazıcı
//
// `KBLexicon`'daki `ByteWriter` ile aynı işi yapar. Kopyalanmasının sebebi:
// `KBMorphology`'nin `KBLexicon`'a bağımlı olmaması. İki modül birbirinden
// bağımsız kaynaklar (§4 ABI'si onları decoder katmanında birleştiriyor);
// bağımlılık eklemek o ayrımı bozardı.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
    }
    mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func replaceU64(at off: Int, _ v: UInt64) {
        for i in 0..<8 { bytes[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }
}
