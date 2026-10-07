import Foundation
import KBGeometry

/// Kelime bigramı paketi — skor sözleşmesi §2 öznitelik 13 (`F_ctx`).
///
/// ## Ne saklıyor: **delta**, olasılık değil
///
/// `F_ctx = −log P̂(w | ctx, ℓ) + log P̂(w | ℓ)`. Paket bu farkı **doğrudan**
/// saklıyor, iki olasılığı ayrı ayrı değil. Sebep §2.1 tek sahiplik kuralı:
/// unigram kütlesinin sahibi `F_lex` ve `F_ctx` onun **üzerine** delta. İki
/// olasılık ayrı saklansaydı çalışma anında `log P̂(w|ℓ)` bigram korpusundan,
/// `F_lex` ise form listesinden gelirdi — iki ayrı normalizasyon, ve fark
/// anlamsız olurdu. Aynı hata argo katmanını ayrı kaynak olarak yüklerken bir
/// kez yapıldı.
///
/// Delta paketin **kendi içinde** hesaplanıyor: `log P̂(w) − log P̂(w|ctx)`,
/// ikisi de aynı korpustan. Böylece form listesi başka bir korpustan gelse bile
/// delta iyi tanımlı kalıyor.
///
/// ## Görülmemiş çift → 0
///
/// Kayıtlı olmayan `(ctx, w)` için `F_ctx = 0`, yani "bağlam bir şey söylemiyor".
/// Olasılıksal olarak görülmemiş bir bigram unigram'dan **daha az** olası olmalı
/// (yani `F_ctx > 0`), ama o cezanın büyüklüğü veriden gelmiyor. Kanıtın
/// yokluğunda cezalandırmamak §5c asimetrisiyle uyumlu: gereksiz koruma
/// zararsız, gereksiz ceza kelimeyi kaybettirir.
///
/// ## Neden ayrıştırılmıyor
///
/// §11.A: paket mmap'lenip **olduğu gibi** okunuyor. Yüzey → kimlik eşlemesi
/// için `[String: UInt32]` sözlüğü kurmak yükleme anında yüz binlerce string
/// tahsisi demekti; onun yerine yüzey tablosu **sıralı** duruyor ve arama
/// bayt karşılaştırmalı ikili arama. Token başına en fazla birkaç sorgu var
/// (bağlam bir kez, adaylar yalnız materyalize edilirken), o yüzden `log n`
/// bedeli ölçülebilir bir yere düşmüyor.
///
/// ```
/// Başlık (32 bayt)
///   0  magic         u32   "BKG1"
///   4  version       u16
///   6  flags         u16
///   8  surfaceCount  u32
///  12  pairCount     u32
///  16  reserved      u32
///  20  reserved      u32
///  24  checksum      u64   FNV-1a, yük üzerinden
///
/// Yük
///   surfaceOffset : (surfaceCount+1) × u32   blob içine offset
///   surfaceBlob   : utf8 baytlar, **sıralı** (UTF-8 bayt sırası)
///   ctxOffset     : (surfaceCount+1) × u32   çift dizisine aralık
///   pairWord      : pairCount × u32          hedef yüzey kimliği, aralık içinde sıralı
///   pairDelta     : pairCount × f32          F_ctx
/// ```
public struct BigramPack: Sendable {

    public static let magic: UInt32 = 0x3147_4B42   // "BKG1"
    public static let version: UInt16 = 1
    public static let headerSize = 32

    public let surfaceCount: Int
    public let pairCount: Int

    private let data: Data
    private let offSurfaceOffset: Int
    private let offSurfaceBlob: Int
    private let offCtxOffset: Int
    private let offPairWord: Int
    private let offPairDelta: Int

    public enum StructureError: Error, CustomStringConvertible {
        case offsetNotMonotone(section: String, index: Int)
        case offsetEndMismatch(section: String, last: UInt32, expected: Int)
        case surfaceNotSorted(index: Int)
        case pairWordOutOfRange(index: Int, word: UInt32)
        case pairsNotSorted(context: Int, index: Int)
        case badUTF8(index: Int)

        public var description: String {
            switch self {
            case let .offsetNotMonotone(s, i):     return "\(s) offset monoton değil: [\(i)]"
            case let .offsetEndMismatch(s, l, e):  return "\(s) offset sonu \(l), \(e) olmalı"
            case let .surfaceNotSorted(i):         return "yüzey tablosu sıralı değil: [\(i)]"
            case let .pairWordOutOfRange(i, w):    return "çift \(i): yüzey kimliği \(w) sınır dışında"
            case let .pairsNotSorted(c, i):        return "bağlam \(c) içindeki çiftler sıralı değil: [\(i)]"
            case let .badUTF8(i):                  return "geçersiz UTF-8: yüzey [\(i)]"
            }
        }
    }

    public init(packData: Data, verifyChecksum: Bool = true) throws {
        let r = ByteReader([UInt8](packData))
        let magic = try r.u32(0)
        guard magic == Self.magic else { throw ByteReader.Error.badMagic(magic) }
        let version = try r.u16(4)
        guard version == Self.version else { throw ByteReader.Error.badVersion(version) }

        let surfaceCount = Int(try r.u32(8))
        let pairCount = Int(try r.u32(12))
        let checksum = try r.u64(24)

        if verifyChecksum {
            let actual = FNV1a.hash(r.bytes[Self.headerSize...])
            guard actual == checksum else {
                throw ByteReader.Error.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        var off = Self.headerSize
        let offSurfaceOffset = off; off += (surfaceCount + 1) * 4
        let blobBytes = Int(try r.u32(offSurfaceOffset + surfaceCount * 4))
        let offSurfaceBlob = off; off += blobBytes
        let offCtxOffset = off;   off += (surfaceCount + 1) * 4
        let offPairWord = off;    off += pairCount * 4
        let offPairDelta = off;   off += pairCount * 4
        guard off <= packData.count else {
            throw ByteReader.Error.outOfBounds(offset: off, need: 0, have: packData.count)
        }

        // --- Yapısal invariantlar ---
        //
        // Sıcak yol ikili arama yapıyor: sıralı olmayan bir tablo sessizce
        // **yanlış kelimeyi** bulur (çökme yok, hatalı bağlam var). Checksum
        // bozulmayı yakalar, üretim hatasını yakalamaz.
        func u32(_ o: Int) throws -> UInt32 { try r.u32(o) }

        func checkMonotone(_ section: String, _ base: Int) throws -> UInt32 {
            var prev: UInt32 = 0
            guard try u32(base) == 0 else {
                throw StructureError.offsetNotMonotone(section: section, index: 0)
            }
            for i in 1...(surfaceCount + 1) - 1 where surfaceCount > 0 {
                let cur = try u32(base + i * 4)
                guard cur >= prev else {
                    throw StructureError.offsetNotMonotone(section: section, index: i)
                }
                prev = cur
            }
            return prev
        }
        _ = try checkMonotone("surface", offSurfaceOffset)
        let lastCtx = try checkMonotone("ctx", offCtxOffset)
        guard Int(lastCtx) == pairCount else {
            throw StructureError.offsetEndMismatch(section: "ctx", last: lastCtx,
                                                   expected: pairCount)
        }

        self.data = packData
        self.surfaceCount = surfaceCount
        self.pairCount = pairCount
        self.offSurfaceOffset = offSurfaceOffset
        self.offSurfaceBlob = offSurfaceBlob
        self.offCtxOffset = offCtxOffset
        self.offPairWord = offPairWord
        self.offPairDelta = offPairDelta

        // Yüzeylerin sıralılığı ve çiftlerin sınırları — arama buna dayanıyor.
        for i in 0..<surfaceCount {
            guard let s = surface(i) else { throw StructureError.badUTF8(index: i) }
            if i > 0, let p = surface(i - 1), !(Array(p.utf8).lexicographicallyPrecedes(Array(s.utf8))) {
                throw StructureError.surfaceNotSorted(index: i)
            }
        }
        for c in 0..<surfaceCount {
            var last: UInt32?
            for j in pairRange(c) {
                let w = try u32(offPairWord + j * 4)
                guard Int(w) < surfaceCount else {
                    throw StructureError.pairWordOutOfRange(index: j, word: w)
                }
                if let l = last, w <= l {
                    throw StructureError.pairsNotSorted(context: c, index: j)
                }
                last = w
            }
        }
    }

    // MARK: - Sıcak yol

    @inline(__always) private func u32(_ o: Int) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(raw[o + i]) << (8 * UInt32(i)) }
            return v
        }
    }

    private func pairRange(_ context: Int) -> Range<Int> {
        Int(u32(offCtxOffset + context * 4))..<Int(u32(offCtxOffset + (context + 1) * 4))
    }

    /// Yüzey tablosundaki `i`. Blob'dan **kopya** üretir; yalnız doğrulama ve
    /// teşhis yolunda çağrılıyor, sıcak yolda değil.
    public func surface(_ i: Int) -> String? {
        guard i >= 0, i < surfaceCount else { return nil }
        let lo = Int(u32(offSurfaceOffset + i * 4))
        let hi = Int(u32(offSurfaceOffset + (i + 1) * 4))
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let base = offSurfaceBlob
            let slice = UnsafeRawBufferPointer(rebasing: raw[(base + lo)..<(base + hi)])
            return String(bytes: slice, encoding: .utf8)
        }
    }

    /// Yüzeyin kimliği — sıralı tabloda ikili arama, **string tahsisi yok**.
    public func id(of surface: String) -> UInt32? {
        let needle = Array(surface.precomposedStringWithCanonicalMapping.utf8)
        var lo = 0, hi = surfaceCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cmp = compare(mid, needle)
            if cmp == 0 { return UInt32(mid) }
            if cmp < 0 { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// `surface(mid)` ile `needle` karşılaştırması: <0, 0, >0.
    private func compare(_ index: Int, _ needle: [UInt8]) -> Int {
        let lo = Int(u32(offSurfaceOffset + index * 4))
        let hi = Int(u32(offSurfaceOffset + (index + 1) * 4))
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            let base = offSurfaceBlob + lo
            let n = hi - lo
            let m = min(n, needle.count)
            for k in 0..<m {
                let a = raw[base + k], b = needle[k]
                if a != b { return a < b ? -1 : 1 }
            }
            if n == needle.count { return 0 }
            return n < needle.count ? -1 : 1
        }
    }

    /// `F_ctx(w | ctx)` — kayıtlı değilse **0** (bağlam bir şey söylemiyor).
    public func delta(context: UInt32, word: UInt32) -> Double {
        let c = Int(context)
        guard c >= 0, c < surfaceCount else { return 0 }
        var lo = Int(u32(offCtxOffset + c * 4))
        var hi = Int(u32(offCtxOffset + (c + 1) * 4)) - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let w = u32(offPairWord + mid * 4)
            if w == word {
                return Double(Float(bitPattern: u32(offPairDelta + mid * 4)))
            }
            if w < word { lo = mid + 1 } else { hi = mid - 1 }
        }
        return 0
    }

    /// Yüzeyden yüzeye — teşhis ve test yolu.
    public func delta(context: String, word: String) -> Double {
        guard let c = id(of: context), let w = id(of: word) else { return 0 }
        return delta(context: c, word: w)
    }
}
