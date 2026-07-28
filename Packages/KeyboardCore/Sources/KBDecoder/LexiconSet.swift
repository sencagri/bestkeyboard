import Foundation
import KBLexicon
import KBMorphology

/// Birden çok leksikal kaynağı **tek ABI** arkasında birleştirir (§4).
///
/// Decoder kaynağın hangisi olduğunu bilmez: `startStates` / `arcs` / `isAccepting`
/// görür. Dağıtım `switch` iledir — existential (`any Protocol`) yoktur, çünkü
/// sözleşme §11.C.2 sıcak döngüde ARC trafiği ve kutulama yasaklıyor.
public struct LexiconSet {

    public let formTrie: FormTrie?
    public let morphology: MorphologyAutomaton?

    /// **Birleşik alfabe.** İki kaynak farklı sembol uzayları kullanır
    /// (trie kendi indeksleri, morfoloji `Character`). Decoder tek uzay görmeli,
    /// yoksa `lastSurfaceSymbol` karşılaştırmaları anlamsızlaşır.
    public let alphabet: [Unicode.Scalar]
    private let symbolOfScalar: [Unicode.Scalar: UInt16]
    /// Trie'nin kendi sembol indeksinden birleşik indekse eşleme.
    private let trieSymbolToMerged: [UInt16]
    private let morphologyLayout: MorphologyNodeLayout?

    public init(formTrie: FormTrie?, morphology: MorphologyAutomaton?) {
        self.formTrie = formTrie
        self.morphology = morphology

        var scalars = Set<Unicode.Scalar>()
        if let t = formTrie { scalars.formUnion(t.alphabet) }
        if let m = morphology {
            for r in m.roots { for c in r.surface { scalars.formUnion(c.unicodeScalars) } }
            // Eklerin üretebileceği tüm yüzey harfleri — arşifonemlerin tüm
            // gerçekleşmeleri dahil.
            for c in "abcçdefgğhıijklmnoöprsştuüvyz" { scalars.formUnion(c.unicodeScalars) }
        }
        let sorted = scalars.sorted()
        self.alphabet = sorted
        var map = [Unicode.Scalar: UInt16]()
        for (i, s) in sorted.enumerated() { map[s] = UInt16(i) }
        self.symbolOfScalar = map

        if let t = formTrie {
            self.trieSymbolToMerged = t.alphabet.map { map[$0] ?? 0 }
        } else {
            self.trieSymbolToMerged = []
        }
        self.morphologyLayout = morphology?.nodeLayout
    }

    public func scalar(_ merged: UInt16) -> Unicode.Scalar { alphabet[Int(merged)] }
    public func symbol(for scalar: Unicode.Scalar) -> UInt16? { symbolOfScalar[scalar] }

    // MARK: - Kaynak-bağımsız düğüm

    /// Bir kaynaktaki konum. `node` genişliği kaynağa göre değişir; `-1A₂`
    /// ölçümü morfoloji için 35 bit (üretim) gösterdiği için **UInt64**.
    public struct Position: Hashable, Sendable {
        public var automaton: UInt8
        public var node: UInt64
        public init(automaton: UInt8, node: UInt64) {
            self.automaton = automaton
            self.node = node
        }
    }

    public struct LexArc {
        public let symbol: UInt16
        public let target: Position
        /// **İtilmiş** ham `F_lex` deltası (§7.1).
        public let lexDelta: Double

        public init(symbol: UInt16, target: Position, lexDelta: Double) {
            self.symbol = symbol
            self.target = target
            self.lexDelta = lexDelta
        }
    }

    /// Bir başlangıç konumunun **tohum maliyeti** — maliyet itmenin telescoping'i
    /// için zorunlu.
    ///
    /// İtilmiş arkların toplamı `rawCost + potential(final) − potential(start)`
    /// olur. Kabulde `potential = 0` olduğu için, tohum `potential(start)`
    /// eklemezse sonuç gerçek maliyetten **`potential(start)` kadar düşük** çıkar.
    /// Trie bunu kökün bound'unu 0 alarak çözüyor; morfolojide potansiyel
    /// sıfırdan farklı olduğu için açıkça eklenmeli — aksi halde morfoloji
    /// sistematik olarak ucuz görünür ve kaynaklar arası skorlar
    /// **karşılaştırılamaz** hale gelir.
    public func startCost(_ p: Position) -> Double {
        switch AutomatonKind(rawValue: p.automaton) {
        case .morphology:
            guard let m = morphology, let layout = morphologyLayout,
                  let st = MorphologyAutomaton.State.unpacked(p.node, layout) else { return 0 }
            return m.potential(st)
        default:
            return 0   // trie: kök bound'u zaten 0
        }
    }

    /// (I1) yüzey uzunluk sınırı — **kaynağa özgü**.
    /// Ortak tek sınır kullanmak kaynak-bağımsız değildi: küçük sınırla
    /// derlenmiş bir trie, yanındaki morfolojinin türetimini de erken keserdi.
    public func maxSurfaceLen(_ automaton: UInt8) -> Int {
        switch AutomatonKind(rawValue: automaton) {
        case .formTrie:   return formTrie?.maxSurfaceLen ?? 40
        case .morphology: return TurkishMorphotactics.maxSurfaceLen
        default:          return 40
        }
    }

    /// Yüzey kimliğini bir ark boyunca ilerletir.
    ///
    /// Politika **burada** yaşar, decoder'da değil: decoder yeni bir kaynak
    /// türü eklendiğinde doğru `surfaceId` kuralını bilmek zorunda kalmamalı.
    public func advanceSurfaceId(from current: UInt64, arc: LexArc) -> UInt64 {
        switch AutomatonKind(rawValue: arc.target.automaton) {
        case .formTrie:
            // Trie'de düğüm öneki tekil belirler — hash gereksiz, çakışma yok.
            return arc.target.node
        default:
            // 64-bit FNV-1a. 32-bit'te aynı düğümde `b` rakip yüzey için
            // çakışma olasılığı ≈ b(b−1)/2³³ (b=128 → ~2·10⁻⁶); 64-bit bunu
            // pratikte sıfırlıyor ve maliyeti aynı.
            var v = current ^ UInt64(arc.symbol)
            v = v &* 0x0000_0100_0000_01B3
            return v
        }
    }

    public func initialSurfaceId(_ p: Position) -> UInt64 {
        AutomatonKind(rawValue: p.automaton) == .formTrie ? p.node : 0xcbf2_9ce4_8422_2325
    }

    /// Başlangıç konumları.
    ///
    /// **Ölçülen sınırlama:** morfoloji kök başına bir başlangıç durumu üretir,
    /// yani ilk frontier `O(kök sayısı)`. Spike'ta (20 kök) sorun değil ama
    /// üretimde (~90k kök) kabul edilemez — Faz 4'te kökler ortak önekli bir
    /// trie'de paylaşılmalı. Bu, entegrasyonun ortaya çıkardığı somut bir bulgu.
    public func startPositions() -> [Position] {
        var out: [Position] = []
        if formTrie != nil {
            out.append(Position(automaton: AutomatonKind.formTrie.rawValue,
                                node: UInt64(FormTrie.rootNode)))
        }
        if let m = morphology, let layout = morphologyLayout {
            for s in m.startStates() {
                guard let p = s.packed(layout) else { continue }
                out.append(Position(automaton: AutomatonKind.morphology.rawValue, node: p))
            }
        }
        return out
    }

    public func arcs(from p: Position) -> [LexArc] {
        switch AutomatonKind(rawValue: p.automaton) {
        case .formTrie:
            guard let t = formTrie else { return [] }
            let node = UInt32(truncatingIfNeeded: p.node)
            return t.arcRange(node).map { i in
                LexArc(symbol: trieSymbolToMerged[Int(t.arcSymbol(i))],
                       target: Position(automaton: p.automaton, node: UInt64(t.arcTarget(i))),
                       lexDelta: t.arcLexDelta(i))
            }
        case .morphology:
            guard let m = morphology, let layout = morphologyLayout,
                  let st = MorphologyAutomaton.State.unpacked(p.node, layout) else { return [] }
            var out: [LexArc] = []
            for a in m.arcs(from: st) {
                guard let sc = a.symbol.unicodeScalars.first,
                      let sym = symbolOfScalar[sc],
                      let packed = a.target.packed(layout) else { continue }
                out.append(LexArc(symbol: sym,
                                  target: Position(automaton: p.automaton, node: packed),
                                  lexDelta: a.lexDelta))
            }
            return out
        default:
            return []
        }
    }

    public func isAccepting(_ p: Position) -> Bool {
        switch AutomatonKind(rawValue: p.automaton) {
        case .formTrie:
            guard let t = formTrie else { return false }
            return t.isTerminal(UInt32(truncatingIfNeeded: p.node))
        case .morphology:
            guard let m = morphology, let layout = morphologyLayout,
                  let st = MorphologyAutomaton.State.unpacked(p.node, layout) else { return false }
            return m.isAccepting(st)
        default:
            return false
        }
    }

    /// Kabul anındaki kalan ham `F_lex`.
    /// Trie'de terminal fazlası; morfolojide potansiyel zaten 0'a indiği için 0.
    public func acceptExtra(_ p: Position) -> Double {
        switch AutomatonKind(rawValue: p.automaton) {
        case .formTrie:
            guard let t = formTrie else { return 0 }
            return t.nodeTermExtra(UInt32(truncatingIfNeeded: p.node))
        default:
            return 0
        }
    }

    /// Bu yüzey form listesinde var mı? §7 tek sahiplik kuralı için:
    /// *"form listesinde varsa değer oradan gelir; morfoloji aynı yüzeye
    /// ulaşsa bile kendi maliyetini eklemez."*
    public func formTrieHas(_ word: String) -> Bool {
        formTrie?.lookup(word) != nil
    }
}
