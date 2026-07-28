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
public struct Oracle {
    public let layout: KeyLayout
    public let spatial: SpatialModel
    public let weights: ScoreWeights

    public init(layout: KeyLayout, spatial: SpatialModel, weights: ScoreWeights) {
        self.layout = layout
        self.spatial = spatial
        self.weights = weights
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
                        best = min(best, d[i - 1][j] + ins(i, touches))
                    }
                    // TR
                    if i >= 2, j >= 2, d[i - 2][j - 2].isFinite {
                        best = min(best, d[i - 2][j - 2] + tr(i, j, c, touches) + 2 * weights.wLen)
                    }
                    d[i][j] = best
                }
            }
        }

        return d[n][m] + weights.wLex * lexCost
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

    /// `sub(i,j) = min(sub_direct, sub_eq)` — §2.3.
    ///
    /// İki seçenek **bağımsız**: doğrudan tuş yoksa bile `base(c)` tanımlıysa
    /// `SUB_eq` yasaldır (Türkçe leksikonu ASCII-only layout'ta kullanma durumu).
    func sub(_ i: Int, _ j: Int, _ c: [Character], _ t: [TouchSample]) -> Double {
        let ch = c[j - 1]
        var best = Double.infinity
        if let directKey = layout.keyIndex(for: ch) {
            best = spatial.negLogP(t[i - 1], keyIndex: directKey)   // w_spa ≡ 1
        }
        if let baseKey = layout.asciiBaseKeyIndex(for: ch) {
            best = min(best, weights.wSpaEq * spatial.negLogP(t[i - 1], keyIndex: baseKey) + weights.wEq)
        }
        return best
    }

    /// `om(j)` — sıralama önemli: önce `j == 1`, böylece `c_0` referanslanmaz.
    func om(_ j: Int, _ c: [Character]) -> Double {
        if j == 1 { return weights.wOmInit }
        return c[j - 1] == c[j - 2] ? weights.wOmGem : weights.wOm
    }

    /// `ins(i)` — `i == 1` daima normal sınıf (`t_0` yok).
    func ins(_ i: Int, _ t: [TouchSample]) -> Double {
        let bg = weights.wInsBg * spatial.negLogPBackground(t[i - 1])
        if i == 1 { return weights.wIns + bg }
        let cur = t[i - 1], prev = t[i - 2]
        let dt = cur.timestamp - prev.timestamp
        let dx = cur.down.x - prev.down.x, dy = cur.down.y - prev.down.y
        let dist = (dx * dx + dy * dy).squareRoot()
        return ((dt < weights.tauFast && dist < weights.dNear) ? weights.wInsNear : weights.wIns) + bg
    }

    /// `tr(i,j) = w_tr − log p(t_{i−1}|key(c_j)) − log p(t_i|key(c_{j−1}))`
    func tr(_ i: Int, _ j: Int, _ c: [Character], _ t: [TouchSample]) -> Double {
        guard let kPrev = layout.keyIndex(for: c[j - 2]),
              let kCur = layout.keyIndex(for: c[j - 1]) else { return .infinity }
        return weights.wTr
            + spatial.negLogP(t[i - 2], keyIndex: kCur)
            + spatial.negLogP(t[i - 1], keyIndex: kPrev)
    }
}
