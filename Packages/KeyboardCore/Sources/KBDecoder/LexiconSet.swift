import Foundation
import KBGeometry
import KBLexicon
import KBMorphology

/// Birden çok leksikal kaynağı **tek ABI** arkasında birleştirir (§4).
///
/// Decoder kaynağın hangisi olduğunu bilmez: `startStates` / `arcs` / `isAccepting`
/// görür. Dağıtım `switch` iledir — existential (`any Protocol`) yoktur, çünkü
/// sözleşme §11.C.2 sıcak döngüde ARC trafiği ve kutulama yasaklıyor.
public struct LexiconSet {

    /// Tek bir leksikal kaynak: bir tür, bir dil, bir veri yapısı.
    ///
    /// Dil **kaynağın kendisinden** gelir, decoder'ın taşıdığı bir bayraktan
    /// değil. Aksi halde iki dilin trie'leri aynı `automaton` değerini paylaşır
    /// ve dedup anahtarı onları ayıramazdı — İngilizce `and` ile Türkçe `and`
    /// aynı duruma çökerdi.
    public struct Source {
        public let kind: AutomatonKind
        public let language: UInt8
        public let formTrie: FormTrie?
        public let morphology: MorphologyAutomaton?
        /// Dile özgü sabit skor kaydırması (§5b `offset_ℓ`).
        ///
        /// Paketler bağımsız korpuslardan üretildiği için `−log(freq/total)`
        /// ölçekleri birebir aynı değildir. `offset` bu farkı kapatır ve
        /// **pakete/ölçüme dayanır**, çalışma anında öğrenilmez. Referans dil
        /// için 0 sabitlenir (gauge), yoksa aynı sıralamayı veren sonsuz
        /// katsayı seti oluşur.
        public let offset: Double

        /// **Değişmez:** tam olarak bir yük, ve `kind` onunla uyumlu.
        ///
        /// İkisi birden verilirse `startPositions()` her iki tür düğümü de aynı
        /// kaynak indeksiyle üretir, ama `arcs`/`isAccepting` daima trie dalını
        /// seçer — morfoloji düğümü trie düğümü gibi yorumlanır ve hata
        /// **sessiz** olur (çökme yok, yanlış kelime var).
        public init(kind: AutomatonKind, language: UInt8,
                    formTrie: FormTrie? = nil, morphology: MorphologyAutomaton? = nil,
                    offset: Double = 0) {
            switch kind {
            case .formTrie:
                precondition(formTrie != nil && morphology == nil,
                             "kind .formTrie tam olarak bir form trie ister")
            case .morphology:
                precondition(morphology != nil && formTrie == nil,
                             "kind .morphology tam olarak bir morfoloji otomatı ister")
            case .personal, .domain:
                precondition(formTrie != nil && morphology == nil,
                             "\(kind) form trie ile temsil edilir")
            }
            self.kind = kind
            self.language = language
            self.formTrie = formTrie
            self.morphology = morphology
            self.offset = offset
        }

        public static func forms(_ t: FormTrie, language: UInt8 = 0,
                                 offset: Double = 0) -> Source {
            Source(kind: .formTrie, language: language, formTrie: t, offset: offset)
        }
        public static func morphology(_ m: MorphologyAutomaton, language: UInt8 = 0,
                                      offset: Double = 0) -> Source {
            Source(kind: .morphology, language: language, morphology: m, offset: offset)
        }
        /// Kullanıcının kendi kelimeleri (§8.7).
        ///
        /// Yapı olarak form trie; ayrı `kind` taşımasının sebebi **kimlik**:
        /// motoru yeniden kurarken paket kaynaklarının hangileri olduğu
        /// `kind != .personal` ile ayırt ediliyor. Türü `.formTrie` yapmak,
        /// her yeniden kurulumda eski kişisel trie'yi de "paket" sayıp
        /// yanına bir yenisini eklerdi.
        public static func personal(_ t: FormTrie, language: UInt8 = 0) -> Source {
            Source(kind: .personal, language: language, formTrie: t, offset: 0)
        }
    }

    /// `Position.automaton` bu diziye **indekstir**, `AutomatonKind.rawValue`
    /// değil. Tür artık kaynağı tekil belirlemiyor: iki dilin form trie'si de
    /// `.formTrie`.
    public let sources: [Source]

    /// **Birleşik alfabe.** Kaynaklar farklı sembol uzayları kullanır
    /// (trie kendi indeksleri, morfoloji `Character`). Decoder tek uzay görmeli,
    /// yoksa `lastSurfaceSymbol` karşılaştırmaları anlamsızlaşır. Çoklu dilde
    /// bu birleşim iki dilin alfabelerini de kapsar.
    public let alphabet: [Unicode.Scalar]
    private let symbolOfScalar: [Unicode.Scalar: UInt16]
    /// Kaynak indeksi → o trie'nin sembol indeksinden birleşik indekse eşleme.
    private let trieSymbolToMerged: [[UInt16]]
    private let morphologyLayouts: [MorphologyNodeLayout?]

    /// Tek dilli kısayol — mevcut çağrı yerleri ve testler için.
    public init(formTrie: FormTrie?, morphology: MorphologyAutomaton?) {
        var srcs: [Source] = []
        if let t = formTrie { srcs.append(.forms(t)) }
        if let m = morphology { srcs.append(.morphology(m)) }
        self.init(sources: srcs)
    }

    public init(sources: [Source]) {
        precondition(sources.count <= 255, "kaynak indeksi UInt8'e sığmalı")
        self.sources = sources

        var scalars = Set<Unicode.Scalar>()
        for src in sources {
            if let t = src.formTrie { scalars.formUnion(t.alphabet) }
            if let m = src.morphology {
                for r in m.roots { for c in r.surface { scalars.formUnion(c.unicodeScalars) } }
                // Eklerin üretebileceği tüm yüzey harfleri — arşifonemlerin tüm
                // gerçekleşmeleri dahil.
                for c in "abcçdefgğhıijklmnoöprsştuüvyz" { scalars.formUnion(c.unicodeScalars) }
            }
        }
        let sorted = scalars.sorted()
        self.alphabet = sorted
        var map = [Unicode.Scalar: UInt16]()
        for (i, s) in sorted.enumerated() { map[s] = UInt16(i) }
        self.symbolOfScalar = map

        self.trieSymbolToMerged = sources.map { src in
            src.formTrie.map { t in t.alphabet.map { map[$0] ?? 0 } } ?? []
        }
        self.morphologyLayouts = sources.map { $0.morphology?.nodeLayout }
    }

    /// Geriye dönük erişim: ilk form trie / ilk morfoloji.
    public var formTrie: FormTrie? { sources.first(where: { $0.formTrie != nil })?.formTrie }
    public var morphology: MorphologyAutomaton? {
        sources.first(where: { $0.morphology != nil })?.morphology
    }

    /// Bu konumun dili — dedup anahtarına ve `F_lang`'e girer.
    public func language(of p: Position) -> UInt8 {
        Int(p.automaton) < sources.count ? sources[Int(p.automaton)].language : 0
    }

    /// Aktif dillerin listesi (kaynak sırasına göre, tekilleştirilmiş).
    public var languages: [UInt8] {
        var seen = Set<UInt8>(), out: [UInt8] = []
        for s in sources where !seen.contains(s.language) { seen.insert(s.language); out.append(s.language) }
        return out
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
        let i = Int(p.automaton)
        guard i < sources.count else { return 0 }
        guard let m = sources[i].morphology, let layout = morphologyLayouts[i],
              let st = MorphologyAutomaton.State.unpacked(p.node, layout) else {
            return 0   // trie: kök bound'u zaten 0
        }
        return m.potential(st)
    }

    /// (I1) yüzey uzunluk sınırı — **kaynağa özgü**.
    /// Ortak tek sınır kullanmak kaynak-bağımsız değildi: küçük sınırla
    /// derlenmiş bir trie, yanındaki morfolojinin türetimini de erken keserdi.
    public func maxSurfaceLen(_ automaton: UInt8) -> Int {
        let i = Int(automaton)
        guard i < sources.count else { return LexiconLimits.maxSurfaceLength }
        if let t = sources[i].formTrie { return t.maxSurfaceLen }
        if sources[i].morphology != nil { return TurkishMorphotactics.maxSurfaceLen }
        return LexiconLimits.maxSurfaceLength
    }

    /// Yüzey kimliğini bir ark boyunca ilerletir.
    ///
    /// Politika **burada** yaşar, decoder'da değil: decoder yeni bir kaynak
    /// türü eklendiğinde doğru `surfaceId` kuralını bilmek zorunda kalmamalı.
    public func advanceSurfaceId(from current: UInt64, arc: LexArc) -> UInt64 {
        let i = Int(arc.target.automaton)
        if i < sources.count, sources[i].formTrie != nil {
            // Trie'de düğüm öneki tekil belirler — hash gereksiz, çakışma yok.
            return arc.target.node
        } else {
            // 64-bit FNV-1a. 32-bit'te aynı düğümde `b` rakip yüzey için
            // çakışma olasılığı ≈ b(b−1)/2³³ (b=128 → ~2·10⁻⁶); 64-bit bunu
            // pratikte sıfırlıyor ve maliyeti aynı.
            // Bayt değil sembol karıştırılıyor; sabitler ortak.
            return (current ^ UInt64(arc.symbol)) &* FNV1a.prime
        }
    }

    public func initialSurfaceId(_ p: Position) -> UInt64 {
        let i = Int(p.automaton)
        return (i < sources.count && sources[i].formTrie != nil)
            ? p.node : FNV1a.offsetBasis
    }

    /// Başlangıç konumları — her kaynak için ayrı, dolayısıyla her dil için ayrı.
    ///
    /// Kökler ortak önekli trie'de paylaşıldığı için morfoloji tek başlangıç
    /// durumu döndürüyor; iki dilli kurulumda toplam frontier hâlâ küçük.
    public func startPositions() -> [Position] {
        var out: [Position] = []
        for (i, src) in sources.enumerated() {
            let a = UInt8(i)
            if src.formTrie != nil {
                out.append(Position(automaton: a, node: UInt64(FormTrie.rootNode)))
            }
            if let m = src.morphology, let layout = morphologyLayouts[i] {
                for s in m.startStates() {
                    guard let p = s.packed(layout) else { continue }
                    out.append(Position(automaton: a, node: p))
                }
            }
        }
        return out
    }

    public func arcs(from p: Position) -> [LexArc] {
        var out: [LexArc] = []
        var scratch: [MorphologyAutomaton.Arc] = []
        arcs(from: p, into: &out, scratch: &scratch)
        return out
    }

    /// Tampona yazan sürüm — **sıcak yol bunu kullanır** (§11.C.2).
    ///
    /// Ölçüldü: durum başına ~0.8 µs harcanıyordu ve bunun büyük kısmı çağrı
    /// başına iki dizi tahsisiydi (biri burada, biri morfoloji otomatında).
    /// `scratch` çağrı yerinde bir kez ayrılıp yeniden kullanılır.
    public func arcs(from p: Position,
                     into out: inout [LexArc],
                     scratch: inout [MorphologyAutomaton.Arc]) {
        let i = Int(p.automaton)
        guard i < sources.count else { return }
        if let t = sources[i].formTrie {
            let node = UInt32(truncatingIfNeeded: p.node)
            let remap = trieSymbolToMerged[i]
            for j in t.arcRange(node) {
                out.append(LexArc(symbol: remap[Int(t.arcSymbol(j))],
                                  target: Position(automaton: p.automaton,
                                                   node: UInt64(t.arcTarget(j))),
                                  lexDelta: t.arcLexDelta(j)))
            }
        } else if let m = sources[i].morphology, let layout = morphologyLayouts[i],
                  let st = MorphologyAutomaton.State.unpacked(p.node, layout) {
            scratch.removeAll(keepingCapacity: true)
            m.arcs(from: st, into: &scratch)
            for a in scratch {
                guard let sc = a.symbol.unicodeScalars.first,
                      let sym = symbolOfScalar[sc],
                      let packed = a.target.packed(layout) else { continue }
                out.append(LexArc(symbol: sym,
                                  target: Position(automaton: p.automaton, node: packed),
                                  lexDelta: a.lexDelta))
            }
        }
    }

    public func isAccepting(_ p: Position) -> Bool {
        let i = Int(p.automaton)
        guard i < sources.count else { return false }
        if let t = sources[i].formTrie {
            return t.isTerminal(UInt32(truncatingIfNeeded: p.node))
        }
        if let m = sources[i].morphology, let layout = morphologyLayouts[i],
           let st = MorphologyAutomaton.State.unpacked(p.node, layout) {
            return m.isAccepting(st)
        }
        return false
    }

    /// Kabul anındaki kalan ham `F_lex`.
    ///
    /// Morfolojide de sıfır DEĞİL: çıplak kök trie bound'unu ödemiş olur,
    /// asıl `L(kök)` ile fark terminalin fazlasıdır (§MorphologyAutomaton).
    public func acceptExtra(_ p: Position) -> Double {
        let i = Int(p.automaton)
        guard i < sources.count else { return 0 }
        if let t = sources[i].formTrie {
            return t.nodeTermExtra(UInt32(truncatingIfNeeded: p.node))
        }
        if let m = sources[i].morphology, let layout = morphologyLayouts[i],
           let st = MorphologyAutomaton.State.unpacked(p.node, layout) {
            return m.acceptExtra(st)
        }
        return 0
    }

    /// Bu yüzey form listesinde var mı? §7 tek sahiplik kuralı için:
    /// *"form listesinde varsa değer oradan gelir; morfoloji aynı yüzeye
    /// ulaşsa bile kendi maliyetini eklemez."*
    public func formTrieHas(_ word: String) -> Bool {
        sources.contains { $0.formTrie?.lookup(word) != nil }
    }

    /// Bir yüzeyin bir dildeki eşleşmesi.
    public struct SurfaceMatch: Equatable, Sendable {
        /// **Ham** `F_lex` — `w_lex` ile çarpılmamış, `offset` eklenmemiş.
        ///
        /// Dil terimleri ayrı taşınır (§0 düz vektör): burada karıştırılsaydı
        /// çağıran `w_lex · (F_lex + offset)` hesaplardı, oysa decoder
        /// `w_lex · F_lex + offset` hesaplıyor. İki yol ayrışırdı.
        public let lexCost: Double
        public let language: UInt8
        /// Form listesinden mi geldi — §7 sahipliği bunu okur.
        public let isFormList: Bool
        /// **Eşleşmeyi üreten kaynağın** `offset_ℓ`'si.
        ///
        /// Dilden türetmek yeterli değil: API aynı dilde farklı offset taşıyan
        /// kaynaklara izin veriyor (bir dilin form listesi ile morfolojisi ayrı
        /// kalibre edilebilir). Dilin "ilk" kaynağından okumak literal ve
        /// decoder maliyetlerini ayrıştırırdı.
        public let offset: Double
    }

    /// Bu yüzeyi kabul eden **her dil için** en iyi eşleşme.
    ///
    /// §7 tek sahipliği **dil içinde** çözülür: aynı dilde form listesi
    /// morfolojiyi ezer. Diller arasında ezme **yoktur** — hangi dilin
    /// kazandığı ancak dil terimleri (`F_lang`) eklendikten sonra belli olur ve
    /// o bilgi burada yok (`prior`/`previous` çalışma anına ait).
    ///
    /// Küresel bir "form listesi kazanır" kuralı yanlış olurdu: İngilizce form
    /// listesi Türkçe morfolojinin ürettiği bir yüzeyi içeriyorsa, Türkçe aday
    /// dil önseli ne olursa olsun elenirdi.
    ///
    /// Uzamsal kanıt kullanılmaz — bu bir **yüzey sorgusudur**, kod çözme değil.
    public func matches(ofSurface word: String) -> [SurfaceMatch] {
        guard !word.isEmpty else { return [] }
        var best: [UInt8: SurfaceMatch] = [:]

        func offer(_ m: SurfaceMatch) {
            guard let cur = best[m.language] else { best[m.language] = m; return }
            // Aynı dilde: form listesi önceliklidir, daha ucuz olan değil.
            if cur.isFormList != m.isFormList {
                if m.isFormList { best[m.language] = m }
            } else if m.lexCost < cur.lexCost {
                best[m.language] = m
            }
        }

        for src in sources {
            guard let t = src.formTrie, let c = t.lookup(word) else { continue }
            offer(SurfaceMatch(lexCost: c, language: src.language,
                               isFormList: true, offset: src.offset))
        }

        // Morfoloji yürüyüşü — yalnız o dilde form listesi kabul etmediyse
        // anlamlı, ama yine de hesaplanır: `isFormList` önceliği `offer` içinde.
        var symbols: [UInt16] = []
        symbols.reserveCapacity(word.count)
        for ch in word {
            guard ch.unicodeScalars.count == 1,
                  let sym = symbol(for: ch.unicodeScalars.first!) else {
                return Array(best.values)   // alfabe dışı → morfoloji yürüyemez
            }
            symbols.append(sym)
        }

        for (i, src) in sources.enumerated() where src.morphology != nil {
            // O dilde form listesi zaten kabul ettiyse morfolojiyi yürütme (§7).
            if best[src.language]?.isFormList == true { continue }
            if let c = morphologyCost(sourceIndex: i, symbols: symbols) {
                offer(SurfaceMatch(lexCost: c, language: src.language,
                                   isFormList: false, offset: src.offset))
            }
        }
        return Array(best.values).sorted { $0.language < $1.language }
    }

    /// Tek dilli kısayol — çağıranın dil terimlerine ihtiyacı yoksa.
    ///
    /// **Çoklu dilde kullanmayın:** `offset` ve önsel uygulanmadan minimum
    /// alır, yani decoder'ın seçtiğinden farklı bir dil kazanabilir.
    public func lexCost(ofSurface word: String) -> Double? {
        matches(ofSurface: word).map(\.lexCost).min()
    }

    /// Bu yüzeyi herhangi bir kaynak kabul ediyor mu — `V` üyeliği.
    public func containsSurface(_ word: String) -> Bool {
        !matches(ofSurface: word).isEmpty
    }

    /// Tek bir morfoloji kaynağında yüzey yürüyüşü.
    ///
    /// Dedup `Position` üzerinde: morfoloji durumu geleceği etkileyen fonolojik
    /// ve devam-sınıfı bilgisini zaten taşıdığı için aynı duruma gelen daha
    /// pahalı analizin farklı bir geleceği kalmaz (`min_A` ile uyumlu).
    private func morphologyCost(sourceIndex i: Int, symbols: [UInt16]) -> Double? {
        var frontier: [Position: Double] = [:]
        for p in startPositions() where p.automaton == UInt8(i) {
            let c = startCost(p)
            if let old = frontier[p], old <= c { continue }
            frontier[p] = c
        }
        guard !frontier.isEmpty else { return nil }

        var arcBuf: [LexArc] = []
        var scratch: [MorphologyAutomaton.Arc] = []
        for sym in symbols {
            var next: [Position: Double] = [:]
            next.reserveCapacity(frontier.count * 2)
            for (p, cost) in frontier {
                arcBuf.removeAll(keepingCapacity: true)
                arcs(from: p, into: &arcBuf, scratch: &scratch)
                for arc in arcBuf where arc.symbol == sym {
                    let c = cost + arc.lexDelta
                    if let old = next[arc.target], old <= c { continue }
                    next[arc.target] = c
                }
            }
            if next.isEmpty { return nil }
            frontier = next
        }

        var accepted: Double?
        for (p, cost) in frontier where isAccepting(p) {
            let total = cost + acceptExtra(p)
            if accepted == nil || total < accepted! { accepted = total }
        }
        return accepted
    }
}
