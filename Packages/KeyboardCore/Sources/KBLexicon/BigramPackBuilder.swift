import Foundation

/// `.bkg` üreticisi — sözleşme §2 öznitelik 13 (`F_ctx`).
///
/// Girdi **sayımlar**: `(ctx, w) → c(ctx,w)` ve `w → c(w)`. Delta paketin kendi
/// içinde hesaplanıyor, dışarıdan olasılık alınmıyor — iki ayrı korpusun
/// normalizasyonunu karıştırmak §2.1'i ihlal ederdi.
///
/// ```
/// F_ctx(w|ctx) = −log P̂(w|ctx) + log P̂(w)
///              = −log( c(ctx,w) / c(ctx) ) + log( c(w) / N )
/// ```
public struct BigramPackBuilder {

    /// Bir çiftin pakete girmesi için gereken en az sayım.
    ///
    /// **Gürültüye karşı asıl savunma bu**, kırpma değil: tek kez görülmüş bir
    /// çiftin log-oranı korpusun büyüklüğü kadar büyük olabilir ve o değer
    /// veriden değil örneklem kazasından gelir. Eşik veriyle birlikte
    /// kalibre edilecek; bugünkü değer bir başlangıç noktası.
    public static let minPairCount = 2

    /// Deltanın mutlak sınırı — **arka duruş**, model değil.
    ///
    /// Leksikal maliyet dağılımının tamamı ~11 nat genişliğinde (tr-TR: 3.66 …
    /// 14.57). Tek bir bağlam teriminin bu genişliği aşması, `F_ctx`'in `F_lex`
    /// üzerine **delta** olduğu iddiasını boşa çıkarırdı: bağlam sıralamayı
    /// çevirebilmeli, tek başına belirlememeli. Sınıra dayanan çiftler
    /// `clamped` olarak raporlanıyor — sessizce kırpmak, veriyi modelmiş gibi
    /// göstermek olurdu.
    public static let deltaBound = 6.0

    public struct Report: Equatable, Sendable {
        public let surfaces: Int
        public let pairs: Int
        /// Sayımı eşiğin altında kaldığı için düşen çiftler.
        public let droppedRare: Int
        /// Sınıra dayandığı için kırpılan çiftler.
        public let clamped: Int
    }

    public enum BuildError: Error, CustomStringConvertible {
        case emptyInput
        case unknownSurface(String)
        case invalidCount(pair: String, count: Double)

        public var description: String {
            switch self {
            case .emptyInput: return "boş girdi"
            case let .unknownSurface(s): return "unigram sayımı olmayan yüzey: '\(s)'"
            case let .invalidCount(p, c): return "geçersiz sayım: '\(p)' = \(c)"
            }
        }
    }

    public init() {}

    /// - Parameter unigrams: `w → c(w)`. Bigram korpusunun **kendi** sayımları
    ///   olmalı; form listesinin frekansları değil.
    /// - Parameter bigrams: `(ctx, w) → c(ctx,w)`.
    public func build(unigrams: [String: Double],
                      bigrams: [BigramCount]) throws -> (bytes: [UInt8], report: Report) {
        guard !unigrams.isEmpty else { throw BuildError.emptyInput }
        for (w, c) in unigrams where !(c.isFinite && c > 0) {
            throw BuildError.invalidCount(pair: w, count: c)
        }
        let total = unigrams.values.reduce(0, +)
        guard total.isFinite, total > 0 else { throw BuildError.emptyInput }

        // Bağlam sayımı `c(ctx)` bigramlardan **türetiliyor**, unigramdan değil:
        // `P̂(w|ctx)` payda olarak o bağlamda görülen toplam devam sayısını
        // ister. Unigram sayımını kullanmak, korpus kenarındaki (son kelime)
        // gözlemleri paydaya katıp olasılıkları sistematik olarak küçültürdü.
        var contextTotals: [String: Double] = [:]
        for b in bigrams {
            guard b.count.isFinite, b.count > 0 else {
                throw BuildError.invalidCount(pair: "\(b.context) \(b.word)", count: b.count)
            }
            contextTotals[b.context, default: 0] += b.count
        }

        var droppedRare = 0, clamped = 0
        var deltas: [(context: String, word: String, delta: Double)] = []
        for b in bigrams {
            guard b.count >= Double(Self.minPairCount) else { droppedRare += 1; continue }
            guard let cw = unigrams[b.word] else { throw BuildError.unknownSurface(b.word) }
            guard let ctxTotal = contextTotals[b.context], ctxTotal > 0 else { continue }
            let conditional = b.count / ctxTotal
            let marginal = cw / total
            var delta = -log(conditional) + log(marginal)
            if abs(delta) > Self.deltaBound {
                delta = delta > 0 ? Self.deltaBound : -Self.deltaBound
                clamped += 1
            }
            deltas.append((b.context, b.word, delta))
        }

        // Yüzey tablosu: bağlam **ve** hedef yüzeylerin birleşimi, sıralı.
        // Tek tablo, çünkü bir kelime hem bağlam hem hedef olabiliyor ve iki
        // tablo tutmak aynı stringi iki kez saklamak olurdu.
        var surfaceSet = Set<String>()
        for d in deltas { surfaceSet.insert(d.context); surfaceSet.insert(d.word) }
        // Sıralama **UTF-8 bayt sırasına** göre: okuyucu ikili aramayı bayt
        // karşılaştırmasıyla yapıyor ve Swift'in `String` sırası ondan farklı.
        let surfaces = surfaceSet.map { (s: $0, b: Array($0.utf8)) }
            .sorted { $0.b.lexicographicallyPrecedes($1.b) }
            .map(\.s)
        var idOf: [String: UInt32] = [:]
        for (i, s) in surfaces.enumerated() { idOf[s] = UInt32(i) }

        // Çiftler bağlam kimliğine göre gruplanıp hedef kimliğine göre sıralı.
        var byContext = [[(word: UInt32, delta: Float)]](repeating: [], count: surfaces.count)
        for d in deltas {
            guard let c = idOf[d.context], let w = idOf[d.word] else { continue }
            byContext[Int(c)].append((w, Float(d.delta)))
        }
        for i in byContext.indices {
            byContext[i].sort { $0.word < $1.word }
            // Aynı çift iki kez verilmişse sonuncusu kalır; ikili arama tekillik
            // varsayıyor ve doğrulama da onu istiyor.
            var deduped: [(word: UInt32, delta: Float)] = []
            for p in byContext[i] {
                if deduped.last?.word == p.word { deduped[deduped.count - 1] = p }
                else { deduped.append(p) }
            }
            byContext[i] = deduped
        }
        let pairCount = byContext.reduce(0) { $0 + $1.count }

        let format = BigramPack.container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(surfaces.count))
            w.u32(UInt32(pairCount))
            w.u32(0); w.u32(0)                        // reserved
        }

        var blob: [UInt8] = []
        var surfaceOffsets: [UInt32] = [0]
        for s in surfaces {
            blob.append(contentsOf: Array(s.utf8))
            surfaceOffsets.append(UInt32(blob.count))
        }
        for v in surfaceOffsets { w.u32(v) }
        w.append(contentsOf: blob)

        var ctxOffsets: [UInt32] = [0]
        var running: UInt32 = 0
        for group in byContext {
            running += UInt32(group.count)
            ctxOffsets.append(running)
        }
        for v in ctxOffsets { w.u32(v) }
        for group in byContext { for p in group { w.u32(p.word) } }
        for group in byContext { for p in group { w.f32(p.delta) } }

        return (format.seal(w), Report(surfaces: surfaces.count, pairs: pairCount,
                                droppedRare: droppedRare, clamped: clamped))
    }
}

public struct BigramCount: Sendable, Equatable {
    public let context: String
    public let word: String
    public let count: Double
    public init(context: String, word: String, count: Double) {
        self.context = context
        self.word = word
        self.count = count
    }
}
