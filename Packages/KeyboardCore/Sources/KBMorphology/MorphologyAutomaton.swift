import Foundation

/// Morfoloji otomatı — yüzey formlarını **harf harf türetir**, önceden üretmez.
/// `kalemlerimizden` sözlükte olmadan çözülür.
///
/// Skor sözleşmesi §4: form trie ile **aynı ABI**.
public struct MorphologyAutomaton {

    // MARK: - State

    /// Otomat düğümü. Alanların gerekçesi `StateLayout.swift`'te.
    public struct State: Hashable, Sendable {
        public enum Phase: UInt8, Sendable { case root, suffix }

        public var phase: Phase
        /// `.root` iken **kök trie düğümü**, `.suffix` iken yoğun ek indeksi.
        /// İki yük birbirini dışlar (etiketli birleşim).
        ///
        /// Kök fazı artık (kök indeksi, karakter offseti) çifti DEĞİL — kökler
        /// ortak önekli bir trie'de paylaşılıyor. Böylece başlangıç frontier'ı
        /// `O(kök)` yerine `O(1)`.
        public var payloadIndex: UInt32
        /// Yalnız `.suffix` fazında anlamlı: ek içinde parça indeksi.
        public var offset: UInt8
        public var continuation: Continuation
        public var alternation: BoundaryAlternation

        // --- Fonolojik bağlam ---
        public var isBack: Bool
        public var isRounded: Bool
        public var lastWasVowel: Bool
        public var lastWasVoiceless: Bool
    }

    // MARK: - Kurulum

    public let roots: [Root]
    /// Kökler üzerinde ortak önekli trie (§RootTrie).
    public let rootTrie: RootTrie
    /// **Yoğun** ek dizisi — state seyrek `Suffix.id` değil, bu dizinin indeksini
    /// taşır. (Seyrek id saklamak bit ölçümünü bozuyordu: id'ler 1…84 aralığında,
    /// 5 bit yetmez, 8 gerekirdi.)
    public let suffixes: [Suffix]
    private let suffixIndicesByContinuation: [Continuation: [UInt32]]

    /// Maliyet itme potansiyeli (§7.1): bir devam sınıfından kabul durumuna
    /// ulaşmak için gereken **en küçük** ek maliyeti.
    private let minCostToAccept: [Continuation: Double]

    public init(roots: [Root], suffixes: [Suffix] = TurkishMorphotactics.suffixes) {
        self.roots = roots
        self.rootTrie = RootTrie(roots: roots)
        self.suffixes = suffixes

        var byCont = [Continuation: [UInt32]]()
        for c in Continuation.allCases {
            byCont[c] = suffixes.enumerated().filter { $0.element.from == c }.map { UInt32($0.offset) }
        }
        self.suffixIndicesByContinuation = byCont

        // Sabit nokta: devam sınıfından kabule en ucuz yol.
        var pot = [Continuation: Double]()
        for c in Continuation.allCases {
            pot[c] = TurkishMorphotactics.isAccepting(c) ? 0 : .infinity
        }
        for _ in 0..<(Continuation.allCases.count + 1) {
            var changed = false
            for s in suffixes {
                let cand = s.cost + (pot[s.to] ?? .infinity)
                if cand < (pot[s.from] ?? .infinity) - 1e-12 { pot[s.from] = cand; changed = true }
            }
            if !changed { break }
        }
        self.minCostToAccept = pot
    }

    public var nodeLayout: MorphologyNodeLayout {
        MorphologyNodeLayout(
            // Kök fazının yükü artık kök indeksi değil, KÖK TRIE DÜĞÜMÜ.
            rootTrieNodeCount: rootTrie.nodeCount,
            suffixCount: suffixes.count,
            continuationCount: Continuation.allCases.count,
            maxSuffixPieces: suffixes.map(\.pieces.count).max() ?? 1)
    }

    /// Kalan en küçük leksikal maliyet — maliyet itmenin potansiyeli (§7.1).
    /// Admissible alt sınırdır.
    public func potential(_ s: State) -> Double {
        // Kök fazında devam sınıfı henüz belirlenmemiştir (hangi kökte
        // bitileceği bilinmiyor); leksikal potansiyel zaten trie bound'una
        // itilmiş durumda.
        guard s.phase == .suffix else { return 0 }
        var p = minCostToAccept[s.continuation] ?? 0
        if !p.isFinite { p = 0 }
        return p
    }

    // MARK: - ABI

    public struct Arc {
        public let symbol: Character
        public let target: State
        /// **İtilmiş** ham `F_lex` deltası (§7.1):
        /// `arcCost + potential(target) − potential(source)`.
        public let lexDelta: Double
        /// Bu ark yeni bir morfem başlatıyor mu (derinlik sayacı için).
        public let startsMorpheme: Bool
    }

    /// **Tek** başlangıç durumu — kök trie'nin kökü.
    ///
    /// Önceden kök başına bir durum üretiliyordu; başlangıç frontier'ı `O(kök)`
    /// oluyordu ve tohumlar doğruluk için budanamadığı için bu maliyetten kaçış
    /// yoktu (bkz. `RootTrie` başlığındaki ölçümler).
    public func startStates() -> [State] {
        [State(phase: .root, payloadIndex: RootTrie.root, offset: 0,
               continuation: .nounRoot,           // kök fazında kullanılmaz
               alternation: .none,
               isBack: true, isRounded: false,
               lastWasVowel: false, lastWasVoiceless: false)]
    }

    public func arcs(from s: State) -> [Arc] {
        var out: [Arc] = []
        arcs(from: s, into: &out)
        return out
    }

    /// Tampona yazan sürüm — **sıcak yol bunu kullanır** (§11.C.2).
    /// Çağrı başına dizi tahsisi, ölçülen darboğazın sabit çarpanıydı:
    /// durum başına ~0.8 µs, ki bu birkaç düzine komutluk iş için çok fazla.
    public func arcs(from s: State, into out: inout [Arc]) {
        let start = out.count
        switch s.phase {
        case .root:   rootTransitions(s, into: &out)
        case .suffix: suffixTransitions(s, into: &out)
        }
        // Potansiyel farkını yerinde uygula (§7.1).
        let pSource = potential(s)
        for i in start..<out.count {
            let a = out[i]
            out[i] = Arc(symbol: a.symbol, target: a.target,
                         lexDelta: a.lexDelta + potential(a.target) - pSource,
                         startsMorpheme: a.startsMorpheme)
        }
    }

    // MARK: - Kök

    private func rootTransitions(_ s: State, into out: inout [Arc]) {
        let node = s.payloadIndex

        // 1. Kökü uzatan arklar — ortak önek burada paylaşılıyor.
        //    Yumuşamış ve ünlü düşmüş varyantlar trie'ye ayrı yol olarak
        //    gömüldüğü için burada ek dallanma YOK.
        for a in rootTrie.arcRange(node) {
            let ch = rootTrie.arcSymbol[a]
            var next = s
            next.payloadIndex = rootTrie.arcTarget[a]
            next.lastWasVowel = Phonology.isVowel(ch)
            next.lastWasVoiceless = Phonology.isVoiceless(ch)
            if Phonology.isVowel(ch) {
                next.isBack = Phonology.isBack(ch)
                next.isRounded = Phonology.isRounded(ch)
            }
            out.append(Arc(symbol: ch, target: next,
                           lexDelta: rootTrie.arcDelta[a], startsMorpheme: false))
        }

        // 2. Bu düğümde biten kökler → ek başlangıçları.
        //    Varyant, sonraki ekin ne olabileceğini belirler.
        for t in rootTrie.terminalRange(node) {
            let term = rootTrie.terminals[t]
            let root = roots[Int(term.rootIndex)]
            var st = s
            st.continuation = root.pos == .verb ? .verbRoot : .nounRoot
            st.alternation = Self.alternation(for: term, root: root)
            suffixStarts(st, extraCost: term.extraCost, into: &out)
        }
    }

    /// Kök varyantının sonraki eke koyduğu kısıt.
    private static func alternation(for term: RootTrie.Terminal, root: Root) -> BoundaryAlternation {
        switch term.variant {
        case .softened, .droppedVowel:
            // Yumuşamış / ünlü düşmüş biçim yalnız ünlüyle başlayan ek alır
            // ve tek başına kelime değildir.
            return .mustTakeVowelSuffix
        case .plain:
            // Sözlük biçimi: kökün alternasyonu varsa ünlüyle başlayan eki
            // ALAMAZ (o ekler yumuşamış/düşmüş yoldan gelir).
            return (root.finalAlternation != nil || root.dropsVowel)
                ? .mustTakeConsonantOrEnd : .none
        }
    }

    // MARK: - Ek

    /// `extraCost`: kök terminalinin itilmiş fazlası (§7.1). Ek başlangıcında
    /// ödenir çünkü kök fazından çıkış tam da burada gerçekleşiyor.
    private func suffixStarts(_ s: State, extraCost: Double = 0, into out: inout [Arc]) {
        for si in suffixIndicesByContinuation[s.continuation] ?? [] {
            let suf = suffixes[Int(si)]
            guard alternationAllows(s.alternation, suffix: suf) else { continue }
            var st = s
            st.phase = .suffix
            st.payloadIndex = si
            st.offset = 0
            st.continuation = suf.to
            st.alternation = .none
            emitPiece(state: st, suffix: suf, pieceIndex: 0,
                      cost: suf.cost + extraCost, startsMorpheme: true, into: &out)
        }
    }

    /// Morfem sınırı kısıtı — tek yerde, tek kural. (Önceden bu karar iki Bool
    /// artı gizli `suffixID == 255` işaretçisine dağılmıştı.)
    private func alternationAllows(_ a: BoundaryAlternation, suffix: Suffix) -> Bool {
        switch a {
        case .none:                   return true
        case .mustTakeConsonantOrEnd: return !suffix.startsWithVowelSound
        case .mustTakeVowelSuffix,
             .droppedVowelMustTakeVowel: return suffix.startsWithVowelSound
        }
    }

    private func suffixTransitions(_ s: State, into out: inout [Arc]) {
        let suf = suffixes[Int(s.payloadIndex)]
        let i = Int(s.offset)
        guard i < suf.pieces.count else { suffixStarts(s, into: &out); return }

        let start = out.count
        emitPiece(state: s, suffix: suf, pieceIndex: i, cost: 0,
                  startsMorpheme: false, into: &out)

        // Ek sonu yumuşaması: `-AcAk + -Im → geleceğim`.
        if i == suf.pieces.count - 1, let alt = suf.finalAlternation,
           out.count > start, out[start].symbol == alt.source {
            let plain = out[start]
            var plainSt = plain.target
            plainSt.alternation = .mustTakeConsonantOrEnd
            out[start] = Arc(symbol: plain.symbol, target: plainSt,
                             lexDelta: plain.lexDelta, startsMorpheme: plain.startsMorpheme)

            var soft = plain.target
            soft.lastWasVoiceless = Phonology.isVoiceless(alt.target)
            soft.alternation = .mustTakeVowelSuffix
            out.append(Arc(symbol: alt.target, target: soft,
                           lexDelta: plain.lexDelta, startsMorpheme: plain.startsMorpheme))
        }
    }

    private func emitPiece(state: State, suffix: Suffix, pieceIndex: Int,
                           cost: Double, startsMorpheme: Bool, into out: inout [Arc]) {
        guard pieceIndex < suffix.pieces.count else { return }
        let ctx = Phonology.VowelContext(isBack: state.isBack, isRounded: state.isRounded)

        var ch: Character?
        switch suffix.pieces[pieceIndex] {
        case let .literal(c):       ch = c
        case .archiA:               ch = Phonology.realizeA(ctx)
        case .archiI:               ch = Phonology.realizeI(ctx)
        case .archiD:               ch = Phonology.realizeD(precedingIsVoiceless: state.lastWasVoiceless)
        case .archiC:               ch = Phonology.realizeC(precedingIsVoiceless: state.lastWasVoiceless)
        case let .bufferIfVowel(c): ch = state.lastWasVowel ? c : nil
        case .optionalIVowel:       ch = state.lastWasVowel ? nil : Phonology.realizeI(ctx)
        }

        guard let emitted = ch else {
            var skipped = state
            skipped.offset = UInt8(pieceIndex + 1)
            emitPiece(state: skipped, suffix: suffix, pieceIndex: pieceIndex + 1,
                      cost: cost, startsMorpheme: startsMorpheme, into: &out)
            return
        }

        var next = state
        next.offset = UInt8(pieceIndex + 1)
        next.lastWasVowel = Phonology.isVowel(emitted)
        next.lastWasVoiceless = Phonology.isVoiceless(emitted)
        if Phonology.isVowel(emitted) {
            next.isBack = Phonology.isBack(emitted)
            next.isRounded = Phonology.isRounded(emitted)
        }
        out.append(Arc(symbol: emitted, target: next, lexDelta: cost,
                       startsMorpheme: startsMorpheme))
    }

    // MARK: - Kabul

    public func isAccepting(_ s: State) -> Bool {
        // Yumuşamış / ünlü düşmüş biçim tek başına kelime değildir.
        switch s.alternation {
        case .mustTakeVowelSuffix, .droppedVowelMustTakeVowel: return false
        case .none, .mustTakeConsonantOrEnd: break
        }
        switch s.phase {
        case .root:
            // Bu trie düğümünde `.plain` varyantla biten ve devam sınıfı kabul
            // eden bir kök var mı?
            for t in rootTrie.terminalRange(s.payloadIndex) {
                let term = rootTrie.terminals[t]
                guard term.variant == .plain else { continue }
                let root = roots[Int(term.rootIndex)]
                let cont: Continuation = root.pos == .verb ? .verbRoot : .nounRoot
                if TurkishMorphotactics.isAccepting(cont) { return true }
            }
            return false
        case .suffix:
            guard Int(s.offset) >= suffixes[Int(s.payloadIndex)].pieces.count else { return false }
            return TurkishMorphotactics.isAccepting(s.continuation)
        }
    }

    // MARK: - Teşhis

    public enum GenerateError: Error, CustomStringConvertible {
        case visitLimitExceeded(visited: Int)
        public var description: String {
            switch self {
            case let .visitLimitExceeded(v):
                return "türetme sınırı aşıldı (\(v) durum) — sonuç EKSİK olurdu"
            }
        }
    }

    /// Bir kökten üretilebilecek yüzey formları.
    ///
    /// Kökler artık ortak önekli trie'de paylaşıldığı için "kökün başlangıç
    /// durumu" diye bir şey yok; bunun yerine kökün her **varyantının** yüzeyi
    /// trie'de yürütülüp oradan devam edilir.
    ///
    /// Sessiz kesme YAPMAZ: sınır aşılırsa hata fırlatır. Bu fonksiyon testlerde
    /// oracle olarak kullanılıyor; eksik sonuç "form yok"u yanlışlıkla başarı
    /// saydırabilirdi.
    public func generate(rootIndex: Int, maxSuffixes: Int = 3,
                         visitLimit: Int = 500_000) throws -> [(surface: String, cost: Double)] {
        precondition(roots.indices.contains(rootIndex), "geçersiz kök indeksi")
        var out: [(String, Double)] = []
        var stack: [(State, [Character], Double, Int)] = []

        // Kökün her varyantının yüzeyini trie'de yürüyerek başlangıç
        // durumlarını kur.
        for seed in seedsForRoot(UInt32(rootIndex)) {
            if isAccepting(seed.state) { out.append((String(seed.surface), seed.cost)) }
            // Kök terminalinden çıkan ek başlangıçları.
            var seedArcs: [Arc] = []
            suffixStarts(seed.completed, extraCost: seed.extraCost, into: &seedArcs)
            for arc in seedArcs {
                var acc = seed.surface; acc.append(arc.symbol)
                stack.append((arc.target, acc, seed.cost + arc.lexDelta,
                              arc.startsMorpheme ? 1 : 0))
            }
        }

        var visited = 0
        while let (st, acc, cost, depth) = stack.popLast() {
            visited += 1
            if visited > visitLimit { throw GenerateError.visitLimitExceeded(visited: visited) }
            if isAccepting(st) { out.append((String(acc), cost)) }
            guard acc.count < TurkishMorphotactics.maxSurfaceLen else { continue }
            for arc in arcs(from: st) {
                let d = arc.startsMorpheme ? depth + 1 : depth
                if d > maxSuffixes { continue }
                var a = acc; a.append(arc.symbol)
                stack.append((arc.target, a, cost + arc.lexDelta, d))
            }
        }
        return out
    }

    private struct RootSeed {
        /// Kökün yüzeyi yürüdükten sonraki trie durumu (kabul kontrolü için).
        let state: State
        /// Ek başlangıcı için hazırlanmış durum (alternasyon kısıtı uygulanmış).
        let completed: State
        let surface: [Character]
        let cost: Double
        let extraCost: Double
    }

    /// Bir kökün tüm varyantlarını (`plain`, `softened`, `droppedVowel`)
    /// trie'de yürüyerek başlangıç tohumlarını üretir.
    private func seedsForRoot(_ rootIndex: UInt32) -> [RootSeed] {
        var out: [RootSeed] = []
        let root = roots[Int(rootIndex)]

        // Trie'de bu köke ait terminalleri bul — hangi düğümde ve hangi yüzeyle.
        var stack: [(UInt32, [Character], Double, State)] = [
            (RootTrie.root, [], 0, startStates()[0])
        ]
        while let (node, surf, cost, st) = stack.popLast() {
            for t in rootTrie.terminalRange(node) {
                let term = rootTrie.terminals[t]
                guard term.rootIndex == rootIndex else { continue }
                var completed = st
                completed.continuation = root.pos == .verb ? .verbRoot : .nounRoot
                completed.alternation = Self.alternation(for: term, root: root)
                out.append(RootSeed(state: st, completed: completed,
                                    surface: surf, cost: cost, extraCost: term.extraCost))
            }
            guard surf.count < TurkishMorphotactics.maxSurfaceLen else { continue }
            for a in rootTrie.arcRange(node) {
                let ch = rootTrie.arcSymbol[a]
                var next = st
                next.payloadIndex = rootTrie.arcTarget[a]
                next.lastWasVowel = Phonology.isVowel(ch)
                next.lastWasVoiceless = Phonology.isVoiceless(ch)
                if Phonology.isVowel(ch) {
                    next.isBack = Phonology.isBack(ch)
                    next.isRounded = Phonology.isRounded(ch)
                }
                var s2 = surf; s2.append(ch)
                stack.append((rootTrie.arcTarget[a], s2, cost + rootTrie.arcDelta[a], next))
            }
        }
        return out
    }
}
