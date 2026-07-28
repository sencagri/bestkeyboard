import Foundation
import KBGeometry
import KBLexicon
import KBSpatial

/// Decoder state — skor sözleşmesi §4.
///
/// Trivial struct: ARC trafiği yok, düz dizide saklanabilir.
///
/// **Not (belge düzeltmesi):** sözleşme §4'te "52 bit, tek UInt64'e sığar" deniyor;
/// bu yalnız `surfaceId ≡ node` olan **form trie** durumu için doğrudur. Morfoloji
/// kaynağında `surfaceId` ayrı 32 bit gerektirir ve toplam 84 bite çıkar. Bu yüzden
/// anahtar burada struct olarak tutulur; paketleme optimizasyonu kaynak-bağımlıdır.
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

/// Beam girdisi. `parent` ve `emitted` kelime yeniden kurulumu için.
struct BeamEntry {
    var key: DecoderStateKey
    var cost: Double
    var parent: Int32          // arena indeksi, -1 = kök
    var emitted: UInt16        // emitilen sembol, 0xFFFF = emisyon yok
    var emitCount: UInt16      // F_len — teşhis ve doğrulama için
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
/// Bu yüzden ping-pong tampon yetmez.
public struct Decoder {
    public let layout: KeyLayout
    public let spatial: SpatialModel
    public let trie: FormTrie
    public var weights: ScoreWeights
    public var beamWidth: Int

    /// Dokunma başına değerlendirilen en fazla aday tuş (§3'teki budama).
    public var maxKeyCandidates: Int

    public init(layout: KeyLayout,
                spatial: SpatialModel,
                trie: FormTrie,
                weights: ScoreWeights = ScoreWeights(),
                beamWidth: Int = 128,
                maxKeyCandidates: Int = 8) {
        precondition(weights.satisfiesLexPositivity, "w_lex > 0 kısıtı ihlal edildi (§7.1)")
        self.layout = layout
        self.spatial = spatial
        self.trie = trie
        self.weights = weights
        self.beamWidth = beamWidth
        self.maxKeyCandidates = maxKeyCandidates
    }

    private static let noSymbol: UInt16 = 0xFFFF

    public func decode(touches: [TouchSample], topK: Int = 3) -> [DecodeResult] {
        let n = touches.count
        guard n > 0 else { return [] }

        // Arena: tüm frontier'ların girdileri; parent indeksleri buraya işaret eder.
        var arena: [BeamEntry] = []
        arena.reserveCapacity(beamWidth * (n + 2))

        // frontier[i] = i dokunma tüketmiş girdilerin arena indeksleri.
        var frontier: [[Int32]] = Array(repeating: [], count: n + 1)

        // Kök.
        let rootKey = DecoderStateKey(
            automaton: AutomatonKind.formTrie.rawValue,
            language: 0,
            node: FormTrie.rootNode,
            surfaceId: FormTrie.rootNode,
            touchIndex: 0,
            lastSurfaceSymbol: Self.noSymbol,
            atWordStart: true)
        arena.append(BeamEntry(key: rootKey, cost: 0, parent: -1, emitted: Self.noSymbol, emitCount: 0))
        frontier[0] = [0]
        frontier[0] = closeOmissions(&arena, frontier[0])

        for i in 1...n {
            var produced: [Int32] = []

            // SUB / SUB_eq / INS: frontier[i-1]'den.
            for slot in frontier[i - 1] {
                expandConsuming(&arena, from: slot, touches: touches, touchIndex: i, into: &produced)
            }
            // TR: frontier[i-2]'den (§3.1).
            if i >= 2 {
                for slot in frontier[i - 2] {
                    expandTransposition(&arena, from: slot, touches: touches, touchIndex: i, into: &produced)
                }
            }

            produced = dedupAndPrune(&arena, produced)
            produced = closeOmissions(&arena, produced)
            frontier[i] = dedupAndPrune(&arena, produced)
        }

        // Terminaller — `END` yalnız otomat kabul durumundayken yasal (§2.2).
        var results: [DecodeResult] = []
        for slot in frontier[n] {
            let e = arena[Int(slot)]
            guard trie.isTerminal(e.key.node) else { continue }
            let total = e.cost + weights.wLex * trie.nodeTermExtra(e.key.node)
            results.append(DecodeResult(word: reconstruct(arena, Int(slot)),
                                        cost: total,
                                        emitCount: Int(e.emitCount)))
        }
        // Aynı yüzeye farklı yollardan ulaşılmışsa en ucuzu kalır.
        var bestByWord: [String: DecodeResult] = [:]
        for r in results {
            if let cur = bestByWord[r.word], cur.cost <= r.cost { continue }
            bestByWord[r.word] = r
        }
        return bestByWord.values.sorted { $0.cost < $1.cost }.prefix(topK).map { $0 }
    }

    // MARK: - Geçişler

    /// `SUB`, `SUB_eq` (dokunma tüketir, emisyon yapar) ve `INS` (tüketir, emisyon yapmaz).
    private func expandConsuming(_ arena: inout [BeamEntry],
                                 from slot: Int32,
                                 touches: [TouchSample],
                                 touchIndex i: Int,
                                 into out: inout [Int32]) {
        let e = arena[Int(slot)]
        let t = touches[i - 1]

        // --- SUB / SUB_eq ---
        for arc in trie.arcRange(e.key.node) {
            let sym = trie.arcSymbol(arc)
            let ch = trie.character(sym)

            guard let directKey = layout.keyIndex(for: ch) else { continue }
            let direct = spatial.negLogP(t, keyIndex: directKey)   // w_spa ≡ 1

            // §2.3: her ikisi de yasalsa ucuz olan kazanır.
            var best = direct
            if let baseKey = layout.asciiBaseKeyIndex(for: ch) {
                let eq = weights.wSpaEq * spatial.negLogP(t, keyIndex: baseKey) + weights.wEq
                if eq < best { best = eq }
            }

            let lexDelta = weights.wLex * trie.arcLexDelta(arc)
            let target = trie.arcTarget(arc)
            let key = DecoderStateKey(
                automaton: e.key.automaton,
                language: e.key.language,
                node: target,
                surfaceId: target,                 // form trie: surfaceId ≡ node (§4.2)
                touchIndex: UInt16(i),
                lastSurfaceSymbol: sym,            // §4.1
                atWordStart: false)
            arena.append(BeamEntry(key: key,
                                   cost: e.cost + best + lexDelta + weights.wLen,
                                   parent: slot,
                                   emitted: sym,
                                   emitCount: e.emitCount + 1))
            out.append(Int32(arena.count - 1))
        }

        // --- INS: dokunma tüketir, otomat ilerlemez ---
        let insClass: Double
        if i == 1 {
            insClass = weights.wIns                       // t_0 yok → daima normal sınıf (§5.1)
        } else {
            let prev = touches[i - 2]
            let dt = t.timestamp - prev.timestamp
            let dx = t.down.x - prev.down.x, dy = t.down.y - prev.down.y
            let dist = (dx * dx + dy * dy).squareRoot()
            insClass = (dt < weights.tauFast && dist < weights.dNear) ? weights.wInsNear : weights.wIns
        }
        let insCost = insClass + weights.wInsBg * spatial.negLogPBackground(t)
        var insKey = e.key
        insKey.touchIndex = UInt16(i)
        arena.append(BeamEntry(key: insKey,
                               cost: e.cost + insCost,
                               parent: slot,
                               emitted: Self.noSymbol,
                               emitCount: e.emitCount))
        out.append(Int32(arena.count - 1))
    }

    /// `TR`: `t_{i−1}, t_i` tüketir, `c_{j−1}, c_j` emisyonu yapar ama dokunmalar
    /// çapraz eşleşir (§2.2). Kaynak frontier `i−2`.
    private func expandTransposition(_ arena: inout [BeamEntry],
                                     from slot: Int32,
                                     touches: [TouchSample],
                                     touchIndex i: Int,
                                     into out: inout [Int32]) {
        let e = arena[Int(slot)]
        let tPrev = touches[i - 2]   // t_{i−1}
        let tCur = touches[i - 1]    // t_i

        for arc1 in trie.arcRange(e.key.node) {
            let sym1 = trie.arcSymbol(arc1)          // c_{j−1}
            let node1 = trie.arcTarget(arc1)
            guard let key1 = layout.keyIndex(for: trie.character(sym1)) else { continue }

            for arc2 in trie.arcRange(node1) {
                let sym2 = trie.arcSymbol(arc2)      // c_j
                let node2 = trie.arcTarget(arc2)
                guard let key2 = layout.keyIndex(for: trie.character(sym2)) else { continue }

                // Çapraz: t_{i−1} → c_j , t_i → c_{j−1}
                let spa = spatial.negLogP(tPrev, keyIndex: key2)
                        + spatial.negLogP(tCur, keyIndex: key1)
                let lexDelta = weights.wLex * (trie.arcLexDelta(arc1) + trie.arcLexDelta(arc2))

                let key = DecoderStateKey(
                    automaton: e.key.automaton,
                    language: e.key.language,
                    node: node2,
                    surfaceId: node2,
                    touchIndex: UInt16(i),
                    lastSurfaceSymbol: sym2,          // yüzey pozisyonu olarak son olan (§4.1)
                    atWordStart: false)

                // Ara emisyonu arena'da temsil etmek için iki adımlı zincir kurulur;
                // maliyetin tamamı ikinci adıma yazılır.
                arena.append(BeamEntry(key: key,   // ara düğüm yalnız kelime kurulumu için
                                       cost: .infinity,
                                       parent: slot,
                                       emitted: sym1,
                                       emitCount: e.emitCount + 1))
                let midSlot = Int32(arena.count - 1)
                arena.append(BeamEntry(key: key,
                                       cost: e.cost + weights.wTr + spa + lexDelta + 2 * weights.wLen,
                                       parent: midSlot,
                                       emitted: sym2,
                                       emitCount: e.emitCount + 2))
                out.append(Int32(arena.count - 1))
            }
        }
    }

    /// `OM` kapanışı: dokunma tüketmeyen emisyonlar. Aynı `touchIndex` içinde zincirlenir.
    ///
    /// Sonluluk **yapısaldır** (§2.5-I1): trie `maxSurfaceLen`'e kadar açılmıştır ve
    /// çevrimsizdir. (I2) ayrıca her emisyonun net maliyetini pozitif tutar.
    private func closeOmissions(_ arena: inout [BeamEntry], _ seeds: [Int32]) -> [Int32] {
        var all = seeds
        var work = seeds
        var depth = 0
        while !work.isEmpty && depth < trie.maxSurfaceLen {
            var next: [Int32] = []
            for slot in work {
                let e = arena[Int(slot)]
                guard e.cost.isFinite else { continue }
                for arc in trie.arcRange(e.key.node) {
                    let sym = trie.arcSymbol(arc)
                    // Sınıflandırma §5.1 sırasıyla: önce kelime başı, sonra ikiz harf.
                    let omCost: Double
                    if e.key.atWordStart {
                        omCost = weights.wOmInit
                    } else if sym == e.key.lastSurfaceSymbol {
                        omCost = weights.wOmGem
                    } else {
                        omCost = weights.wOm
                    }
                    let target = trie.arcTarget(arc)
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
                        cost: e.cost + omCost + weights.wLex * trie.arcLexDelta(arc) + weights.wLen,
                        parent: slot,
                        emitted: sym,
                        emitCount: e.emitCount + 1))
                    next.append(Int32(arena.count - 1))
                }
            }
            if next.isEmpty { break }
            let pruned = dedupAndPrune(&arena, next)
            all.append(contentsOf: pruned)
            work = pruned
            depth += 1
        }
        return all
    }

    // MARK: - Dedup + budama

    private func dedupAndPrune(_ arena: inout [BeamEntry], _ slots: [Int32]) -> [Int32] {
        var bestBySlot: [DecoderStateKey: Int32] = [:]
        bestBySlot.reserveCapacity(slots.count)
        for s in slots {
            let e = arena[Int(s)]
            guard e.cost.isFinite else { continue }
            if let cur = bestBySlot[e.key], arena[Int(cur)].cost <= e.cost { continue }
            bestBySlot[e.key] = s
        }
        var kept = Array(bestBySlot.values)
        if kept.count > beamWidth {
            kept.sort { arena[Int($0)].cost < arena[Int($1)].cost }
            kept.removeSubrange(beamWidth...)
        }
        return kept
    }

    private func reconstruct(_ arena: [BeamEntry], _ slot: Int) -> String {
        var symbols: [UInt16] = []
        var cur = slot
        while cur >= 0 {
            let e = arena[cur]
            if e.emitted != Self.noSymbol { symbols.append(e.emitted) }
            cur = Int(e.parent)
        }
        return String(symbols.reversed().map { trie.character($0) })
    }
}
