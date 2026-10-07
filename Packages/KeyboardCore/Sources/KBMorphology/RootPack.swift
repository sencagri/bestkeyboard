import Foundation
import KBGeometry

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
    public static let container = BinaryContainer(
        magic: 0x3152_4B42,   // "BKR1"
        version: 2, headerSize: 32)
}

public struct RootPack: Sendable {
    public let roots: [Root]
    public let alphabet: [Unicode.Scalar]

    /// Pakete özgü yapısal hatalar. Ortak durumlar (magic, sürüm, checksum,
    /// kesiklik, alfabe, CSR offset'leri) `BinaryFormatError`.
    public enum PackError: Error, CustomStringConvertible {
        case symbolOutOfRange(index: Int, symbol: UInt16, alphabetSize: Int)
        case badPOS(UInt8)

        public var description: String {
            switch self {
            case let .symbolOutOfRange(i, s, n): return "kök \(i): sembol \(s) alfabe sınırı \(n) dışında"
            case let .badPOS(p):            return "geçersiz POS: \(p)"
            }
        }
    }

    // MARK: - Okuma

    public init(data: Data, verifyChecksum: Bool = true) throws {
        let r = try RootPackFormat.container.open(data, verifyChecksum: verifyChecksum)
        let rootCount = Int(try r.u32(8))
        let charCount = Int(try r.u32(12))
        let alphabetSize = Int(try r.u16(16))

        var off = RootPackFormat.container.headerSize
        let alpha = try r.alphabet(at: off, count: alphabetSize)
        off += alphabetSize * 4

        let offCharOffset = off;  off += (rootCount + 1) * 4
        let offChars = off;       off += charCount * 2
        let offPOS = off;         off += rootCount
        let offFlags = off;       off += rootCount * 2
        let offLexCost = off;     off += rootCount * 4
        let offPronOffset = off;  off += (rootCount + 1) * 4
        // Okunuş bölümü **v2 ile geldi** ve `off` onu okumadan önce zaten
        // ilerletildi; bölümün boyu yeni `off`'tan sonra okunan sınırdan
        // geliyor. İlk sürüm eski `off`u sınayıp bölümü hep atlıyordu —
        // telaffuz sessizce hiç okunmuyordu ve `sqlleri` üretilemiyordu.
        let pronCount = Int(try r.offsets(at: offPronOffset, count: rootCount,
                                          section: "pronOffset"))
        let offPronChars = off; off += pronCount * 2
        try r.requireRange(0, off)

        // --- Yapısal doğrulama, form trie ile aynı disiplin ---
        try r.offsets(at: offCharOffset, count: rootCount, section: "charOffset",
                      end: charCount)

        /// `[lo, hi)` sembol aralığını yüzeye çevirir; sınırlar doğrulandı.
        func surface(root i: Int, bounds: Int, chars: Int) throws -> String {
            let lo = Int(r.unchecked(UInt32.self, bounds + i * 4))
            let hi = Int(r.unchecked(UInt32.self, bounds + (i + 1) * 4))
            var out: [Character] = []
            out.reserveCapacity(hi - lo)
            for c in lo..<hi {
                let sym = r.unchecked(UInt16.self, chars + c * 2)
                guard Int(sym) < alphabetSize else {
                    throw PackError.symbolOutOfRange(index: i, symbol: sym, alphabetSize: alphabetSize)
                }
                out.append(Character(alpha[Int(sym)]))
            }
            return String(out)
        }

        var out: [Root] = []
        out.reserveCapacity(rootCount)
        for i in 0..<rootCount {
            let text = try surface(root: i, bounds: offCharOffset, chars: offChars)
            let posRaw = r.unchecked(UInt8.self, offPOS + i)
            guard let pos = Root.POS(rawValue: posRaw) else { throw PackError.badPOS(posRaw) }
            let flags = r.unchecked(UInt16.self, offFlags + i * 2)
            let cost = Double(Float(bitPattern: r.unchecked(UInt32.self, offLexCost + i * 4)))
            let spoken = try surface(root: i, bounds: offPronOffset, chars: offPronChars)
            out.append(Root(text, pos: pos, lexCost: cost,
                            finalAlternation: Self.alternation(fromFlags: flags),
                            dropsVowel: flags & 0b1000 != 0,
                            aoristClass: Root.AoristClass(
                                rawValue: UInt8((flags >> 4) & 0b11)) ?? .unknown,
                            causativeClass: Root.CausativeClass(
                                rawValue: UInt8((flags >> 6) & 0b11)) ?? .unknown,
                            pronunciation: spoken.isEmpty ? nil : spoken))
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

    // MARK: - Kaynak dosyasının adları

    /// Kök sözlüğü kaynağının (`roots.tsv`) sütun değerleri — yukarıdaki ikili
    /// bayrak kodlarının **metin** karşılığı, onların yanında. Paket üreticisi
    /// bunları kendi içinde eşliyordu; bir sınıf eklendiğinde bayrak kodu
    /// burada, adı orada güncellenmek zorundaydı.
    public enum SourceNames {
        public static let pos: [String: Root.POS] = [
            "noun": .noun, "verb": .verb,
            "adjective": .adjective, "adj": .adjective,
            "adverb": .adverb, "adv": .adverb,
            "proper": .proper,
        ]
        /// `none` → alternasyon yok. **Sözlükseldir**: `çocuk→çocuğu` ama
        /// `renk→rengi`; tek bir `k→ğ` kuralı `renği` üretirdi.
        public static let alternation: [String: Phonology.Alternation?] = [
            "none": nil, "pToB": .pToB, "cToC": .çToC, "tToD": .tToD,
            "kToG": .kToG, "kToGSoft": .kToĞ,
        ]
        /// Boş ya da `unknown` → sınıf bilinmiyor (üretme, tahmin etme).
        public static let aorist: [String: Root.AoristClass] = [
            "ar": .ar, "ir": .ir, "": .unknown, "unknown": .unknown,
        ]
        public static let causative: [String: Root.CausativeClass] = [
            "dir": .dir, "t": .t, "ir": .ir, "": .unknown, "unknown": .unknown,
        ]
    }

    // MARK: - Yazma

    /// Kök listesini binary'ye serileştirir.
    public static func build(roots: [Root]) -> [UInt8] {
        let alphabet = ScalarAlphabet(roots.flatMap { r in
            r.surface.flatMap(\.unicodeScalars).map(\.value)
                + (r.pronunciation ?? "").unicodeScalars.map(\.value)
        })

        /// Yüzeyi sembol dizisine çevirir: karakter başına ilk skaler.
        func symbols<S: Sequence>(_ text: S, into out: inout [UInt16])
            where S.Element == Character {
            for c in text {
                guard let sc = c.unicodeScalars.first,
                      let sym = alphabet.symbolOf[sc.value] else { continue }
                out.append(sym)
            }
        }

        var charOffset: [UInt32] = [0]
        var chars: [UInt16] = []
        var pronOffset: [UInt32] = [0]
        var pronChars: [UInt16] = []
        for r in roots {
            symbols(r.surface, into: &chars)
            charOffset.append(UInt32(chars.count))
            symbols(r.pronunciation ?? "", into: &pronChars)
            pronOffset.append(UInt32(pronChars.count))
        }

        let format = RootPackFormat.container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(roots.count))
            w.u32(UInt32(chars.count))
            w.u16(UInt16(alphabet.count))
            w.u16(UInt16(roots.map(\.surface.count).max() ?? 0))
            w.u32(0)                                  // reserved
        }
        w.alphabet(alphabet.values)
        for v in charOffset { w.u32(v) }
        for v in chars { w.u16(v) }
        for r in roots { w.u8(r.pos.rawValue) }
        for r in roots { w.u16(flags(for: r)) }
        for r in roots { w.f32(Float(r.lexCost)) }
        for v in pronOffset { w.u32(v) }
        for v in pronChars { w.u16(v) }
        return format.seal(w)
    }
}

public extension Root.POS {
    /// Kaynak dosyadaki adından (`noun`, `adj`, …).
    init?(name: String) {
        guard let pos = RootPack.SourceNames.pos[name] else { return nil }
        self = pos
    }
}
