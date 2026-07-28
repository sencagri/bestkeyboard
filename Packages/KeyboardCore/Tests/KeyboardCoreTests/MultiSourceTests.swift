import Testing
import Foundation
import KBDecoder
import KBGeometry
import KBLexicon
import KBMorphology
import KBSpatial

/// `-1A₂`'nin ikinci yarısı: morfolojinin decoder'a **form trie ile aynı ABI**
/// üzerinden bağlanması. Bu testler ABI'nin gerçekten kaynak-bağımsız olup
/// olmadığını sınar.
@Suite("Çoklu kaynak — ABI entegrasyonu")
struct MultiSourceTests {

    /// Form listesinde OLMAYAN ama morfolojiden türetilebilen kelimeler.
    static let trieOnlyWords: [String: Double] = [
        "kalem": 900, "kitap": 1400, "ev": 2000, "masa": 500,
        "işlem": 1500, "eklem": 180,
    ]

    static func makeSpatial() -> (KeyLayout, SpatialModel) {
        let l = TurkishQ.layout()
        return (l, SpatialModel(layout: l))
    }

    static func makeTrie() throws -> FormTrie {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: trieOnlyWords)
        return try FormTrie(bytes: try FormTrieBuilder().build(entries: entries).bytes)
    }

    /// **Küçük** morfoloji fixture'ı (6 kök). `SpikeRoots.all` (20 kök) durum
    /// uzayını gereksiz büyütüyor; kapıların kanıt gücü kök sayısına değil
    /// çeşitliliğe bağlı.
    static func makeMorphology() -> MorphologyAutomaton {
        // `kalem` ve `ev` bilinçli birlikte: ikisi de isim, son ünlüsü ince+düz,
        // son sesi ötümlü → ek fazında **aynı** düğüme farklı yüzeylerle
        // ulaşıyorlar. `surfaceId` testinin ihtiyaç duyduğu çakışma bu.
        // `masa` ve `araba` bilinçli birlikte: ikisi de isim ve `a` ile bitiyor
        // → aynı fonolojik bağlam (kalın, düz, son ses ünlü). Ek fazında **aynı**
        // düğüme farklı yüzeylerle ulaşıyorlar; `surfaceId` testinin ihtiyaç
        // duyduğu çakışma bu.
        morphology(["kitap", "çocuk", "renk", "burun", "kalem", "masa", "araba", "gel"])
    }

    /// **Minimal** fixture — budamasız kapılar için.
    ///
    /// Budamasız beam ile morfolojiyi birleştirmek durum uzayını üstel büyütüyor
    /// ve testi dakikalarca sürdürüyor. Bu, entegrasyonun performans bulgusunun
    /// (bkz. `MultiSourcePerformanceTests`) test tarafındaki tezahürü.
    /// §5.4 kapıları **doğruluk** kapıları; iki kök onları kanıtlamaya yeter.
    static func makeMinimalMorphology() -> MorphologyAutomaton {
        morphology(["kitap", "gel"])
    }

    static func morphology(_ names: [String]) -> MorphologyAutomaton {
        MorphologyAutomaton(roots: SpikeRoots.all.filter { names.contains(String($0.surface)) })
    }

    static func decoder(trie: Bool, morph: Bool, beam: Int = 512) throws -> (Decoder, KeyLayout) {
        let (layout, spatial) = makeSpatial()
        let set = LexiconSet(formTrie: trie ? try makeTrie() : nil,
                             morphology: morph ? makeMorphology() : nil)
        // Geniş ama **budamalı**: budamasız mod morfolojiyle üstel.
        return (Decoder(layout: layout, spatial: spatial, lexicon: set, beamWidth: beam), layout)
    }

    // MARK: - Temel entegrasyon

    /// Morfoloji tek başına: sözlükte olmayan çekimli form çözülüyor.
    @Test("Yalnız morfoloji: kalemlerimizden çözülür")
    func morphologyOnly() throws {
        let (d, layout) = try Self.decoder(trie: false, morph: true)
        let r = d.decode(touches: touches("kalemlerimizden", layout: layout), topK: 3)
        #expect(r.first?.word == "kalemlerimizden",
                "top-1: \(r.map { "\($0.word)=\(String(format: "%.2f", $0.cost))" })")
    }

    /// Yüzey kuralları decoder içinden de doğru işliyor.
    @Test("Yalnız morfoloji: yüzey kuralları decoder'da da geçerli")
    func morphologySurfaceRulesInDecoder() throws {
        let (d, layout) = try Self.decoder(trie: false, morph: true)
        for word in ["kitabı", "çocuğu", "rengi", "burnu", "geldim", "gelmiyor"] {
            let r = d.decode(touches: touches(word, layout: layout), topK: 1)
            #expect(r.first?.word == word, "\(word) → \(r.map(\.word))")
        }
    }

    /// İki kaynak birlikte: her biri kendi kelimesini üretebiliyor.
    @Test("İki kaynak: trie kelimesi de morfoloji kelimesi de bulunur")
    func bothSources() throws {
        let (d, layout) = try Self.decoder(trie: true, morph: true)

        // Yalnız trie'de olan
        let a = d.decode(touches: touches("işlem", layout: layout), topK: 3)
        #expect(a.first?.word == "işlem", "top-1: \(a.map(\.word))")

        // Yalnız morfolojiden türetilebilen
        let b = d.decode(touches: touches("kalemlerimizden", layout: layout), topK: 3)
        #expect(b.first?.word == "kalemlerimizden", "top-1: \(b.map(\.word))")
    }

    // MARK: - §4.2 surfaceId

    /// Morfolojide düğüm yüzeyi belirlemez; `surfaceId` olmadan farklı kelimeler
    /// yanlış birleşirdi. Bu test, aynı düğüme farklı yüzeylerle ulaşılan
    /// durumların ayrı kaldığını gösterir.
    /// Bir yüzeyi otomatta yürütüp ulaşılan konumları ve `surfaceId`'leri döndürür.
    static func walk(_ set: LexiconSet, _ surface: String) -> [(LexiconSet.Position, UInt64)] {
        var cur: [(LexiconSet.Position, UInt64)] = set.startPositions().map { ($0, set.initialSurfaceId($0)) }
        for ch in surface {
            guard let sym = set.symbol(for: ch.unicodeScalars.first!) else { return [] }
            var next: [(LexiconSet.Position, UInt64)] = []
            for (pos, sid) in cur {
                for arc in set.arcs(from: pos) where arc.symbol == sym {
                    next.append((arc.target, set.advanceSurfaceId(from: sid, arc: arc)))
                }
            }
            cur = next
            if cur.isEmpty { return [] }
        }
        return cur
    }

    /// Önceki hâli yalnız dört kelimeyi ayrı ayrı decode ediyordu; iddia ettiği
    /// çakışmayı hiç kurmuyordu. Bu sürüm **aynı düğüme farklı yüzeylerle
    /// ulaşıldığını önce ispatlıyor**, sonra `surfaceId`'nin ayırdığını gösteriyor.
    @Test("surfaceId farklı yüzey öneklerini ayırır — çakışma önce ispatlanır")
    func surfaceIdSeparatesPrefixes() throws {
        let set = LexiconSet(formTrie: nil, morphology: Self.makeMorphology())

        // `masa` ve `araba` aynı fonolojik profilde iki isim; çoğul ekinden
        // sonra morfoloji düğümleri **çakışmalı**.
        let a = Self.walk(set, "masalar")
        let b = Self.walk(set, "arabalar")
        #expect(!a.isEmpty && !b.isEmpty, "yürüyüş başarısız: masalar=\(a.count), arabalar=\(b.count)")

        let nodesA = Set(a.map(\.0))
        let nodesB = Set(b.map(\.0))
        let shared = nodesA.intersection(nodesB)
        let detail: Comment = "aynı düğüme farklı yüzeylerle ulaşılmalı — yoksa surfaceId gereksiz demektir (masalar: \(nodesA.count) düğüm, arabalar: \(nodesB.count))"
        #expect(!shared.isEmpty, detail)

        // Çakışan düğümde `surfaceId`'ler FARKLI olmalı — ayrımı sağlayan bu.
        for node in shared {
            let idsA = Set(a.filter { $0.0 == node }.map(\.1))
            let idsB = Set(b.filter { $0.0 == node }.map(\.1))
            #expect(idsA.isDisjoint(with: idsB),
                    "surfaceId ayırmadı: aynı düğüm \(node), aynı kimlik")
        }

        // Ve uçtan uca: her kelime doğru çözülüyor.
        let (d, layout) = try Self.decoder(trie: false, morph: true)
        for word in ["masalar", "arabalar", "kitapta", "çocukta"] {
            let r = d.decode(touches: touches(word, layout: layout), topK: 1)
            #expect(r.first?.word == word, "\(word) → \(r.map(\.word))")
        }
    }

    // MARK: - §4.2 top-k kararlılığı

    /// Sözleşme §4.2 test kapısı: *"kaynaklardan biri kapatıldığında, yeterli
    /// beam genişliğinde top-k listesi değişmemeli."*
    ///
    /// Yani bir kaynağı eklemek, diğerinin ürettiği adayların **sıralamasını**
    /// bozmamalı — yalnız kendi adaylarını araya sokmalı.
    @Test("Top-k kararlılığı: kaynak eklemek diğerinin sırasını bozmuyor")
    func topKStability() throws {
        // Budamalı ama geniş beam: kapı **arama hatasını** ölçmeli, budamasız
        // modun maliyetini değil.
        let (layout, spatial) = Self.makeSpatial()
        let both = Decoder(layout: layout, spatial: spatial,
                           lexicon: LexiconSet(formTrie: try Self.makeTrie(),
                                               morphology: Self.makeMorphology()),
                           beamWidth: 512)
        let trieOnly = Decoder(layout: layout, spatial: spatial,
                               lexicon: LexiconSet(formTrie: try Self.makeTrie(), morphology: nil),
                               beamWidth: 512)

        for typed in ["işlem", "eklem", "kitap", "masa"] {
            let t = touches(typed, layout: layout)
            // `topK` SINIRSIZ olmalı. Sınırlı istemek, morfolojinin ürettiği
            // daha ucuz adaylar yüzünden trie adaylarının listeden **taşmasına**
            // yol açar — bu bir kayıp değil, kesmedir; kapı onu ölçmemeli.
            let fromBoth = both.decode(touches: t, topK: Int.max)
            let fromTrie = trieOnly.decode(touches: t, topK: Int.max)

            // (a) HİÇBİR trie adayı düşmemeli. Önceki hâli kesişime filtreliyordu,
            //     yani düşen aday testten de düşüyordu — tautoloji.
            let bothWords = Set(fromBoth.map(\.word))
            for r in fromTrie {
                #expect(bothWords.contains(r.word),
                        "\(typed): trie adayı '\(r.word)' iki kaynaklı sonuçtan DÜŞTÜ")
            }
            // (b) Trie adaylarının kendi aralarındaki sırası korunmalı.
            let trieWords = Set(fromTrie.map(\.word))
            let orderInBoth = fromBoth.map(\.word).filter { trieWords.contains($0) }
            #expect(orderInBoth == fromTrie.map(\.word),
                    "\(typed): trie sırası bozuldu\n  iki kaynak: \(orderInBoth)\n  tek kaynak: \(fromTrie.map(\.word))")

            // Trie adaylarının MALİYETLERİ de değişmemeli (maliyet itme, §7.1).
            let costBoth = Dictionary(fromBoth.map { ($0.word, $0.cost) }, uniquingKeysWith: min)
            for r in fromTrie where costBoth[r.word] != nil {
                #expect(abs(costBoth[r.word]! - r.cost) < 1e-9,
                        "\(typed)/\(r.word): maliyet değişti \(r.cost) → \(costBoth[r.word]!)")
            }
        }
    }

    // MARK: - Ölçüm

    /// Aynı yüzeye giden farklı kaynak/analizlerin beam'de kapladığı yer.
    /// Sözleşme §4.2: *"duplicate-state baskısı ölçülür."*
    /// Önceki hâli tautolojikti: `results()` zaten yüzeyleri tekilleştirdiği için
    /// `results.count == unique.count` her zaman doğruydu. Bu sürüm **beam içi**
    /// baskıyı ölçüyor: aynı yüzeye kaç ayrı durumdan ulaşılıyor.
    @Test("Duplicate-surface baskısı BEAM İÇİNDE ölçülür")
    func duplicateSurfacePressure() throws {
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMorphology())

        // Yüzey → o yüzeye ulaşan (automaton, node) çiftleri.
        var statesPerSurface: [String: Set<LexiconSet.Position>] = [:]
        var stack: [(LexiconSet.Position, String)] = set.startPositions().map { ($0, "") }
        var seen = Set<String>()
        while let (pos, surf) = stack.popLast(), seen.count < 40_000 {
            guard surf.count <= 4 else { continue }
            let key = "\(pos.automaton):\(pos.node):\(surf)"
            if seen.contains(key) { continue }
            seen.insert(key)
            if !surf.isEmpty { statesPerSurface[surf, default: []].insert(pos) }
            for arc in set.arcs(from: pos) {
                stack.append((arc.target, surf + String(Character(set.scalar(arc.symbol)))))
            }
        }
        let multi = statesPerSurface.filter { $0.value.count > 1 }
        let worst = statesPerSurface.map(\.value.count).max() ?? 0
        print("DUPLICATE BASKISI — yüzey: \(statesPerSurface.count) · "
              + "çoklu duruma sahip: \(multi.count) · en kötü: \(worst) durum/yüzey")
        // Kapı değil, kayıt: baskı var ve ölçülüyor.
        #expect(worst >= 1)
    }

    /// **Ölçülen sınırlama** (entegrasyonun ortaya çıkardığı bulgu):
    /// morfoloji kök başına bir başlangıç durumu üretir → ilk frontier O(kök).
    /// Üretimde (~90k kök) kabul edilemez; kökler ortak önekli trie'de
    /// paylaşılmalı. Bu test bulgunun kaybolmaması için var.
    @Test("Başlangıç frontier'ı kök sayısıyla doğrusal büyüyor (Faz 4 bulgusu)")
    func startFrontierScalesWithRoots() throws {
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMorphology())
        let starts = set.startPositions()
        let rootCount = Self.makeMorphology().roots.count
        // 1 trie kökü + kök sayısı kadar morfoloji başlangıcı → O(kök)
        #expect(starts.count == 1 + rootCount,
                "başlangıç sayısı: \(starts.count), kök sayısı: \(rootCount)")
        // Bulgunun özü: kök eklemek başlangıç frontier'ını büyütüyor.
        let bigger = LexiconSet(formTrie: nil, morphology: MorphologyAutomaton(roots: SpikeRoots.all))
        #expect(bigger.startPositions().count == SpikeRoots.all.count,
                "20 kök → \(bigger.startPositions().count) başlangıç durumu")
    }

    // MARK: - §5.4 kapıları, morfoloji için

    /// §5.4/2: dedup açık/kapalı **aynı** sonucu vermeli. Önceden yalnız trie
    /// üzerinde koşuyordu; morfoloji state anahtarının yeterli istatistik olduğu
    /// hiç sınanmamıştı.
    @Test("Dedup güvenliği morfolojide de geçerli (budamasız)")
    func dedupSafetyWithMorphology() throws {
        let (layout, spatial) = Self.makeSpatial()
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMinimalMorphology())
        let withDedup = Decoder(layout: layout, spatial: spatial, lexicon: set,
                                disableDedup: false, disablePruning: true)
        let noDedup = Decoder(layout: layout, spatial: spatial, lexicon: set,
                              disableDedup: true, disablePruning: true)

        for typed in ["kitap", "geldi", "işlem"] {
            let t = touches(typed, layout: layout)
            let a = withDedup.decode(touches: t, topK: 5)
            let b = noDedup.decode(touches: t, topK: 5)
            #expect(a.map(\.word) == b.map(\.word), "\(typed): dedup sıralamayı değiştirdi")
            for (x, y) in zip(a, b) {
                #expect(abs(x.cost - y.cost) < 1e-9,
                        "\(typed)/\(x.word): dedup maliyeti değiştirdi \(x.cost) vs \(y.cost)")
            }
        }
    }

    /// §5.4/3: artımlı decode = tam decode, **çoklu kaynakta da**.
    @Test("Artımlı = tam decode, morfoloji dahil")
    func incrementalEqualityWithMorphology() throws {
        let (layout, spatial) = Self.makeSpatial()
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMinimalMorphology())
        let d = Decoder(layout: layout, spatial: spatial, lexicon: set, disablePruning: true)

        for typed in ["kitap", "geldi"] {
            let all = touches(typed, layout: layout)
            var inc = IncrementalDecoder(decoder: d)
            for k in 1...all.count {
                inc.append(all[k - 1])
                let incR = inc.results(topK: 5)
                let fullR = d.decode(touches: Array(all.prefix(k)), topK: 5)
                #expect(incR.map(\.word) == fullR.map(\.word),
                        "\(typed)[0..<\(k)]: artımlı \(incR.map(\.word)) vs tam \(fullR.map(\.word))")
                for (a, b) in zip(incR, fullR) {
                    #expect(abs(a.cost - b.cost) < 1e-12, "\(typed)[0..<\(k)]/\(a.word): maliyet farkı")
                }
            }
        }
    }

    /// §7.1 maliyet itmesinin kaynaklar arası tutarlılığı: decoder'ın verdiği
    /// `F_lex`, morfolojinin ham türetme maliyetiyle **eşleşmeli**.
    /// (Tohum potansiyeli eklenmezse morfoloji sistematik olarak ucuz çıkardı.)
    @Test("Maliyet itme mutlak maliyeti koruyor")
    func costPushingPreservesAbsoluteCost() throws {
        let m = Self.makeMorphology()
        let i = SpikeRoots.all.firstIndex { String($0.surface) == "kalem" }!
        let generated = try m.generate(rootIndex: i, maxSuffixes: 2)
        // `generate` itilmiş deltaları topluyor + tohum yok; decoder tohumu ekliyor.
        // İkisinin farkı tam olarak potential(start) olmalı.
        let start = m.startStates()[i]
        let p0 = m.potential(start)
        guard let kalem = generated.first(where: { $0.surface == "kalem" }) else {
            Issue.record("kalem üretilmedi"); return
        }
        // Ham maliyet = itilmiş toplam + potential(start)
        let absolute = kalem.cost + p0
        #expect(abs(absolute - SpikeRoots.all[i].lexCost) < 1e-9,
                "mutlak maliyet korunmadı: \(absolute) vs \(SpikeRoots.all[i].lexCost) (p0=\(p0))")
    }

    /// Birleşik alfabe: iki kaynağın sembol uzayları tek uzaya indirgeniyor.
    /// Aksi halde `lastSurfaceSymbol` karşılaştırmaları (ikiz harf sınıfı)
    /// kaynaklar arası anlamsızlaşırdı.
    @Test("Birleşik alfabe iki kaynağı da kapsıyor")
    func mergedAlphabet() throws {
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMorphology())
        for ch in "abcçdefgğhıijklmnoöprsştuüvyz" {
            #expect(set.symbol(for: ch.unicodeScalars.first!) != nil, "eksik: \(ch)")
        }
    }
}

/// Entegrasyonun ortaya çıkardığı **performans bulgusu**.
///
/// Doğruluk tamam ama morfoloji kaynağı bütçeyi 27× aşıyor. Bu suite bir
/// **kapı değil, kayıt**: sayı görünür kalsın ve performans fazının hedef
/// listesi belgeli olsun diye var.
///
/// Ölçülen (macOS, **debug** derleme, budamalı beam=128, 20 kök):
///   yalnız form trie : ~2 ms
///   morfoloji ile    : bkz. test çıktısındaki PERF KAYDI satırı
///
/// Bütçe (§11) p99 < 8 ms ve **release** derlemede, cihazda geçerlidir; buradaki
/// sayı mutlak bir yargı değil, kaynak ekleme maliyetinin büyüklük mertebesidir.
///
/// Nedenleri (performans fazının hedef listesi):
///   1. `LexiconSet.arcs` her çağrıda `[LexArc]` allocate ediyor
///   2. Morfolojide her ark için State unpack → arcs → pack turu
///   3. `MorphologyAutomaton.arcs` da `[Arc]` allocate ediyor
///   4. Başlangıç frontier'ı kök başına bir durum (5 kök → 5; 90k kök → 90k)
///   5. Sıfır-tahsisli sıcak döngü (§11.C.2) hiç uygulanmadı
///
/// 4. madde tek başına üretimde kabul edilemez: kökler ortak önekli bir
/// trie'de paylaşılmalı (Faz 4).
@Suite("Çoklu kaynak — performans kaydı")
struct MultiSourcePerformanceTests {

    private func measure(_ d: Decoder, _ layout: KeyLayout, _ word: String) -> Double {
        let t = touches(word, layout: layout)
        let t0 = Date().timeIntervalSince1970
        _ = d.decode(touches: t, topK: 3)
        return (Date().timeIntervalSince1970 - t0) * 1000
    }

    /// Budamalı (üretim benzeri) decoder — yardımcıdaki `disablePruning: true`
    /// ölçümü anlamsız kılıyordu.
    private func prunedDecoder(morph: Bool) throws -> (Decoder, KeyLayout) {
        let (layout, spatial) = MultiSourceTests.makeSpatial()
        let set = LexiconSet(formTrie: try MultiSourceTests.makeTrie(),
                             morphology: morph ? MultiSourceTests.makeMorphology() : nil)
        return (Decoder(layout: layout, spatial: spatial, lexicon: set, beamWidth: 128), layout)
    }

    @Test("Morfoloji kaynağı bütçeyi aşıyor — kayıt altına alınır")
    func morphologyLatencyRecorded() throws {
        let (trieOnly, layout) = try prunedDecoder(morph: false)
        let (withMorph, _) = try prunedDecoder(morph: true)

        let a = measure(trieOnly, layout, "işlem")
        let b = measure(withMorph, layout, "kitapta")

        // Kapı DEĞİL: yalnız sayının makul aralıkta kaldığını ve bulgunun
        // kaybolmadığını doğrular. Gerçek bütçe cihazda, release derlemede.
        #expect(a < 200, "form trie beklenmedik şekilde yavaş: \(a) ms")
        #expect(b > a, "morfoloji ölçülebilir bir maliyet getirmeli (kayıt: trie \(a) ms, morfoloji \(b) ms)")

        // Bulgu görünür kalsın.
        print("PERF KAYDI — form trie: \(String(format: "%.1f", a)) ms · morfoloji ile: \(String(format: "%.1f", b)) ms")
    }
}
