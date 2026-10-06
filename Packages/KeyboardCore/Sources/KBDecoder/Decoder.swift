import Foundation
import KBGeometry
import KBLexicon
import KBMorphology
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
    public var surfaceId: UInt64
    public var touchIndex: UInt16
    /// Önceki yüzey **pozisyonunun** sembolü (§4.1) — son fiziksel emisyon değil.
    public var lastSurfaceSymbol: UInt16
    /// Kelime başındayız — `om(j)` sınıfının ilk dalı (§5.1).
    ///
    /// **Türetilebilir ve bilerek türetilmiyor** (§9). Yüklem sınandı:
    /// `atWordStart ⟺ (automaton, node) ∈ startPositions()` — üretim
    /// leksikonunda 291 133 durumda sıfır ihlal, çünkü hiçbir ark tohum
    /// konumuna geri dönmüyor (`AtWordStartDerivableTests`).
    ///
    /// Alan yine de duruyor: türetmek `omissionCost`'a omission başına bir
    /// küme sorgusu ekler ve karşılığında anahtar 86 bitten 85 bite iner —
    /// §4'ün `UInt64` hedefine zaten uzak bir sayı. Bir bit için sıcak yola
    /// arama koymak yanlış takas.
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
    /// Bu adayı üreten **kaynak indeksi** (`LexiconSet.sources` içine) — §7
    /// önceliği ve teşhis için. `AutomatonKind.rawValue` DEĞİL: çoklu dilde iki
    /// form trie'si aynı türe sahip, farklı kaynaklardır.
    public let source: UInt8
    /// Adayın dili (§5b). Casing kuralları ve dil önseli bunu okur — Türkçe
    /// `i→İ` dönüşümünü İngilizce `it`'e uygulamak `İt` üretirdi.
    public let language: UInt8

    public init(word: String, cost: Double, emitCount: Int,
                source: UInt8 = 0, language: UInt8 = 0) {
        self.word = word
        self.cost = cost
        self.emitCount = emitCount
        self.source = source
        self.language = language
    }
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
    /// Aday tuş budaması (§3) bir **arama sezgiselidir**, model terimi değil —
    /// oracle onu tanımlamaz. Model-eşdeğerlik kapısı (§5.4/1) bu yüzden onu
    /// kapatabilmeli, yoksa beam ile oracle kaçınılmaz olarak ayrışır.
    public let disableCandidatePruning: Bool

    /// Dil terimleri (§5b). Formül `LanguageModel`'de — **tek tanım**;
    /// literal kanalı da aynı fonksiyonu çağırır, yoksa `Δ` iki farklı
    /// formülün farkı olurdu.
    ///
    /// `IncrementalDecoder` kurulurken bu değer **snapshot**'lanır (Decoder bir
    /// değer tipi). Yani token ortasında değiştirmek aktif beam'i etkilemez;
    /// değişiklik bir sonraki token'da yürürlüğe girer. Bu, §5b'nin "model
    /// sürümü yalnız token sınırında değişir" kuralının doğal karşılığıdır.
    public var languageModel = LanguageModel()

    /// Kelime bigramı (§2 öznitelik 13). `nil` iken `F_ctx ≡ 0` ve motor
    /// bugünkü davranışını birebir koruyor.
    public var bigrams: BigramPack?

    /// Bağlam: **kapanmış önceki token**. `nil` = bağlam bilinmiyor.
    ///
    /// Prefix-causal (§3): token boyunca sabit ve token **başlamadan** belli.
    /// `IncrementalDecoder` kurulurken kimliğe çözülüp snapshot'lanıyor, yani
    /// token ortasında değiştirmek aktif beam'i etkilemiyor — `languageModel`
    /// ile aynı kural, aynı gerekçe (§5b model sürümü).
    public var contextWord: String?

    /// `F_ctx(w | ctx)` — ham, `w_ctx` ile çarpılmamış.
    ///
    /// `contextID` çağıran tarafından bir kez çözülür; her aday için yüzey
    /// aramasını tekrarlamak token başına `log n` yerine `k · log n` olurdu.
    func contextDelta(_ word: String, contextID: UInt32?) -> Double {
        guard let pack = bigrams, let ctx = contextID,
              let w = pack.id(of: word) else { return 0 }
        return pack.delta(context: ctx, word: w)
    }

    /// Bağlam yüzeyini kimliğe çözer — token başında **bir kez**.
    func contextID() -> UInt32? {
        guard let pack = bigrams, let ctx = contextWord else { return nil }
        return pack.id(of: ctx)
    }

    /// Bir kaynağın **kelime başına sabit** dil maliyeti.
    ///
    /// Tohuma eklenir, kabule değil. İkisi matematiksel olarak eşdeğer (sabit
    /// bir terim, maliyet itmenin telescoping'ini bozmaz), ama tohumda eklemek
    /// budamanın da doğru davranmasını sağlar: düşük önselli dilin adayları
    /// baştan pahalı görünür ve beam'i haksız yere doldurmaz.
    ///
    /// Prefix-causal: kaynağın dili tohum anında bellidir.
    public func languageCost(ofSource i: Int) -> Double {
        guard i < lexicon.sources.count else { return 0 }
        let src = lexicon.sources[i]
        return languageModel.cost(language: src.language,
                                  offset: src.offset, weights: weights)
    }

    public init(layout: KeyLayout,
                spatial: SpatialModel,
                lexicon: LexiconSet,
                weights: ScoreWeights = ScoreWeights(),
                beamWidth: Int = 128,
                disableDedup: Bool = false,
                disablePruning: Bool = false,
                disableCandidatePruning: Bool = false) {
        precondition(weights.satisfiesLexPositivity, "w_lex > 0 kısıtı ihlal edildi (§7.1)")
        self.layout = layout
        self.spatial = spatial
        self.lexicon = lexicon
        self.weights = weights
        self.beamWidth = beamWidth
        self.disableDedup = disableDedup
        self.disablePruning = disablePruning
        self.disableCandidatePruning = disableCandidatePruning
    }

    /// Tek kaynaklı kısayol.
    public init(layout: KeyLayout, spatial: SpatialModel, trie: FormTrie,
                weights: ScoreWeights = ScoreWeights(), beamWidth: Int = 128,
                disableDedup: Bool = false, disablePruning: Bool = false,
                disableCandidatePruning: Bool = false) {
        self.init(layout: layout, spatial: spatial,
                  lexicon: LexiconSet(formTrie: trie, morphology: nil),
                  weights: weights, beamWidth: beamWidth,
                  disableDedup: disableDedup, disablePruning: disablePruning,
                  disableCandidatePruning: disableCandidatePruning)
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

    /// **Tekrar insertion'ı** yüklemi — sözleşme §2'nin `F_ins,rep` sınıfı.
    ///
    /// Fazladan dokunma, en son emit edilen karakterin tuşuna düşüyor mu.
    /// Decoder ve oracle **aynı** tanımı kullanmak zorunda: ayrı yazılsalardı
    /// eşdeğerlik testi ilk ayrışmada patlardı (nitekim patladı — sınıf
    /// decoder'a eklenip oracle'a eklenmemişti).
    ///
    /// **Prefix-causal**: yalnız geçmişten türeyen `lastChar` ve o anki
    /// dokunmaya bakıyor.
    public static func isRepeatInsertion(touch: TouchSample, lastChar: Character?,
                                         layout: KeyLayout) -> Bool {
        guard let lastChar, let k = layout.nearestKey(to: touch.down) else { return false }
        return layout.keys[k].char == lastChar
    }

    /// - Parameter lastChar: en son **emit edilen** karakter (`nil` ise henüz yok).
    func insertionCost(_ touches: [TouchSample], _ i: Int,
                       lastChar: Character?) -> Double {
        let t = touches[i - 1]
        let bg = weights.wInsBg * spatial.negLogPBackground(t)

        if Decoder.isRepeatInsertion(touch: t, lastChar: lastChar, layout: layout) {
            return weights.wInsRepeat + bg
        }

        guard i >= 2 else { return weights.wIns + bg }   // t_0 yok → normal sınıf (§5.1)
        let prev = touches[i - 2]
        let dt = t.timestamp - prev.timestamp
        let dx = t.down.x - prev.down.x, dy = t.down.y - prev.down.y
        let dist = (dx * dx + dy * dy).squareRoot()
        return ((dt < weights.tauFast && dist < weights.dNear) ? weights.wInsNear : weights.wIns) + bg
    }

    /// Bir dokunma için **makul semboller**.
    ///
    /// **Bu bir ARAMA SEZGİSELİDİR, model terimi değil.** Skor sözleşmesi onu
    /// tanımlamaz (planda benzer bir cümle var ama normatif belgede yok — bir
    /// ara yorumda sözleşmeye atıf yapmıştım, yanlıştı). Dolayısıyla
    /// model-eşdeğerlik kapısında `disableCandidatePruning` ile kapatılır.
    ///
    /// Ölçüm: budama olmadan durum başına ~215 ark açılıyordu (308 kök, beam
    /// 128). Hiçbir geçiş türü baskın değildi; sorun fanout'un kendisiydi.
    ///
    /// Eşdeğerlik sınıfı korunur: `u` tuşuna basıldıysa `ü` de makuldür (§2.3),
    /// yoksa deasciification çalışmaz.
    func plausibleSymbols(for t: TouchSample, alphabet: [Unicode.Scalar]) -> [Bool] {
        var costs: [(Int, Double)] = []
        costs.reserveCapacity(layout.keys.count)
        for k in layout.keys.indices {
            costs.append((k, spatial.negLogP(t, keyIndex: k)))
        }
        // KARARLI sıralama: eşit uzamsal maliyette tuş indeksi tiebreak.
        // Swift'in sort'u kararlı değil; iki tuşun tam ortasına gelen bir
        // dokunmada ilk altıya hangilerinin gireceği değişebilir ve bu,
        // az önce düzeltilen determinizmi aday üretiminden geri bozardı.
        costs.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard let best = costs.first?.1 else { return Array(repeating: true, count: alphabet.count) }

        var allowedChars = Set<Character>()
        for (k, c) in costs.prefix(weights.maxKeyCandidates) {
            guard c - best <= weights.candidateCostWindow else { break }
            let ch = layout.keys[k].char
            allowedChars.insert(ch)
            // Eşdeğerlik: bu tuşa basılmışsa diyakritik biçimleri de makul.
            for (diacritic, base) in layout.asciiBase where base == ch {
                allowedChars.insert(diacritic)
            }
        }

        var mask = [Bool](repeating: false, count: alphabet.count)
        for (i, sc) in alphabet.enumerated() where allowedChars.contains(Character(sc)) {
            mask[i] = true
        }
        return mask
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
    /// Yeniden kullanılan tamponlar — sıcak döngüde tahsis olmasın diye (§11.C.2).
    private var arcBuf: [LexiconSet.LexArc] = []
    private var morphScratch: [MorphologyAutomaton.Arc] = []
    /// Dokunma başına makul sembol maskesi (§3 aday budaması). Bir kez
    /// hesaplanır, o dokunmanın tüm beam girdilerinde yeniden kullanılır.
    private var symbolMask: [Bool] = []
    /// Bir önceki dokunmanın maskesi — `TR` iki dokunma tükettiği için gerekli.
    private var prevSymbolMask: [Bool] = []
    /// Bağlam kimliği — kurulurken **bir kez** çözülüyor (§3 prefix-causality).
    ///
    /// `Decoder` bir değer tipi ve `contextWord`'ü token ortasında değiştirmek
    /// aktif beam'i etkilememeli: `languageModel` snapshot'ıyla aynı kural.
    /// Ayrıca yüzey aramasını aday başına tekrarlamaktan kurtarıyor.
    let context: UInt32?

    public init(decoder: Decoder) {
        self.d = decoder
        self.context = decoder.contextID()
        var seeds: [Int32] = []
        for pos in decoder.lexicon.startPositions() {
            let key = DecoderStateKey(
                automaton: pos.automaton,
                language: decoder.lexicon.language(of: pos),
                node: pos.node,
                surfaceId: decoder.lexicon.initialSurfaceId(pos),
                touchIndex: 0,
                lastSurfaceSymbol: Decoder.noSymbol,
                atWordStart: true)
            // Tohum maliyeti = w_lex · potential(start). Bu olmadan itilmiş
            // toplam, gerçek maliyetten potential(start) kadar düşük çıkar ve
            // morfoloji trie karşısında sistematik avantaj kazanır (§7.1).
            arena.append(BeamEntry(
                key: key,
                cost: decoder.weights.wLex * decoder.lexicon.startCost(pos)
                    + decoder.languageCost(ofSource: Int(pos.automaton)),
                parent: -1, emission: .none, emitCount: 0))
            seeds.append(Int32(arena.count - 1))
        }
        // Kökten `OM` kapanışı: yalnız omission ile erişilen kelimeler de modelde
        // geçerlidir (oracle §5.2'de `D[0][j]` zinciri bunu tanımlar).
        // Tohumların KENDİSİ budanmaz (kanıt görmeden eleme yapılmamalı), ama
        // onlardan çıkan omission KAPANIŞI normal budanır.
        //
        // Kapanışı da budamasız bırakmak, kök trie'sinde 40 derinliğe kadar
        // sınırsız genişlikte gezinmeye yol açıyordu: ölçümde gecikme beam
        // genişliğinden BAĞIMSIZ çıkıyordu (beam 48 ve 128 aynı süre) — çünkü
        // asıl iş beam'in dışındaydı.
        //
        // Kök trie'sinden sonra tohum sayısı zaten 2 (bir kaynak başına bir
        // tane), yani "tohumlar budanmasın" istisnasının pratik maliyeti yok.
        let seedStates = dedupAndPrune(seeds, isSeed: true)
        frontier = [closeOmissions(seedStates, isSeed: false, minKeep: seedStates.count)]
    }

    /// Bir arkı izleyerek hedef anahtarı kurar — kaynak-bağımsız.
    private func advance(_ e: BeamEntry, _ arc: LexiconSet.LexArc, touchIndex: Int?) -> DecoderStateKey {
        DecoderStateKey(
            automaton: arc.target.automaton,
            language: e.key.language,
            node: arc.target.node,
            surfaceId: d.lexicon.advanceSurfaceId(from: e.key.surfaceId, arc: arc),
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
        // Aday tuş budaması: uzamsal skorlar dokunma başına BİR KEZ hesaplanır
        // ve tüm beam girdilerinde paylaşılır (§3, §11.C.5).
        prevSymbolMask = symbolMask
        symbolMask = d.disableCandidatePruning
            ? [Bool](repeating: true, count: d.lexicon.alphabet.count)
            : d.plausibleSymbols(for: t, alphabet: d.lexicon.alphabet)
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

    /// Teşhis: bu decode sırasında **üretilen toplam durum** sayısı.
    /// Darboğazın nerede olduğunu tahmin etmek yerine ölçmek için.
    public var statesCreated: Int { arena.count }

    /// Teşhis: geçiş türüne göre üretilen durum sayısı.
    /// Darboğazı tahmin etmek yerine ölçmek için — iki kez yanlış tahmin ettim.
    public private(set) var omissionStates: Int = 0
    public private(set) var subStates: Int = 0
    public private(set) var transpositionStates: Int = 0

    /// Teşhis: tohum frontier'ındaki durum sayısı.
    /// Tohumların budanmadığı invariantını doğrudan sınamak için (§Determinizm).
    public var seedFrontierCount: Int { frontier.first?.count ?? 0 }

    public func results(topK: Int = 3) -> [DecodeResult] {
        // §7 tek sahiplik: aynı yüzey iki kaynaktan gelirse **form listesi
        // kazanır**, daha ucuz olan değil. Min almak, morfolojinin normatif
        // trie maliyetini ezmesine izin verirdi.
        // Anahtar `(yüzey, dil)`: §7 sahipliği dil İÇİNDE tanımlı. Yalnız
        // yüzeye bakmak, bir dilin form listesinin başka bir dilin morfoloji
        // adayını elemesine yol açardı — dil terimleri henüz karşılaştırılmadan.
        struct Key: Hashable { let word: String; let language: UInt8 }
        var best: [Key: DecodeResult] = [:]
        for slot in frontier[frontier.count - 1] {
            let e = arena[Int(slot)]
            let pos = LexiconSet.Position(automaton: e.key.automaton, node: e.key.node)
            guard e.cost.isFinite, d.lexicon.isAccepting(pos) else { continue }
            let word = reconstruct(Int(slot))
            // `F_ctx` **terminal** (§3.2): yalnız burada, kabul anında ekleniyor.
            // Beam genişletmesine girmiyor, dolayısıyla erken budamaya yardım
            // etmiyor — sözleşmenin kabul ettiği bedel. Karşılığında dedup
            // anahtarı bağlam taşımak zorunda kalmıyor: bağlam token boyunca
            // sabit olduğu için aynı yüzeye varan iki yol aynı `F_ctx`'i alır.
            let total = e.cost + d.weights.wLex * d.lexicon.acceptExtra(pos)
                + d.weights.wCtx * d.contextDelta(word, contextID: context)
            let candidate = DecodeResult(word: word, cost: total,
                                         emitCount: Int(e.emitCount),
                                         source: e.key.automaton,
                                         language: e.key.language)
            let key = Key(word: word, language: e.key.language)
            guard let cur = best[key] else { best[key] = candidate; continue }
            // Öncelik **türe** bakar, kaynak indeksine değil: çoklu dilde iki
            // form trie'si farklı indekslerde ama ikisi de form listesidir.
            let curIsTrie = d.lexicon.sources[Int(cur.source)].formTrie != nil
            let newIsTrie = d.lexicon.sources[Int(candidate.source)].formTrie != nil
            if curIsTrie != newIsTrie {
                if newIsTrie { best[key] = candidate }        // kaynak önceliği
            } else if candidate.cost < cur.cost {
                best[key] = candidate                         // aynı kaynak: en ucuz
            }
        }
        // Aynı yüzey iki dilde de kabul edildiyse kullanıcıya iki kez
        // gösterilmez: dil terimleri dahil **tam maliyetle** en iyisi seçilir.
        // Bu, elemenin tek meşru yeri — burada tüm terimler hesaplanmış durumda.
        var byWord: [String: DecodeResult] = [:]
        for r in best.values {
            guard let cur = byWord[r.word] else { byWord[r.word] = r; continue }
            if r.cost < cur.cost || (r.cost == cur.cost && r.language < cur.language) {
                byWord[r.word] = r
            }
        }
        // `Dictionary.values` sırası deterministik değil; eşit maliyette
        // kelimeye göre tiebreak yaparak kararlı çıktı üretiyoruz.
        return byWord.values
            .sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.word < $1.word }
            .prefix(topK).map { $0 }
    }

    // MARK: - Geçişler

    private mutating func expandConsuming(from slot: Int32, touchIndex i: Int, into out: inout [Int32]) {
        let e = arena[Int(slot)]
        let t = touches[i - 1]

        // --- SUB / SUB_eq ---
        arcBuf.removeAll(keepingCapacity: true)
        d.lexicon.arcs(from: position(e.key), into: &arcBuf, scratch: &morphScratch)
        for arc in arcBuf {
            // Makul olmayan semboller hiç denenmez.
            guard Int(arc.symbol) < symbolMask.count, symbolMask[Int(arc.symbol)] else { continue }
            let ch = Character(d.lexicon.scalar(arc.symbol))
            guard let cost = d.substitutionCost(t, char: ch) else { continue }
            arena.append(BeamEntry(
                key: advance(e, arc, touchIndex: i),
                cost: e.cost + cost + d.weights.wLex * arc.lexDelta + d.weights.wLen,
                parent: slot,
                emission: .one(arc.symbol),
                emitCount: e.emitCount + 1))
            out.append(Int32(arena.count - 1))
            subStates += 1
        }

        // --- INS: dokunma tüketir, otomat ilerlemez ---
        var insKey = e.key
        insKey.touchIndex = UInt16(i)
        arena.append(BeamEntry(key: insKey,
                               cost: e.cost + d.insertionCost(
                                   touches, i,
                                   lastChar: e.key.lastSurfaceSymbol == Decoder.noSymbol
                                       ? nil
                                       : Character(d.lexicon.scalar(e.key.lastSurfaceSymbol))),
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

        var firstArcs: [LexiconSet.LexArc] = []
        d.lexicon.arcs(from: position(e.key), into: &firstArcs, scratch: &morphScratch)
        for arc1 in firstArcs {
            // `TR` çapraz eşleşir: c_{j−1} ← t_i, c_j ← t_{i−1}.
            // Aday budaması buna göre uygulanır; kuadratik fanout'u kesen şey bu.
            guard Int(arc1.symbol) < symbolMask.count, symbolMask[Int(arc1.symbol)] else { continue }
            guard let k1 = d.layout.keyIndex(for: Character(d.lexicon.scalar(arc1.symbol))) else { continue }
            let mid = advance(e, arc1, touchIndex: nil)
            var midEntry = e
            midEntry.key = mid

            arcBuf.removeAll(keepingCapacity: true)
            d.lexicon.arcs(from: position(mid), into: &arcBuf, scratch: &morphScratch)
            for arc2 in arcBuf {
                guard Int(arc2.symbol) < prevSymbolMask.count,
                      prevSymbolMask[Int(arc2.symbol)] else { continue }
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
                transpositionStates += 1
            }
        }
    }

    /// `OM` kapanışı: dokunma tüketmeyen emisyonlar, aynı `touchIndex` içinde zincirlenir.
    ///
    /// Sonluluk **yapısaldır**: `FormTrie.init` her arkın hedefinin kaynaktan ileri
    /// olduğunu doğrular (çevrim imkânsız) ve derinlik `maxSurfaceLen` ile sınırlıdır (I1).
    /// (I2) ayrıca her emisyonun net maliyetini pozitif tutar.
    /// `isSeed`: tohum frontier'ı üzerinde çalışıyoruz, budama yapılmamalı.
    /// (Bu bayrak taşınmayınca kapanış içindeki budama tohumları geri kesiyordu —
    /// dıştaki `isSeed` tek başına yetmiyordu.)
    private mutating func closeOmissions(_ seeds: [Int32], isSeed: Bool = false,
                                         minKeep: Int = 0) -> [Int32] {
        var all = seeds
        var work = seeds
        var depth = 0
        // (I1) sınırı emisyon sayısı üzerinden ve kaynağa özgü uygulanır;
        // ayrıca art arda omission sayısı arama sezgiseliyle sınırlı (§ScoreWeights).
        let maxDepth = isSeed ? d.lexicon.maxSurfaceLen(0) : d.weights.maxConsecutiveOmissions
        while !work.isEmpty && depth < maxDepth {
            var next: [Int32] = []
            for slot in work {
                let e = arena[Int(slot)]
                guard e.cost.isFinite,
                      Int(e.emitCount) < d.lexicon.maxSurfaceLen(e.key.automaton) else { continue }
                arcBuf.removeAll(keepingCapacity: true)
                    d.lexicon.arcs(from: position(e.key), into: &arcBuf, scratch: &morphScratch)
                    for arc in arcBuf {
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
                    omissionStates += 1
                }
            }
            if next.isEmpty { break }
            // Kapanışta ÜRETİLEN durumlar normal budanır…
            let pruned = dedupAndPrune(next, isSeed: isSeed)
            all.append(contentsOf: pruned)
            work = pruned
            depth += 1
        }
        // …ama tohumların kendisi korunur (`minKeep`).
        return dedupAndPrune(all, isSeed: isSeed, minKeep: minKeep)
    }

    // MARK: - Dedup + budama

    /// Dedup + budama.
    ///
    /// **Deterministik olmak ZORUNDA.** Önceki sürüm `Array(dictionary.values)`
    /// kullanıyordu; Swift'te `Dictionary` iterasyon sırası süreç başına rastgele
    /// (hash tohumu randomize) ve `sort` kararlı değil. Sonuç: eşit maliyetli
    /// durumlarda beam'de hangisinin kalacağı çalıştırmadan çalıştırmaya
    /// değişiyordu. Klavyede bu, aynı yazımın farklı öneri vermesi demek.
    /// Ölçüldü: morfoloji açıkken top-1 aynı komutta %40 ile %96 arasında
    /// gidip geliyordu.
    ///
    /// Çözüm: giriş dizisinin sırası korunur ve eşitlikte o sıra tiebreak olur.
    /// `minKeep`: budama yapılsa bile en az bu kadar girdi korunur.
    /// Tohumlar için kullanılır — hiçbir kaynak kanıt görmeden elenmemeli.
    private func dedupAndPrune(_ slots: [Int32], isSeed: Bool = false,
                               minKeep: Int = 0) -> [Int32] {
        var kept: [Int32]
        if d.disableDedup {
            kept = slots.filter { arena[Int($0)].cost.isFinite }
        } else {
            var slotIndexByKey: [DecoderStateKey: Int] = [:]
            slotIndexByKey.reserveCapacity(slots.count)
            var order: [Int32] = []
            order.reserveCapacity(slots.count)
            for s in slots {
                let e = arena[Int(s)]
                guard e.cost.isFinite else { continue }
                if let i = slotIndexByKey[e.key] {
                    if e.cost < arena[Int(order[i])].cost { order[i] = s }
                } else {
                    slotIndexByKey[e.key] = order.count
                    order.append(s)
                }
            }
            kept = order
        }

        // TOHUM FRONTIER'I BUDANMAZ.
        //
        // Başlangıç durumları henüz hiçbir kanıt görmemiştir; onları beam
        // genişliğine göre kesmek, kullanıcı tek harfe basmadan kökleri
        // yalnız önsel maliyetlerine bakarak elemek demektir. Ölçüldü:
        // 158 kök + beam 64 ile doğru kök %60 olasılıkla daha başlangıçta
        // eleniyordu.
        //
        // Gerçek çözüm kökleri ortak önekli bir trie'de paylaştırmaktır
        // (Faz 4); o zaman tohum sayısı O(kök) olmaktan çıkar. O gelene kadar
        // doğruluk için budamıyoruz.
        guard !isSeed else { return kept }

        let limit = max(d.beamWidth, minKeep)
        if !d.disablePruning && kept.count > limit {
            // Kararlı sıralama: eşit maliyette giriş sırası korunur.
            kept = kept.enumerated()
                .sorted { a, b in
                    let ca = arena[Int(a.element)].cost
                    let cb = arena[Int(b.element)].cost
                    if ca != cb { return ca < cb }
                    return a.offset < b.offset
                }
                .prefix(limit)
                .map(\.element)
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
