import Testing
import Foundation
import KBGeometry
import KBSpatial
import KBAssembly
@testable import KBLexicon
@testable import KBDecoder

/// `atWordStart` `node`'dan türetilebilir mi — §9'un açık sorusu.
///
/// ## Soru ne
///
/// `DecoderStateKey` bir bit olarak `atWordStart` taşıyor ve tek tüketicisi
/// `omissionCost`: kelime başı omission `w_om_init`, diğerleri `w_om`/`w_om_gem`
/// alıyor (§5.1). Bit anahtarda olduğu için dedup'a da giriyor.
///
/// Alan **türetilebilirse** anahtardan düşebilir. Türetim adayı şu: bit yalnız
/// tohum durumlarında `true`, ve her `advance` onu `false` yapıyor. Yani iddia:
///
/// ```
/// atWordStart  ⟺  (automaton, node) ∈ startPositions()
/// ```
///
/// ## Neden bir iddia, neden test
///
/// İddia yapısal bir gerekçeye dayanıyor: form trie'de kök düğüme geri dönen
/// ark yok (trie aşağı iner), morfolojide de kök trie'si aynı sebeple geri
/// dönmüyor. Ama "yok" demek ile göstermek aynı şey değil ve karşı örnek tek
/// bir ark olurdu — üretim leksikonunda `advance`'in tohum konumuna varması.
///
/// Test bunu **gerçek pakette** sınıyor: her decode durumunun biti ile konum
/// yüklemi karşılaştırılıyor.
///
/// **İki yön eşit ağırlıkta değil.** "Bit `true` ⇒ konum tohum" *yapı gereği*
/// doğru: biti yalnız tohum kurucusu `true` yapıyor, `advance` daima `false`
/// yazıyor. O yön bir şey kanıtlamıyor, yalnız kurucunun değişmediğini
/// bekliyor. Asıl iddia ters yön — **"konum tohum ⇒ bit `true`"** — ve karşı
/// örneği tek bir ark olurdu: `advance`'in bir tohum konumuna varması. Test
/// yükü orada.
///
/// Üçüncü sayaç boşuna değil: iki ihlal sayacı da sıfırsa test, hiçbir durum
/// tohum konumuyla **eşleşmediği** için de geçebilirdi (konum paketlemesi
/// ayrışsa böyle olurdu). Eşleşen durum sayısı ayrıca sayılıyor.
///
/// ## Kanıt değil, karakterizasyon
///
/// Bu bir tümevarım kanıtı değil: üretim leksikonu ve bir kelime kümesi
/// üzerinde ölçüm. Morfoloji grafı büyürse (Faz 4) tekrar koşmalı — testin
/// varlık sebebi de bu.
@Suite("atWordStart türetilebilirliği (§9)")
struct AtWordStartDerivableTests {

    private static var packRoot: URL { RecordingTestSupport.packRoot }

    private static func layout() -> KeyLayout { RecordingTestSupport.layout }

    /// Yüklemin decode durumlarında **iki yönlü** tutup tutmadığı.
    private struct Verdict {
        var states = 0
        /// Konum yüklemine **uyan** durumlar — sayaçların canlı olduğunun kanıtı.
        var seedPositions = 0
        /// Bit `true` ama konum tohum değil — türetim yüklemi eksik kalırdı.
        var trueButNotSeed = 0
        /// Konum tohum ama bit `false` — türetim yüklemi fazla söylerdi.
        var seedButNotTrue = 0
    }

    private static func check(_ words: [String], decoder: Decoder,
                              layout: KeyLayout) -> Verdict {
        let seeds = Set(decoder.lexicon.startPositions())
        var v = Verdict()
        for word in words {
            var inc = IncrementalDecoder(decoder: decoder)
            for ch in word {
                guard let k = layout.keyIndex(for: ch) else { continue }
                inc.append(TouchSample(down: layout.keys[k].center, timestamp: 0))
            }
            // **Arena, frontier değil.** Frontier yalnız hayatta kalanları
            // taşıyor; budanmış bir durum da bir kez kurulmuş gerçek bir
            // durumdur ve yüklemi orada da sağlamalı. Karşı örnek en çok
            // budanan dallarda beklenir.
            for e in inc.arena {
                v.states += 1
                let isSeed = seeds.contains(.init(automaton: e.key.automaton,
                                                  node: e.key.node))
                if isSeed { v.seedPositions += 1 }
                if e.key.atWordStart && !isSeed { v.trueButNotSeed += 1 }
                if isSeed && !e.key.atWordStart { v.seedButNotTrue += 1 }
            }
        }
        return v
    }

    /// Üretim leksikonu: 70k form + 30k kök, morfoloji açık.
    ///
    /// Ölçülen (2026-08-01): 12 kelime, **291 133 durum**, iki yönde de sıfır
    /// ihlal. Yani hiçbir ark tohum konumuna geri dönmüyor ve `atWordStart`
    /// gerçekten `(automaton, node)`'dan türetilebilir.
    @Test("Üretim leksikonunda yüklem iki yönde de tutuyor")
    func predicateHoldsOnTheProductionLexicon() throws {
        let layout = Self.layout()
        let source = DirectoryPackSource(root: Self.packRoot)
        guard let loaded = try? PackLoader.load(layout: layout, source: source),
              loaded.decoder.lexicon.sources.contains(where: { $0.morphology != nil })
        else { return }

        let words = ["kalem", "kalemler", "kalemlerimizden", "kitap", "kitabı",
                     "geliyor", "gelmeyecek", "evlerimizde", "güzel", "yazdım",
                     "lslem", "burnu"]
        let v = Self.check(words, decoder: loaded.decoder, layout: layout)

        #expect(v.states > 0, "hiç durum kurulmadı — ölçüm anlamsız")
        #expect(v.seedPositions > 0, """
                hiçbir durum tohum konumuyla eşleşmedi — ihlal sayaçları \
                sıfırsa bu yüzden olabilir, ölçüm anlamsız
                """)
        #expect(v.trueButNotSeed == 0,
                "\(v.trueButNotSeed) durumda bit true ama konum tohum değil")
        #expect(v.seedButNotTrue == 0, """
                \(v.seedButNotTrue) durumda konum tohum ama bit false — bir ark \
                tohum konumuna geri dönüyor, türetim yüklemi çöker
                """)
    }

    /// Morfolojisiz kurulumda da tutuyor — form trie tarafı ayrıca sınanıyor.
    ///
    /// Ayrı test, çünkü iki kaynağın gerekçesi farklı: form trie'de kök düğüme
    /// dönen ark olmadığı trie'nin tanımından, morfolojide kök trie'sinin aynı
    /// özelliğinden geliyor. Biri bozulursa diğerinin testi bunu göstermez.
    @Test("Form trie tek başına da yüklemi sağlıyor")
    func predicateHoldsOnAFormTrieAlone() throws {
        let layout = Self.layout()
        let counts = ["kalem": 900.0, "işlem": 1500, "kalan": 700, "güzel": 800,
                      "kalemler": 200, "kitap": 1400, "elli": 400, "anne": 1200]
        let decoder = try TestLexicon.decoder(counts, layout: layout)

        // İkiz harfli kelimeler bilerek listede: `w_om_gem` dalı `atWordStart`
        // ile aynı fonksiyonda seçiliyor ve o dalı hiç uyandırmayan bir kelime
        // kümesi biti gerçekten sınamazdı.
        let v = Self.check(["kalem", "işlem", "lslem", "elli", "anne", "kalemler"],
                           decoder: decoder, layout: layout)
        #expect(v.states > 0)
        #expect(v.seedPositions > 0, "tohum konumu hiç eşleşmedi — ölçüm anlamsız")
        #expect(v.trueButNotSeed == 0)
        #expect(v.seedButNotTrue == 0)
    }
}
