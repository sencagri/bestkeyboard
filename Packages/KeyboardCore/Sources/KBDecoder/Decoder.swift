import Foundation
import KBGeometry
import KBLexicon
import KBSpatial

/// Decoder state — skor sözleşmesi §4.
///
/// **Not (belge düzeltmesi):** sözleşme §4'te "52 bit, tek UInt64'e sığar" deniyor;
/// bu yalnız `surfaceId ≡ node` olan **form trie** durumu için doğrudur.
/// `-1A₂` ölçümü tam anahtarı **86 bit** olarak verdi (morfoloji düğümü 35 +
/// surfaceId 32 + …), yani tek `UInt64` yetmez — anahtar struct kalır.
public struct DecoderStateKey: Hashable, Sendable {
    public var automaton: UInt8
    public var language: UInt8
    /// `-1A₂` ölçümü: morfoloji düğümü üretim ölçeğinde 35 bit — `UInt32`
    /// yetmiyor. Sözleşme §4'teki `UInt32` bu ölçümle **UInt64'e yükseltildi**.
    public var node: UInt64
    /// Yüzey öneki kimliği (§4.2).
    ///
    /// Form trie'de düğüm öneki tekil belirler → `surfaceId = node`.
    /// Morfolojide belirlemez (aynı düğüme farklı yüzeylerle ulaşılır) →
    /// emit edilen sembollerin **rolling hash**'i.
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
    /// Çoklu leksikal kaynak — decoder hangisinin konuştuğunu bilmez (§4).
    public let lexicon: LexiconSet
    /// Geriye dönük kolaylık: yalnız form trie ile kurulmuşsa erişim.
    public var trie: FormTrie? { lexicon.formTrie }
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
                lexicon: LexiconSet,
                weights: ScoreWeights = ScoreWeights(),
                beamWidth: Int = 128,
                disableDedup: Bool = false,
                disablePruning: Bool = false) {
        precondition(weights.satisfiesLexPositivity, "w_lex > 0 kısıtı ihlal edildi (§7.1)")
        self.layout = layout
        self.spatial = spatial
        self.lexicon = lexicon
        self.weights = weights
        self.beamWidth = beamWidth
        self.disableDedup = disableDedup
        self.disablePruning = disablePruning
    }

    /// Tek kaynaklı kısayol.
    public init(layout: KeyLayout, spatial: SpatialModel, trie: FormTrie,
                weights: ScoreWeights = ScoreWeights(), beamWidth: Int = 128,
                disableDedup: Bool = false, disablePruning: Bool = false) {
        self.init(layout: layout, spatial: spatial,
                  lexicon: LexiconSet(formTrie: trie, morphology: nil),
                  weights: weights, beamWidth: beamWidth,
                  disableDedup: disableDedup, disablePruning: disablePruning)
    }

    /// Yüzey öneki rolling hash'i (§4.2) — FNV-1a 32-bit.
    @inline(__always)
    static func mixSurface(_ h: UInt32, _ symbol: UInt16) -> UInt32 {
        var v = h ^ UInt32(symbol)
        v = v &* 0x0100_0193
        return v
    }
    static let surfaceSeed: UInt32 = 0x811C_9DC5

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

    /// (I1) yüzey uzunluk sınırı — kaynaklar arası ortak.
    var maxSurfaceLen: Int { lexicon.formTrie?.maxSurfaceLen ?? 40 }

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
        var seeds: [Int32] = []
        for pos in decoder.lexicon.startPositions() {
            let key = DecoderStateKey(
                automaton: pos.automaton,
                language: 0,
                node: pos.node,
                surfaceId: decoder.lexicon.nodeDeterminesSurface(pos.automaton)
                    ? UInt32(truncatingIfNeeded: pos.node) : Decoder.surfaceSeed,
                touchIndex: 0,
                lastSurfaceSymbol: Decoder.noSymbol,
                atWordStart: true)
            arena.append(BeamEntry(key: key, cost: 0, parent: -1, emission: .none, emitCount: 0))
            seeds.append(Int32(arena.count - 1))
        }
        // Kökten `OM` kapanışı: yalnız omission ile erişilen kelimeler de modelde
        // geçerlidir (oracle §5.2'de `D[0][j]` zinciri bunu tanımlar).
        frontier = [closeOmissions(dedupAndPrune(seeds))]
    }

    /// Bir arkı izleyerek hedef anahtarı kurar — kaynak-bağımsız.
    private func advance(_ e: BeamEntry, _ arc: LexiconSet.LexArc, touchIndex: Int?) -> DecoderStateKey {
        DecoderStateKey(
            automaton: arc.target.automaton,
            language: e.key.language,
            node: arc.target.node,
            surfaceId: d.lexicon.nodeDeterminesSurface(arc.target.automaton)
                ? UInt32(truncatingIfNeeded: arc.target.node)
                : Decoder.mixSurface(e.key.surfaceId, arc.symbol),
            touchIndex: UInt16(touchIndex ?? Int(e.key.touchIndex)),
            lastSurfaceSymbol: arc.symbol,
            atWordStart: false)
    }

    private func position(_ k: DecoderStateKey) -> LexiconSet.Position {
        LexiconSet.Position(automaton: k.automaton, node: k.node)
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
            let pos = LexiconSet.Position(automaton: e.key.automaton, node: e.key.node)
            guard e.cost.isFinite, d.lexicon.isAccepting(pos) else { continue }
            let total = e.cost + d.weights.wLex * d.lexicon.acceptExtra(pos)
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
        for arc in d.lexicon.arcs(from: position(e.key)) {
            let ch = Character(d.lexicon.scalar(arc.symbol))
            guard let cost = d.substitutionCost(t, char: ch) else { continue }
            arena.append(BeamEntry(
                key: advance(e, arc, touchIndex: i),
                cost: e.cost + cost + d.weights.wLex * arc.lexDelta + d.weights.wLen,
                parent: slot,
                emission: .one(arc.symbol),
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

        for arc1 in d.lexicon.arcs(from: position(e.key)) {
            guard let k1 = d.layout.keyIndex(for: Character(d.lexicon.scalar(arc1.symbol))) else { continue }
            let mid = advance(e, arc1, touchIndex: nil)
            var midEntry = e
            midEntry.key = mid

            for arc2 in d.lexicon.arcs(from: position(mid)) {
                guard let k2 = d.layout.keyIndex(for: Character(d.lexicon.scalar(arc2.symbol))) else { continue }

                // Çapraz: t_{i−1} → c_j , t_i → c_{j−1}
                let spa = d.spatial.negLogP(tPrev, keyIndex: k2)
                        + d.spatial.negLogP(tCur, keyIndex: k1)
                let lex = d.weights.wLex * (arc1.lexDelta + arc2.lexDelta)

                arena.append(BeamEntry(
                    key: advance(midEntry, arc2, touchIndex: i),
                    cost: e.cost + d.weights.wTr + spa + lex + 2 * d.weights.wLen,
                    parent: slot,
                    emission: .two(arc1.symbol, arc2.symbol),
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
        while !work.isEmpty && depth < d.maxSurfaceLen {
            var next: [Int32] = []
            for slot in work {
                let e = arena[Int(slot)]
                guard e.cost.isFinite else { continue }
                for arc in d.lexicon.arcs(from: position(e.key)) {
                    let om = d.omissionCost(atWordStart: e.key.atWordStart,
                                            symbol: arc.symbol,
                                            lastSurfaceSymbol: e.key.lastSurfaceSymbol)
                    arena.append(BeamEntry(
                        key: advance(e, arc, touchIndex: nil),
                        cost: e.cost + om + d.weights.wLex * arc.lexDelta + d.weights.wLen,
                        parent: slot,
                        emission: .one(arc.symbol),
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
        for sym in symbols.reversed() { s.append(d.lexicon.scalar(sym)) }
        return String(s)
    }
}
