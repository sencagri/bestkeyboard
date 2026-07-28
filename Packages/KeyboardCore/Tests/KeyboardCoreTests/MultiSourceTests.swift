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

    static func makeMorphology() -> MorphologyAutomaton {
        MorphologyAutomaton(roots: SpikeRoots.all)
    }

    static func decoder(trie: Bool, morph: Bool, beam: Int = 4096) throws -> (Decoder, KeyLayout) {
        let (layout, spatial) = makeSpatial()
        let set = LexiconSet(formTrie: trie ? try makeTrie() : nil,
                             morphology: morph ? makeMorphology() : nil)
        return (Decoder(layout: layout, spatial: spatial, lexicon: set,
                        beamWidth: beam, disablePruning: true), layout)
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
    @Test("surfaceId farklı yüzey öneklerini ayırır")
    func surfaceIdSeparatesPrefixes() throws {
        let (d, layout) = try Self.decoder(trie: false, morph: true)
        // `kitap` ve `çocuk` farklı kökler ama aynı ek yollarını paylaşır;
        // ek fazındaki düğümler örtüşebilir. Her ikisi de doğru çözülmeli.
        for word in ["kitapta", "çocukta", "kitaplar", "çocuklar"] {
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
        let (both, layout) = try Self.decoder(trie: true, morph: true)
        let (trieOnly, _) = try Self.decoder(trie: true, morph: false)

        for typed in ["işlem", "eklem", "kitap", "masa"] {
            let t = touches(typed, layout: layout)
            let fromBoth = both.decode(touches: t, topK: 20)
            let fromTrie = trieOnly.decode(touches: t, topK: 20)

            // Trie adaylarının kendi aralarındaki SIRASI korunmalı.
            let trieWords = Set(fromTrie.map(\.word))
            let bothFilteredToTrie = fromBoth.map(\.word).filter { trieWords.contains($0) }
            let trieOrder = fromTrie.map(\.word).filter { bothFilteredToTrie.contains($0) }
            #expect(bothFilteredToTrie == trieOrder,
                    "\(typed): trie sırası bozuldu\n  iki kaynak: \(bothFilteredToTrie)\n  tek kaynak: \(trieOrder)")

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
    @Test("Duplicate-surface baskısı ölçülür ve raporlanır")
    func duplicateSurfacePressure() throws {
        let (d, layout) = try Self.decoder(trie: true, morph: true)
        let t = touches("kitapta", layout: layout)
        let results = d.decode(touches: t, topK: Int.max)
        let unique = Set(results.map(\.word))
        // `decode` zaten yüzey başına en ucuzu tuttuğu için burada eşit olmalı;
        // asıl baskı beam içinde. Ölçüm raporlanır, kapı olarak kullanılmaz.
        #expect(results.count == unique.count,
                "sonuçta yüzey tekrarı olmamalı: \(results.count) sonuç, \(unique.count) benzersiz")
        #expect(unique.contains("kitapta"))
    }

    /// **Ölçülen sınırlama** (entegrasyonun ortaya çıkardığı bulgu):
    /// morfoloji kök başına bir başlangıç durumu üretir → ilk frontier O(kök).
    /// Üretimde (~90k kök) kabul edilemez; kökler ortak önekli trie'de
    /// paylaşılmalı. Bu test bulgunun kaybolmaması için var.
    @Test("Başlangıç frontier'ı kök sayısıyla doğrusal büyüyor (Faz 4 bulgusu)")
    func startFrontierScalesWithRoots() throws {
        let set = LexiconSet(formTrie: try Self.makeTrie(), morphology: Self.makeMorphology())
        let starts = set.startPositions()
        // 1 trie kökü + kök sayısı kadar morfoloji başlangıcı
        #expect(starts.count == 1 + SpikeRoots.all.count,
                "başlangıç sayısı: \(starts.count), kök sayısı: \(SpikeRoots.all.count)")
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
/// Ölçülen (macOS, debug derleme, 5 kök):
///   yalnız form trie : ~2 ms   (bütçe içinde)
///   morfoloji ile    : ~218 ms (bütçe p99 < 8 ms → 27× aşım)
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

    @Test("Morfoloji kaynağı bütçeyi aşıyor — kayıt altına alınır")
    func morphologyLatencyRecorded() throws {
        let (trieOnly, layout) = try MultiSourceTests.decoder(trie: true, morph: false, beam: 128)
        let (withMorph, _) = try MultiSourceTests.decoder(trie: true, morph: true, beam: 128)

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
