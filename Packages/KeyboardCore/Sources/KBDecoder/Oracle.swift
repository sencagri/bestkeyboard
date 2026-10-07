import Foundation
import KBGeometry
import KBLexicon
import KBSpatial

/// Exhaustive oracle — skor sözleşmesi §5.
///
/// Beam'in karşılaştırılacağı **tam** arama. Leksikondaki her kelime için
/// hizalamalar üzerinde tam DP koşar; budama yoktur.
///
/// Sözleşme §5.4/1: sonlu bir beam genişliğinde eşitlik tamlık kanıtı değildir,
/// bu yüzden model eşdeğerliği testi **budamasız** bu oracle'a karşı koşulur.
public struct Oracle: UnitCosts {
    public let layout: KeyLayout
    public let spatial: SpatialModel
    public let weights: ScoreWeights
    /// Kelime bigramı ve bağlam — decoder'la **aynı** olmalı.
    ///
    /// Oracle bir referans, taklit değil: modelde olan her terim burada da
    /// olmalı, yoksa §5.4/1 eşdeğerlik kapısı `F_ctx` eklendiği anda kırılır ve
    /// fark "beam yanlış" diye okunur. Aynı hata §8.5'te gayrıresmî insertion
    /// sınıfı eklenirken bir kez yapıldı; eşdeğerlik testi ayrışmayı yakaladı.
    public var bigrams: BigramPack?
    public var contextWord: String?

    public init(layout: KeyLayout, spatial: SpatialModel, weights: ScoreWeights,
                bigrams: BigramPack? = nil, contextWord: String? = nil) {
        self.layout = layout
        self.spatial = spatial
        self.weights = weights
        self.bigrams = bigrams
        self.contextWord = contextWord
    }

    /// `F_ctx(w | ctx)` — decoder ile aynı kural, aynı geri düşüş (0).
    func contextDelta(_ word: String) -> Double {
        guard let pack = bigrams, let ctx = contextWord,
              let c = pack.id(of: ctx), let w = pack.id(of: word) else { return 0 }
        return pack.delta(context: c, word: w)
    }

    /// Sabit bir kelime için `min_A cost(w, A | T)` + terminal leksikal maliyet.
    /// `lexCost` ham `F_lex`'tir; burada `w_lex` ile çarpılır (§7.1).
    public func cost(word: String, touches: [TouchSample], lexCost: Double) -> Double {
        let c = Array(word.precomposedStringWithCanonicalMapping)
        let m = c.count
        let n = touches.count
        let inf = Double.infinity

        // D[i][j], i dokunma × j karakter.
        var d = [[Double]](repeating: [Double](repeating: inf, count: m + 1), count: n + 1)
        d[0][0] = 0

        // Saf insertion zinciri.
        if n >= 1 {
            for i in 1...n { d[i][0] = d[i - 1][0] + ins(i, touches) }
        }
        // Saf omission zinciri.
        if m >= 1 {
            for j in 1...m { d[0][j] = d[0][j - 1] + om(j, c) + weights.wLen }
        }

        if n >= 1 && m >= 1 {
            for i in 1...n {
                for j in 1...m {
                    var best = inf
                    // SUB / SUB_eq
                    if d[i - 1][j - 1].isFinite {
                        best = min(best, d[i - 1][j - 1] + sub(i, j, c, touches) + weights.wLen)
                    }
                    // OM (dokunma tüketmez)
                    if d[i][j - 1].isFinite {
                        best = min(best, d[i][j - 1] + om(j, c) + weights.wLen)
                    }
                    // INS (emisyon yapmaz)
                    if d[i - 1][j].isFinite {
                        best = min(best, d[i - 1][j] + ins(i, touches, lastChar: c[j - 1]))
                    }
                    // TR
                    if i >= 2, j >= 2, d[i - 2][j - 2].isFinite {
                        best = min(best, d[i - 2][j - 2] + tr(i, j, c, touches) + 2 * weights.wLen)
                    }
                    d[i][j] = best
                }
            }
        }

        // `F_ctx` terminal (§3.2): hizalamadan bağımsız, kabul anında bir kez.
        return d[n][m] + weights.wLex * lexCost + weights.wCtx * contextDelta(word)
    }

    /// Tüm leksikon üzerinde en iyi `topK`.
    public func best(touches: [TouchSample],
                     lexicon: [(word: String, lexCost: Double)],
                     topK: Int = 3) -> [DecodeResult] {
        var out: [DecodeResult] = []
        out.reserveCapacity(lexicon.count)
        for entry in lexicon {
            let cst = cost(word: entry.word, touches: touches, lexCost: entry.lexCost)
            guard cst.isFinite else { continue }
            out.append(DecodeResult(word: entry.word,
                                    cost: cst,
                                    emitCount: entry.word.count))
        }
        return out.sorted { $0.cost < $1.cost }.prefix(topK).map { $0 }
    }

    // MARK: - Birim maliyetler (§5.1)
    //
    // Formüller `UnitCosts`'ta, decoder'la **ortak**; burada yalnız DP
    // indekslerinden (`i` dokunma, `j` karakter, 1 tabanlı) onlara çeviri.

    func sub(_ i: Int, _ j: Int, _ c: [Character], _ t: [TouchSample]) -> Double {
        substitutionCost(t[i - 1], char: c[j - 1])
    }

    /// Sıralama önemli: önce `j == 1`, böylece `c_0` referanslanmaz.
    func om(_ j: Int, _ c: [Character]) -> Double {
        omissionCost(atWordStart: j == 1, repeatsPrevious: j > 1 && c[j - 1] == c[j - 2])
    }

    /// - Parameter lastChar: DP durumunda son emit edilen karakter — `d[i][j]`
    ///   için `c[j-1]`, `j == 0` ise yok.
    func ins(_ i: Int, _ t: [TouchSample], lastChar: Character? = nil) -> Double {
        insertionCost(t[i - 1], previous: i >= 2 ? t[i - 2] : nil, lastChar: lastChar)
    }

    /// `tr(i,j) = w_tr − log p(t_{i−1}|key(c_j)) − log p(t_i|key(c_{j−1}))`
    func tr(_ i: Int, _ j: Int, _ c: [Character], _ t: [TouchSample]) -> Double {
        guard let kPrev = layout.keyIndex(for: c[j - 2]),
              let kCur = layout.keyIndex(for: c[j - 1]) else { return .infinity }
        return weights.wTr + transpositionSpatialCost(earlier: t[i - 2], later: t[i - 1],
                                                      firstKey: kPrev, secondKey: kCur)
    }
}
