import Foundation

/// Morfoloji otomatı — yüzey formlarını **harf harf türetir**, önceden üretmez.
/// `kalemlerimizden` sözlükte olmadan çözülür.
///
/// Skor sözleşmesi §4: form trie ile **aynı ABI**. Decoder kaynağın hangisi
/// olduğunu bilmez; `arcs(from:)` / `isAccepting` / `acceptExtra` görür.
public struct MorphologyAutomaton {

    // MARK: - State

    /// Otomat durumu.
    ///
    /// **Bu şema `-1A₂`'nin asıl çıktısıdır.** Sözleşme §4.2 bit genişliklerini
    /// bilerek sabitlemedi; aşağıdaki alanlar ve `Bits` ölçümü o boşluğu dolduruyor.
    ///
    /// Neden bu alanlar: yüzey kuralları yalnız o anki karaktere değil, kök
    /// kimliğine, son ünlünün kalınlık/yuvarlaklığına, son sesin sertliğine,
    /// morfem sınırındaki konuma ve sözlüksel istisna bayraklarına bağlıdır.
    public struct State: Hashable, Sendable {
        public enum Phase: UInt8, Sendable { case root, suffix }

        public var phase: Phase
        /// `phase == .root` iken kök indeksi; `.suffix` iken anlamsız.
        public var rootIndex: UInt32
        /// Emisyon konumu: kök içinde karakter indeksi ya da ek içinde parça indeksi.
        public var offset: UInt8
        /// `.suffix` iken hangi ek işleniyor (ekin `id`'si).
        public var suffixID: UInt8
        public var continuation: Continuation

        // --- Fonolojik bağlam (yüzey kuralları için) ---
        public var isBack: Bool
        public var isRounded: Bool
        /// Son emisyon ünlü müydü — kaynaştırma ünsüzleri buna bakar.
        public var lastWasVowel: Bool
        /// Son emisyon sert ünsüz müydü — `D`/`C` benzeşmesi buna bakar.
        public var lastWasVoiceless: Bool
        /// Kökün yumuşama bayrağı hâlâ geçerli mi (kök bitince taşınır).
        public var pendingSoften: Bool
        public var pendingVowelDrop: Bool
        /// Önceki morfem yumuşamış olarak bitti — sonraki ek ünlüyle başlamalı.
        public var softenedMorphemeEnd: Bool
    }

    /// Ölçülen bit genişlikleri — spike ve **gerçek ölçek** için.
    ///
    /// Bu tablo `-1A₂`'nin somut bulgusudur: `UInt32 node` gerçek Türkçe
    /// morfoloji için **yetmez**.
    public enum Bits {
        public static func width(forCount n: Int) -> Int {
            n <= 1 ? 1 : Int(ceil(log2(Double(n))))
        }

        public struct Layout: Sendable {
            public let rootCount: Int
            public let suffixCount: Int
            public let continuationCount: Int
            public let maxRootLen: Int
            public let maxSuffixPieces: Int

            public var phaseBits: Int { 1 }
            public var rootBits: Int { Bits.width(forCount: rootCount) }
            public var offsetBits: Int { Bits.width(forCount: max(maxRootLen, maxSuffixPieces) + 1) }
            public var suffixBits: Int { Bits.width(forCount: suffixCount + 1) }
            public var continuationBits: Int { Bits.width(forCount: continuationCount) }
            /// isBack, isRounded, lastWasVowel, lastWasVoiceless,
            /// pendingSoften, pendingVowelDrop, softenedMorphemeEnd
            public var phonologyBits: Int { 7 }

            public var total: Int {
                phaseBits + rootBits + offsetBits + suffixBits + continuationBits + phonologyBits
            }
            public var fitsInUInt32: Bool { total <= 32 }
        }

        /// Bu spike'ın gerçek ölçüsü.
        public static func spike(rootCount: Int, maxRootLen: Int) -> Layout {
            Layout(rootCount: rootCount,
                   suffixCount: TurkishMorphotactics.suffixes.count,
                   continuationCount: Continuation.allCases.count,
                   maxRootLen: maxRootLen,
                   maxSuffixPieces: TurkishMorphotactics.suffixes.map(\.pieces.count).max() ?? 1)
        }

        /// Faz 4 hedef ölçeği — plandaki ~90k kök, ~200 morfem, ~64 devam sınıfı.
        public static let production = Layout(
            rootCount: 90_000,
            suffixCount: 200,
            continuationCount: 64,
            maxRootLen: 24,
            maxSuffixPieces: 8)
    }

    // MARK: - Kurulum

    public let roots: [Root]
    /// Devam sınıfı → ek listesi (açılışta bir kez).
    private let suffixesByContinuation: [Continuation: [Suffix]]
    private let suffixByID: [UInt8: Suffix]
    /// Kök öneki araması için: ilk karakter → kök indeksleri.
    private let rootsByFirstChar: [Character: [UInt32]]

    public init(roots: [Root]) {
        self.roots = roots
        var byCont = [Continuation: [Suffix]]()
        for c in Continuation.allCases { byCont[c] = TurkishMorphotactics.suffixes(from: c) }
        self.suffixesByContinuation = byCont
        var byID = [UInt8: Suffix]()
        for s in TurkishMorphotactics.suffixes { byID[s.id] = s }
        self.suffixByID = byID
        var byFirst = [Character: [UInt32]]()
        for (i, r) in roots.enumerated() {
            guard let f = r.surface.first else { continue }
            byFirst[f, default: []].append(UInt32(i))
        }
        self.rootsByFirstChar = byFirst
    }

    public var measuredLayout: Bits.Layout {
        Bits.spike(rootCount: roots.count, maxRootLen: roots.map(\.surface.count).max() ?? 1)
    }

    // MARK: - ABI: ark üretimi

    /// Bir arkın ürettiği: emisyon karakteri, hedef durum, ham `F_lex` deltası.
    public struct Arc {
        public let symbol: Character
        public let target: State
        public let lexDelta: Double
    }

    /// Başlangıç durumları — her kök için bir tane (kökün ilk harfini bekler).
    public func startStates() -> [State] {
        (0..<roots.count).map { i in
            State(phase: .root, rootIndex: UInt32(i), offset: 0, suffixID: 0,
                  continuation: roots[i].pos == .verb ? .verbRoot : .nounRoot,
                  isBack: true, isRounded: false, lastWasVowel: false,
                  lastWasVoiceless: false, pendingSoften: false, pendingVowelDrop: false,
                  softenedMorphemeEnd: false)
        }
    }

    /// Durumdan çıkan arklar.
    public func arcs(from s: State) -> [Arc] {
        switch s.phase {
        case .root:  return rootArcs(s)
        case .suffix: return suffixArcs(s)
        }
    }

    private func rootArcs(_ s: State) -> [Arc] {
        let root = roots[Int(s.rootIndex)]
        let i = Int(s.offset)

        // Kök tükenmediyse: sıradaki harfi emit et.
        if i < root.surface.count {
            var ch = root.surface[i]
            let isLast = (i == root.surface.count - 1)

            // Son ünsüz yumuşaması, ancak ünlüyle başlayan ek gelecekse uygulanır.
            // Bu bir **ileriye bağımlılık** olurdu; bunun yerine yumuşamamış hâli
            // emit edip bayrağı taşırız ve yumuşamış varyantı AYRI ark olarak sunarız.
            var out: [Arc] = []
            var next = s
            next.offset = UInt8(i + 1)
            next.lastWasVowel = Phonology.isVowel(ch)
            next.lastWasVoiceless = Phonology.isVoiceless(ch)
            if Phonology.isVowel(ch) {
                next.isBack = Phonology.isBack(ch)
                next.isRounded = Phonology.isRounded(ch)
            }
            if isLast {
                next.pendingSoften = root.softensFinal
                next.pendingVowelDrop = root.dropsVowel
            }
            // Kök maliyeti tek seferde son harfte yazılır (maliyet itme Faz 4'te).
            out.append(Arc(symbol: ch, target: next, lexDelta: isLast ? root.lexCost : 0))

            // Yumuşamış varyant: `kitap` → `kitab-`. Yalnız son harfte ve
            // sözlüksel bayrak varsa.
            if isLast, root.softensFinal, let soft = Phonology.softening[ch] {
                ch = soft
                var softNext = next
                softNext.lastWasVoiceless = Phonology.isVoiceless(soft)
                softNext.pendingSoften = false
                // Yumuşamış kök yalnız ünlüyle başlayan ek alabilir; bunu
                // `suffixStart` içinde kontrol ederiz.
                softNext.pendingVowelDrop = false
                softNext.suffixID = Self.softenedMarker
                out.append(Arc(symbol: soft, target: softNext, lexDelta: root.lexCost))
            }
            return out
        }

        // Kök bitti → ek başlangıçları.
        return suffixStartArcs(s)
    }

    /// Yumuşamış kök işareti — `suffixID` alanında geçici bayrak olarak taşınır.
    /// (Ayrı bir bit yerine kullanılmayan alanın yeniden kullanımı; `Bits` ölçümü
    /// bunu ayrı bir bayrak saymaz çünkü ek seçimi anında tüketilir.)
    private static let softenedMarker: UInt8 = 255

    private func suffixStartArcs(_ s: State) -> [Arc] {
        let candidates = suffixesByContinuation[s.continuation] ?? []
        var out: [Arc] = []
        for suf in candidates {
            // Yumuşamış morfem sonu (kök ya da ek) yalnız ünlüyle başlayan eki alır.
            let softened = (s.suffixID == Self.softenedMarker) || s.softenedMorphemeEnd
            if softened && !suf.startsWithVowelSound { continue }
            // Yumuşama bekleyen (yumuşamamış) morfem, ünlüyle başlayan eki
            // yumuşamadan alamaz — aksi halde `kitapı` / `gelecekim` üretilirdi.
            if s.pendingSoften && suf.startsWithVowelSound { continue }

            var st = s
            st.phase = .suffix
            st.suffixID = suf.id
            st.offset = 0
            st.continuation = suf.to
            st.pendingSoften = false
            st.pendingVowelDrop = false
            st.softenedMorphemeEnd = false
            // İlk parçayı hemen emit et.
            if let arc = emitPiece(state: st, suffix: suf, pieceIndex: 0, extraCost: suf.cost) {
                out.append(contentsOf: arc)
            }
        }
        return out
    }

    private func suffixArcs(_ s: State) -> [Arc] {
        guard let suf = suffixByID[s.suffixID] else { return [] }
        let i = Int(s.offset)
        if i < suf.pieces.count {
            var out = emitPiece(state: s, suffix: suf, pieceIndex: i, extraCost: 0) ?? []
            // Ekin SON parçası ve ek yumuşayabiliyorsa, yumuşamış varyantı da sun.
            // `-AcAk` + `-Im` → `geleceğim`. Yumuşama köke özgü değil, her
            // morfem sınırında işler — bu, spike testlerinin ortaya çıkardığı
            // bir eksikti.
            if i == suf.pieces.count - 1, suf.softensFinal,
               let plain = out.first, let soft = Phonology.softening[plain.symbol] {
                var st = plain.target
                st.lastWasVoiceless = Phonology.isVoiceless(soft)
                st.pendingSoften = false
                st.softenedMorphemeEnd = true
                out.append(Arc(symbol: soft, target: st, lexDelta: plain.lexDelta))
                // Yumuşamamış hâl yalnız ünsüzle başlayan ek (veya kelime sonu)
                // alabilir; bunu `suffixStartArcs` denetler.
                var plainSt = plain.target
                plainSt.pendingSoften = true
                out[0] = Arc(symbol: plain.symbol, target: plainSt, lexDelta: plain.lexDelta)
            }
            return out
        }
        // Ek bitti → sıradaki ek grubu.
        var next = s
        next.phase = .root
        next.offset = UInt8(roots[Int(s.rootIndex)].surface.count)   // kök tükenmiş sayılır
        return suffixStartArcs(next)
    }

    /// Bir ek parçasını yüzeye çevirip ark(lar) üretir.
    /// Kaynaştırma ve `(I)` gibi koşullu parçalar **atlanabilir**, bu yüzden
    /// özyinelemeli olarak sıradaki parçaya geçilir.
    private func emitPiece(state: State, suffix: Suffix, pieceIndex: Int, extraCost: Double) -> [Arc]? {
        guard pieceIndex < suffix.pieces.count else { return nil }
        let ctx = Phonology.VowelContext(isBack: state.isBack, isRounded: state.isRounded)
        let piece = suffix.pieces[pieceIndex]

        var ch: Character?
        switch piece {
        case let .literal(c):
            ch = c
        case .archiA:
            ch = Phonology.realizeA(ctx)
        case .archiI:
            ch = Phonology.realizeI(ctx)
        case .archiD:
            ch = Phonology.realizeD(precedingIsVoiceless: state.lastWasVoiceless)
        case .archiC:
            ch = Phonology.realizeC(precedingIsVoiceless: state.lastWasVoiceless)
        case let .bufferIfVowel(c):
            // Ünlüden sonra kaynaştırma ünsüzü; ünsüzden sonra atlanır.
            ch = state.lastWasVowel ? c : nil
        case .optionalIVowel:
            // `(I)`: ünsüzden sonra bağlantı ünlüsü; ünlüden sonra atlanır.
            ch = state.lastWasVowel ? nil : Phonology.realizeI(ctx)
        }

        guard let emitted = ch else {
            // Parça atlandı — sıradakine geç, maliyeti taşı.
            var skipped = state
            skipped.offset = UInt8(pieceIndex + 1)
            return emitPiece(state: skipped, suffix: suffix, pieceIndex: pieceIndex + 1, extraCost: extraCost)
        }

        var next = state
        next.offset = UInt8(pieceIndex + 1)
        next.lastWasVowel = Phonology.isVowel(emitted)
        next.lastWasVoiceless = Phonology.isVoiceless(emitted)
        if Phonology.isVowel(emitted) {
            next.isBack = Phonology.isBack(emitted)
            next.isRounded = Phonology.isRounded(emitted)
        }
        return [Arc(symbol: emitted, target: next, lexDelta: extraCost)]
    }

    /// Kelime burada bitebilir mi?
    public func isAccepting(_ s: State) -> Bool {
        switch s.phase {
        case .root:
            // Kök tam emit edilmiş ve devam sınıfı kabul ediyorsa.
            guard Int(s.offset) >= roots[Int(s.rootIndex)].surface.count else { return false }
            // Yumuşamış kök tek başına kelime değildir (`kitab` diye kelime yok).
            if s.suffixID == Self.softenedMarker { return false }
            return TurkishMorphotactics.isAccepting(s.continuation)
        case .suffix:
            guard let suf = suffixByID[s.suffixID] else { return false }
            guard Int(s.offset) >= suf.pieces.count else { return false }
            // Yumuşamış ek sonu (`geleceğ`) tek başına kelime değildir.
            if s.softenedMorphemeEnd { return false }
            return TurkishMorphotactics.isAccepting(s.continuation)
        }
    }

    // MARK: - Teşhis

    /// Bir kökten üretilebilecek tüm yüzey formları (sınırlı derinlikte).
    /// Yalnız test ve ölçüm için — decoder bunu kullanmaz.
    public func generate(rootIndex: Int, maxSuffixes: Int = 3) -> [(surface: String, cost: Double)] {
        var out: [(String, Double)] = []
        var stack: [(State, [Character], Double, Int)] = []
        let start = startStates()[rootIndex]
        stack.append((start, [], 0, 0))
        var guardCounter = 0

        while let (st, acc, cost, depth) = stack.popLast() {
            guardCounter += 1
            if guardCounter > 200_000 { break }
            if isAccepting(st) { out.append((String(acc), cost)) }
            guard acc.count < 40 else { continue }           // (I1) yüzey uzunluk sınırı
            let atMorphemeBoundary = (st.phase == .suffix && Int(st.offset) >= (suffixByID[st.suffixID]?.pieces.count ?? 0))
            if atMorphemeBoundary && depth >= maxSuffixes { continue }
            for arc in arcs(from: st) {
                var a = acc; a.append(arc.symbol)
                let d = (arc.lexDelta > 0 && st.phase == .suffix) ? depth + 1 : depth
                stack.append((arc.target, a, cost + arc.lexDelta, d))
            }
        }
        return out
    }
}
