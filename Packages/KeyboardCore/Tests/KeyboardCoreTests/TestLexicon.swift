import Foundation
import KBDecoder
import KBGeometry
import KBLexicon
import KBRuntime
import KBSpatial

/// `-1A₁` için küçük test leksikonu. Kalite hedefi yok; amaç decoder'ı ve
/// oracle'ı sınamak. Frekanslar kabaca gerçekçi (yüksek = daha sık).
enum TestLexicon {
    static let counts: [String: Double] = [
        // Altın vaka ve rakipleri
        "kalem": 900, "işlem": 1500, "kalan": 700, "kelam": 40,
        "kalemler": 200, "kalemi": 300, "kalemin": 250,
        // "lslem" çevresinde tuzak kelimeler
        "islem": 5, "ıslak": 120, "eklem": 180, "kalıp": 260,
        // Deasciification vakası
        "güzel": 2000, "guzel": 1, "gazel": 30, "gizel": 1,
        "çok": 5000, "cok": 1, "şey": 4000,
        // İkiz harf (F_om_gem)
        "elli": 400, "eli": 600, "anne": 1200, "ane": 2,
        // Genel dolgu
        "ve": 20000, "bir": 15000, "bu": 12000, "için": 9000,
        "gibi": 5000, "daha": 4800, "kadar": 4000, "sonra": 3500,
        "olarak": 3000, "her": 2900, "en": 2800, "ile": 2700,
        "var": 2600, "yok": 2500, "ben": 2400, "sen": 2300,
        "gelen": 900, "giden": 800, "yapan": 700, "olan": 2000,
        "masa": 500, "kapı": 600, "araba": 700, "kitap": 1400,
        "kitabı": 500, "burun": 300, "burnu": 200,
        "deniz": 800, "orman": 400, "şehir": 900, "insan": 1600,
        "zaman": 1700, "yıl": 1800, "gün": 1900, "gece": 1000,
        "sabah": 900, "akşam": 850, "hafta": 700, "ay": 1100,
    ]

    /// Sayımlardan form trie'si ve girdileri.
    static func trie(_ counts: [String: Double] = counts) throws
        -> (FormTrie, [(word: String, lexCost: Double)]) {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let t = try FormTrie(bytes: bytes)
        let lex = entries.map { (word: $0.word, lexCost: $0.lexCost) }
        return (t, lex)
    }

    // MARK: - Ortak kurulum
    //
    // Sayım → trie → leksikon → decoder/koordinatör zinciri test dosyalarında
    // ayrı ayrı yazılıyordu. Biri bir adımı değiştirince (beam, kanal kapısı)
    // testler sessizce farklı motorları sınamaya başlardı.

    static func formTrie(_ counts: [String: Double] = counts) throws -> FormTrie {
        try trie(counts).0
    }

    /// Yalnız form trie'sinden oluşan leksikon.
    static func lexicon(_ counts: [String: Double] = counts) throws -> LexiconSet {
        LexiconSet(formTrie: try formTrie(counts), morphology: nil)
    }

    static func decoder(_ counts: [String: Double] = counts, layout: KeyLayout,
                        bigrams: BigramPack? = nil,
                        beamWidth: Int = 128) throws -> Decoder {
        var d = Decoder(layout: layout, spatial: SpatialModel(layout: layout),
                        lexicon: try lexicon(counts), beamWidth: beamWidth)
        d.bigrams = bigrams
        return d
    }

    /// Koordinatör motoru: karakter modeli **aynı kelime kümesinden**, OOV
    /// kapısı açık (düzeltme kararı ölçülebilsin diye).
    static func engine(_ counts: [String: Double] = counts, layout: KeyLayout,
                       bigrams: BigramPack? = nil) throws -> InputCoordinator.Engine {
        let lex = try lexicon(counts)
        var channel = LiteralChannel(vocabulary: lex,
                                     charModel: try CharNGramBuilder.build(
                                        words: Array(counts.keys)))
        channel.autoCorrectsOutOfVocabulary = true
        channel.bigrams = bigrams
        var d = Decoder(layout: layout, spatial: SpatialModel(layout: layout),
                        lexicon: lex, beamWidth: 128)
        d.bigrams = bigrams
        return .init(decoder: d, literalChannel: channel)
    }

    static func coordinator(_ counts: [String: Double] = counts, layout: KeyLayout,
                            bigrams: BigramPack? = nil) throws -> InputCoordinator {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try engine(counts, layout: layout, bigrams: bigrams))
        return c
    }
}
