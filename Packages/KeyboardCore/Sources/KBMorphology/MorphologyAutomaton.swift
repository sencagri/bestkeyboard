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
        /// `.root` iken kök indeksi, `.suffix` iken **yoğun** ek indeksi.
        /// İki yük birbirini dışlar (etiketli birleşim).
        public var payloadIndex: UInt32
        /// `.root` iken kök içinde karakter indeksi, `.suffix` iken parça indeksi.
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
            rootCount: roots.count,
            suffixCount: suffixes.count,
            continuationCount: Continuation.allCases.count,
            maxRootLen: roots.map(\.surface.count).max() ?? 1,
            maxSuffixPieces: suffixes.map(\.pieces.count).max() ?? 1)
    }

    /// Kalan en küçük leksikal maliyet — maliyet itmenin potansiyeli (§7.1).
    /// Admissible alt sınırdır.
    public func potential(_ s: State) -> Double {
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

    public func startStates() -> [State] {
        (0..<roots.count).map { i in
            State(phase: .root, payloadIndex: UInt32(i), offset: 0,
                  continuation: roots[i].pos == .verb ? .verbRoot : .nounRoot,
                  alternation: .none,
                  isBack: true, isRounded: false,
                  lastWasVowel: false, lastWasVoiceless: false)
        }
    }

    public func arcs(from s: State) -> [Arc] {
        let raw: [(Character, State, Double, Bool)]
        switch s.phase {
        case .root:   raw = rootTransitions(s)
        case .suffix: raw = suffixTransitions(s)
        }
        let pSource = potential(s)
        return raw.map { sym, target, cost, starts in
            Arc(symbol: sym, target: target,
                lexDelta: cost + potential(target) - pSource,
                startsMorpheme: starts)
        }
    }

    // MARK: - Kök

    private func rootTransitions(_ s: State) -> [(Character, State, Double, Bool)] {
        let root = roots[Int(s.payloadIndex)]
        let i = Int(s.offset)
        guard i < root.surface.count else { return suffixStarts(s) }

        let ch = root.surface[i]
        let isLast = (i == root.surface.count - 1)
        // Kök maliyeti **ilk harfte** ödenir — nadir kök prefix'te de pahalı olsun
        // diye (maliyet itme, §7.1). Son harfte ödemek beam'i yanıltıyordu.
        let cost = (i == 0) ? root.lexCost : 0
        var out: [(Character, State, Double, Bool)] = []

        // --- Ünlü düşmesi: son ünlü emit EDİLMEDEN atlanır (`burun → burn-`) ---
        // Uyum bağlamı **düşen ünlüden** alınır: `burun + I → burnu`.
        if root.dropsVowel, !isLast, Phonology.isVowel(ch), isLastVowel(of: root.surface, at: i) {
            var skipped = s
            skipped.offset = UInt8(i + 1)
            skipped.isBack = Phonology.isBack(ch)
            skipped.isRounded = Phonology.isRounded(ch)
            // Ünlü atlandı → kalan harfleri normal yolla üret, ama bu daldaki
            // her hedef "ünlüyle başlayan ek almak zorunda" işaretini taşır.
            for (sym, st, c, starts) in rootTransitions(skipped) {
                var marked = st
                marked.alternation = .droppedVowelMustTakeVowel
                out.append((sym, marked, c + cost, starts))
            }
        }

        var next = s
        next.offset = UInt8(i + 1)
        next.lastWasVowel = Phonology.isVowel(ch)
        next.lastWasVoiceless = Phonology.isVoiceless(ch)
        if Phonology.isVowel(ch) {
            next.isBack = Phonology.isBack(ch)
            next.isRounded = Phonology.isRounded(ch)
        }

        if isLast, let alt = root.finalAlternation, alt.source == ch {
            var plain = next
            plain.alternation = .mustTakeConsonantOrEnd
            out.append((ch, plain, cost, false))

            var soft = next
            soft.lastWasVoiceless = Phonology.isVoiceless(alt.target)
            soft.alternation = .mustTakeVowelSuffix
            out.append((alt.target, soft, cost, false))
        } else {
            if isLast, root.dropsVowel {
                // Ünlü düşüren kökün **tam** hâli ünlüyle başlayan ek ALAMAZ;
                // o ekler yalnız düşmüş dal üzerinden gelir.
                // (`burunda` ✓, `burunu` ✗ — doğrusu `burnu`.)
                next.alternation = .mustTakeConsonantOrEnd
            }
            out.append((ch, next, cost, false))
        }
        return out
    }

    private func isLastVowel(of s: [Character], at i: Int) -> Bool {
        for j in (i + 1)..<s.count where Phonology.isVowel(s[j]) { return false }
        return true
    }

    // MARK: - Ek

    private func suffixStarts(_ s: State) -> [(Character, State, Double, Bool)] {
        var out: [(Character, State, Double, Bool)] = []
        for si in suffixIndicesByContinuation[s.continuation] ?? [] {
            let suf = suffixes[Int(si)]
            guard alternationAllows(s.alternation, suffix: suf) else { continue }
            var st = s
            st.phase = .suffix
            st.payloadIndex = si
            st.offset = 0
            st.continuation = suf.to
            st.alternation = .none
            if let arcs = emitPiece(state: st, suffix: suf, pieceIndex: 0,
                                    cost: suf.cost, startsMorpheme: true) {
                out.append(contentsOf: arcs)
            }
        }
        return out
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

    private func suffixTransitions(_ s: State) -> [(Character, State, Double, Bool)] {
        let suf = suffixes[Int(s.payloadIndex)]
        let i = Int(s.offset)
        guard i < suf.pieces.count else { return suffixStarts(s) }

        var out = emitPiece(state: s, suffix: suf, pieceIndex: i,
                            cost: 0, startsMorpheme: false) ?? []

        // Ek sonu yumuşaması: `-AcAk + -Im → geleceğim`.
        if i == suf.pieces.count - 1, let alt = suf.finalAlternation,
           let plain = out.first, plain.0 == alt.source {
            var plainSt = plain.1
            plainSt.alternation = .mustTakeConsonantOrEnd
            out[0] = (plain.0, plainSt, plain.2, plain.3)

            var soft = plain.1
            soft.lastWasVoiceless = Phonology.isVoiceless(alt.target)
            soft.alternation = .mustTakeVowelSuffix
            out.append((alt.target, soft, plain.2, plain.3))
        }
        return out
    }

    private func emitPiece(state: State, suffix: Suffix, pieceIndex: Int,
                           cost: Double, startsMorpheme: Bool)
        -> [(Character, State, Double, Bool)]? {
        guard pieceIndex < suffix.pieces.count else { return nil }
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
            return emitPiece(state: skipped, suffix: suffix, pieceIndex: pieceIndex + 1,
                             cost: cost, startsMorpheme: startsMorpheme)
        }

        var next = state
        next.offset = UInt8(pieceIndex + 1)
        next.lastWasVowel = Phonology.isVowel(emitted)
        next.lastWasVoiceless = Phonology.isVoiceless(emitted)
        if Phonology.isVowel(emitted) {
            next.isBack = Phonology.isBack(emitted)
            next.isRounded = Phonology.isRounded(emitted)
        }
        return [(emitted, next, cost, startsMorpheme)]
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
            guard Int(s.offset) >= roots[Int(s.payloadIndex)].surface.count else { return false }
            return TurkishMorphotactics.isAccepting(s.continuation)
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
    /// Sessiz kesme YAPMAZ: sınır aşılırsa hata fırlatır. Bu fonksiyon testlerde
    /// oracle olarak kullanılıyor; eksik sonuç "form yok"u yanlışlıkla başarı
    /// saydırabilirdi.
    public func generate(rootIndex: Int, maxSuffixes: Int = 3,
                         visitLimit: Int = 500_000) throws -> [(surface: String, cost: Double)] {
        var out: [(String, Double)] = []
        var stack: [(State, [Character], Double, Int)] = [(startStates()[rootIndex], [], 0, 0)]
        var visited = 0

        while let (st, acc, cost, depth) = stack.popLast() {
            visited += 1
            if visited > visitLimit { throw GenerateError.visitLimitExceeded(visited: visited) }
            if isAccepting(st) { out.append((String(acc), cost)) }
            guard acc.count < TurkishMorphotactics.maxSurfaceLen else { continue }
            for arc in arcs(from: st) {
                // Derinlik **arkın kendi işaretinden** okunur; phase'den çıkarım
                // yapmak derinliği hiç artırmıyordu.
                let d = arc.startsMorpheme ? depth + 1 : depth
                if d > maxSuffixes { continue }
                var a = acc; a.append(arc.symbol)
                stack.append((arc.target, a, cost + arc.lexDelta, d))
            }
        }
        return out
    }
}
