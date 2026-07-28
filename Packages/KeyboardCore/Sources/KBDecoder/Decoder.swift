import Foundation
import KBGeometry
import KBLexicon
import KBSpatial

/// Decoder state — skor sözleşmesi §4.
///
/// **Not (belge düzeltmesi):** sözleşme §4'te "52 bit, tek UInt64'e sığar" deniyor;
/// bu yalnız `surfaceId ≡ node` olan **form trie** durumu için doğrudur. Morfoloji
/// kaynağında `surfaceId` ayrı 32 bit gerektirir ve toplam 84 bite çıkar.
public struct DecoderStateKey: Hashable, Sendable {
    public var automaton: UInt8
    public var language: UInt8
    public var node: UInt32
    /// Yüzey öneki kimliği (§4.2). Form trie'de `node` ile aynıdır.
    public var surfaceId: UInt32
    public var touchIndex: UInt16
    /// Önceki yüzey **pozisyonunun** sembolü (§4.1) — son fiziksel emisyon değil.
    public var lastSurfaceSymbol: UInt16
    public var atWordStart: Bool
}

/// Bir geçişin ürettiği emisyon. `TR` atomiktir (§4.4: "yarım TR durumu yok") —
/// bu kural veri yapısında da ifade edilir, ara düğüm hilesi yoktur.
enum Emission: Sendable {
    case none
    case one(UInt16)
    /// Yüzey sırasıyla `(c_{j−1}, c_j)`.
    case two(UInt16, UInt16)
}

struct BeamEntry {
    var key: DecoderStateKey
    var cost: Double
    var parent: Int32          // arena indeksi, -1 = kök
    var emission: Emission
    var emitCount: UInt16      // F_len
}

public struct DecodeResult: Sendable {
    public let word: String
    public let cost: Double
    public let emitCount: Int
}

/// Sıraya sadık beam search — skor sözleşmesi §0/§5.
///
/// `cost(w) = min_A cost(w, A | T)` — Viterbi, **skorun tanımı** (yaklaşım değil).
/// Dolayısıyla dedup'ın durum başına yalnız en iyi yolu tutması tanımı gereği doğrudur.
///
/// **Üç yuvalı frontier (§3.1):** `TR` iki dokunma tükettiği için dokunma `i`
/// geldiğinde `TR(t_{i−1}, t_i)` kaynağı `touchIndex = i−2` frontier'ıdır.
public struct Decoder {
    public let layout: KeyLayout
    public let spatial: SpatialModel
    public let trie: FormTrie
    /// **Immutable**: `w_lex > 0` gibi init'te doğrulanan invariantlar sonradan
    /// bozulamasın diye (§7.1 admissibility buna bağlı).
    public let weights: ScoreWeights
    public let beamWidth: Int

    /// Test kancaları — üretimde ikisi de `false`.
    /// `disableDedup` ile durum birleştirme kapatılır; `disablePruning` ile beam
    /// genişliği sınırsız olur. Sözleşme §5.4/1 ve /2 bunları gerektirir.
    public let disableDedup: Bool
    public let disablePruning: Bool

    public init(layout: KeyLayout,
                spatial: SpatialModel,
                trie: FormTrie,
                weights: ScoreWeights = ScoreWeights(),
                beamWidth: Int = 128,
                disableDedup: Bool = false,
                disablePruning: Bool = false) {
        precondition(weights.satisfiesLexPositivity, "w_lex > 0 kısıtı ihlal edildi (§7.1)")
        self.layout = layout
        self.spatial = spatial
        self.trie = trie
        self.weights = weights
        self.beamWidth = beamWidth
        self.disableDedup = disableDedup
        self.disablePruning = disablePruning
    }

    static let noSymbol: UInt16 = 0xFFFF

    /// Tüm diziyi bir seferde çözer. Artımlı API ile **birebir aynı** sonucu
    /// vermelidir (§5.4/3 test kapısı).
    public func decode(touches: [TouchSample], topK: Int = 3) -> [DecodeResult] {
        var inc = IncrementalDecoder(decoder: self)
        for t in touches { inc.append(t) }
        return inc.results(topK: topK)
    }

    // MARK: - Aday maliyetleri

    /// `sub(i,j) = min(sub_direct, sub_eq)` — §2.3.
    ///
    /// İki seçenek **bağımsız** hesaplanır: doğrudan tuş yoksa bile `base(c)`
    /// tanımlıysa `SUB_eq` yasaldır. (Türkçe leksikonu ASCII-only bir layout'ta
    /// kullanmak tam olarak bu durumdur: `ü` tuşu yok, `u` var.)
    func substitutionCost(_ t: TouchSample, char: Character) -> Double? {
        var best = Double.infinity
        if let direct = layout.keyIndex(for: char) {
            best = spatial.negLogP(t, keyIndex: direct)          // w_spa ≡ 1
        }
        if let base = layout.asciiBaseKeyIndex(for: char) {
            best = min(best, weights.wSpaEq * spatial.negLogP(t, keyIndex: base) + weights.wEq)
        }
        return best.isFinite ? best : nil
    }

    func insertionCost(_ touches: [TouchSample], _ i: Int) -> Double {
        let t = touches[i - 1]
        let bg = weights.wInsBg * spatial.negLogPBackground(t)
        guard i >= 2 else { return weights.wIns + bg }   // t_0 yok → normal sınıf (§5.1)
        let prev = touches[i - 2]
        let dt = t.timestamp - prev.timestamp
        let dx = t.down.x - prev.down.x, dy = t.down.y - prev.down.y
        let dist = (dx * dx + dy * dy).squareRoot()
        return ((dt < weights.tauFast && dist < weights.dNear) ? weights.wInsNear : weights.wIns) + bg
    }

    /// `om(j)` sınıfı — sıralama §5.1: önce kelime başı, sonra ikiz harf.
    func omissionCost(atWordStart: Bool, symbol: UInt16, lastSurfaceSymbol: UInt16) -> Double {
        if atWordStart { return weights.wOmInit }
        return symbol == lastSurfaceSymbol ? weights.wOmGem : weights.wOm
    }
}

/// Artımlı decoder — dokunmalar tek tek beslenir.
///
/// Üç yuvalı frontier (§3.1) burada görünür hale gelir: `TR` için `i−2`
/// frontier'ı canlı tutulur.
public struct IncrementalDecoder {
    let d: Decoder
    var arena: [BeamEntry] = []
    /// frontier[i] = i dokunma tüketmiş girdilerin arena indeksleri.
    var frontier: [[Int32]] = []
    var touches: [TouchSample] = []

    public init(decoder: Decoder) {
        self.d = decoder
        let rootKey = DecoderStateKey(
            automaton: AutomatonKind.formTrie.rawValue,
            language: 0,
            node: FormTrie.rootNode,
            surfaceId: FormTrie.rootNode,
            touchIndex: 0,
            lastSurfaceSymbol: Decoder.noSymbol,
            atWordStart: true)
        arena.append(BeamEntry(key: rootKey, cost: 0, parent: -1, emission: .none, emitCount: 0))
        // Kökten `OM` kapanışı: yalnız omission ile erişilen kelimeler de modelde
        // geçerlidir (oracle §5.2'de `D[0][j]` zinciri bunu tanımlar).
        frontier = [closeOmissions([0])]
    }

    public mutating func append(_ t: TouchSample) {
        touches.append(t)
        let i = touches.count
        var produced: [Int32] = []

        for slot in frontier[i - 1] {
            expandConsuming(from: slot, touchIndex: i, into: &produced)
        }
        if i >= 2 {
            for slot in frontier[i - 2] {
                expandTransposition(from: slot, touchIndex: i, into: &produced)
            }
        }

        produced = dedupAndPrune(produced)
        produced = closeOmissions(produced)
        frontier.append(dedupAndPrune(produced))
    }

    public func results(topK: Int = 3) -> [DecodeResult] {
        var best: [String: DecodeResult] = [:]
        for slot in frontier[frontier.count - 1] {
            let e = arena[Int(slot)]
            guard e.cost.isFinite, d.trie.isTerminal(e.key.node) else { continue }
            let total = e.cost + d.weights.wLex * d.trie.nodeTermExtra(e.key.node)
            let word = reconstruct(Int(slot))
            if let cur = best[word], cur.cost <= total { continue }
            best[word] = DecodeResult(word: word, cost: total, emitCount: Int(e.emitCount))
        }
        return best.values.sorted { $0.cost < $1.cost }.prefix(topK).map { $0 }
    }

    // MARK: - Geçişler

    private mutating func expandConsuming(from slot: Int32, touchIndex i: Int, into out: inout [Int32]) {
        let e = arena[Int(slot)]
        let t = touches[i - 1]

        // --- SUB / SUB_eq ---
        for arc in d.trie.arcRange(e.key.node) {
            let sym = d.trie.arcSymbol(arc)
            guard let cost = d.substitutionCost(t, char: d.trie.character(sym)) else { continue }
            let target = d.trie.arcTarget(arc)
            let key = DecoderStateKey(
                automaton: e.key.automaton,
                language: e.key.language,
                node: target,
                surfaceId: target,                 // form trie: surfaceId ≡ node (§4.2)
                touchIndex: UInt16(i),
                lastSurfaceSymbol: sym,            // §4.1
                atWordStart: false)
            arena.append(BeamEntry(
                key: key,
                cost: e.cost + cost + d.weights.wLex * d.trie.arcLexDelta(arc) + d.weights.wLen,
                parent: slot,
                emission: .one(sym),
                emitCount: e.emitCount + 1))
            out.append(Int32(arena.count - 1))
        }

        // --- INS: dokunma tüketir, otomat ilerlemez ---
        var insKey = e.key
        insKey.touchIndex = UInt16(i)
        arena.append(BeamEntry(key: insKey,
                               cost: e.cost + d.insertionCost(touches, i),
                               parent: slot,
                               emission: .none,
                               emitCount: e.emitCount))
        out.append(Int32(arena.count - 1))
    }

    /// `TR`: `t_{i−1}, t_i` tüketir, yüzey pozisyonları `c_{j−1}, c_j`; dokunmalar
    /// çapraz eşleşir (§2.2). Kaynak frontier `i−2`. Tek atomik beam girdisi.
    private mutating func expandTransposition(from slot: Int32, touchIndex i: Int, into out: inout [Int32]) {
        let e = arena[Int(slot)]
        let tPrev = touches[i - 2]   // t_{i−1}
        let tCur = touches[i - 1]    // t_i

        for arc1 in d.trie.arcRange(e.key.node) {
            let sym1 = d.trie.arcSymbol(arc1)          // c_{j−1}
            let node1 = d.trie.arcTarget(arc1)
            guard let k1 = d.layout.keyIndex(for: d.trie.character(sym1)) else { continue }

            for arc2 in d.trie.arcRange(node1) {
                let sym2 = d.trie.arcSymbol(arc2)      // c_j
                let node2 = d.trie.arcTarget(arc2)
                guard let k2 = d.layout.keyIndex(for: d.trie.character(sym2)) else { continue }

                // Çapraz: t_{i−1} → c_j , t_i → c_{j−1}
                let spa = d.spatial.negLogP(tPrev, keyIndex: k2)
                        + d.spatial.negLogP(tCur, keyIndex: k1)
                let lex = d.weights.wLex * (d.trie.arcLexDelta(arc1) + d.trie.arcLexDelta(arc2))

                let key = DecoderStateKey(
                    automaton: e.key.automaton,
                    language: e.key.language,
                    node: node2,
                    surfaceId: node2,
                    touchIndex: UInt16(i),
                    lastSurfaceSymbol: sym2,          // yüzey pozisyonu olarak son olan (§4.1)
                    atWordStart: false)
                arena.append(BeamEntry(
                    key: key,
                    cost: e.cost + d.weights.wTr + spa + lex + 2 * d.weights.wLen,
                    parent: slot,
                    emission: .two(sym1, sym2),
                    emitCount: e.emitCount + 2))
                out.append(Int32(arena.count - 1))
            }
        }
    }

    /// `OM` kapanışı: dokunma tüketmeyen emisyonlar, aynı `touchIndex` içinde zincirlenir.
    ///
    /// Sonluluk **yapısaldır**: `FormTrie.init` her arkın hedefinin kaynaktan ileri
    /// olduğunu doğrular (çevrim imkânsız) ve derinlik `maxSurfaceLen` ile sınırlıdır (I1).
    /// (I2) ayrıca her emisyonun net maliyetini pozitif tutar.
    private mutating func closeOmissions(_ seeds: [Int32]) -> [Int32] {
        var all = seeds
        var work = seeds
        var depth = 0
        while !work.isEmpty && depth < d.trie.maxSurfaceLen {
            var next: [Int32] = []
            for slot in work {
                let e = arena[Int(slot)]
                guard e.cost.isFinite else { continue }
                for arc in d.trie.arcRange(e.key.node) {
                    let sym = d.trie.arcSymbol(arc)
                    let om = d.omissionCost(atWordStart: e.key.atWordStart,
                                            symbol: sym,
                                            lastSurfaceSymbol: e.key.lastSurfaceSymbol)
                    let target = d.trie.arcTarget(arc)
                    let key = DecoderStateKey(
                        automaton: e.key.automaton,
                        language: e.key.language,
                        node: target,
                        surfaceId: target,
                        touchIndex: e.key.touchIndex,
                        lastSurfaceSymbol: sym,
                        atWordStart: false)
                    arena.append(BeamEntry(
                        key: key,
                        cost: e.cost + om + d.weights.wLex * d.trie.arcLexDelta(arc) + d.weights.wLen,
                        parent: slot,
                        emission: .one(sym),
                        emitCount: e.emitCount + 1))
                    next.append(Int32(arena.count - 1))
                }
            }
            if next.isEmpty { break }
            let pruned = dedupAndPrune(next)
            all.append(contentsOf: pruned)
            work = pruned
            depth += 1
        }
        return dedupAndPrune(all)
    }

    // MARK: - Dedup + budama

    private func dedupAndPrune(_ slots: [Int32]) -> [Int32] {
        var kept: [Int32]
        if d.disableDedup {
            kept = slots.filter { arena[Int($0)].cost.isFinite }
        } else {
            var bestBySlot: [DecoderStateKey: Int32] = [:]
            bestBySlot.reserveCapacity(slots.count)
            for s in slots {
                let e = arena[Int(s)]
                guard e.cost.isFinite else { continue }
                if let cur = bestBySlot[e.key], arena[Int(cur)].cost <= e.cost { continue }
                bestBySlot[e.key] = s
            }
            kept = Array(bestBySlot.values)
        }
        if !d.disablePruning && kept.count > d.beamWidth {
            kept.sort { arena[Int($0)].cost < arena[Int($1)].cost }
            kept.removeSubrange(d.beamWidth...)
        }
        return kept
    }

    private func reconstruct(_ slot: Int) -> String {
        var symbols: [UInt16] = []
        var cur = slot
        while cur >= 0 {
            let e = arena[cur]
            switch e.emission {
            case .none: break
            case let .one(s): symbols.append(s)
            case let .two(a, b): symbols.append(b); symbols.append(a)  // ters sırada birikiyor
            }
            cur = Int(e.parent)
        }
        var s = String.UnicodeScalarView()
        for sym in symbols.reversed() { s.append(d.trie.scalar(sym)) }
        return String(s)
    }
}
