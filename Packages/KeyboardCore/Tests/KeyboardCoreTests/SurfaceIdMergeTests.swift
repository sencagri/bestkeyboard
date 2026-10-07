import Testing
import Foundation
import KBGeometry
import KBSpatial
import KBAssembly
@testable import KBLexicon
@testable import KBDecoder

/// `surfaceId`'nin beam birleşmesine maliyeti — §9'un açık sorusu, ölçülüyor.
///
/// ## Soru ne
///
/// Dedup anahtarı (§4) `surfaceId` taşıyor: aynı otomat düğümüne **farklı
/// yüzeylerle** varan iki yol birleştirilmiyor. Form trie'de bu bedava —
/// düğüm öneki zaten tekil belirliyor, `surfaceId ≡ node`. Morfolojide
/// belirlemiyor: aynı düğüme farklı yüzeylerle ulaşılıyor ve `surfaceId`
/// emisyonların rolling hash'i.
///
/// Yani `surfaceId` **yalnız morfoloji tarafında** durum ayırıyor, ve ayırdığı
/// her durum bir beam yuvası tüketiyor. Sorulan bedel bu.
///
/// ## Neden kaldırmak seçenek değil
///
/// Bu ölçüm bir öneri değil, bir **fiyat etiketi**. `surfaceId`'yi anahtardan
/// çıkarmak farklı yüzeyleri tek duruma katlardı ve `reconstruct` hangi yüzeyi
/// yazacağını bilemezdi — §4.2'nin tam olarak yasakladığı şey. Ölçülen şey
/// doğruluğun bedeli, bir tasarruf fırsatı değil.
///
/// ## Nasıl ölçülüyor — ve ilk tasarımın neden çöptüğü
///
/// İlk ölçüm budamayı **kapatıyordu**: aranan şey dedup'ın yapısal etkisiydi ve
/// budama o etkiyi maskeler. Ölçüm koşmadı — üretim leksikonunda (70k form +
/// 30k kök) budamasız decode 10 dakikada bitmedi. Bu bir aksaklık değil
/// **bulgu**: `disablePruning` sözleşmenin eşdeğerlik kapısı (§5.4/2) için var
/// ve orada oyuncak leksikonlarla koşuyor; üretim ölçeğinde budamasız arama
/// diye bir rejim yok.
///
/// Dolayısıyla soru üretim rejiminde soruluyor: **beam'in fiilen tuttuğu
/// yuvaların kaçı yalnızca `surfaceId` ayırdığı için ayrı duruyor.** Bu zaten
/// sorulması gereken sayı — ödenen bedel, ödenebilecek bedel değil.
///
/// Karşı-olgu anahtarı **aynı** koşu üzerinde kuruluyor: hayatta kalan her
/// durumun anahtarından `surfaceId` sıfırlanıp tekil sayılıyor. İkinci bir
/// decode koşusu yapmak iki farklı aramayı karşılaştırmak olurdu.
///
/// Sayının alt sınır olduğu **kabul ediliyor**: budama dedup'tan sonra
/// çalıştığı için `surfaceId`'nin ayırdığı bazı durumlar beam'e girmeden
/// eleniyor olabilir. Ölçülemeyen bir üst sınır iddia etmektense ölçülebilen
/// alt sınırı yazmak doğru — ve alt sınır zaten "patlamıyor" sorusunu
/// yanıtlıyor.
@Suite("surfaceId birleşme bedeli (§9)")
struct SurfaceIdMergeTests {

    private static var packRoot: URL { RecordingTestSupport.packRoot }

    /// **Üretim layout'u.** `GoldenReplayTests` kendi yaklaşımını kuruyor
    /// çünkü orada kaydın kullandığı düzenle eşleşmek gerekiyor; burada öyle
    /// bir kısıt yok ve ölçüm gerçek geometriyle yapılmalı. Aday budaması
    /// (§3) tuş komşuluğuna bakıyor, yani yaklaşık bir düzen ölçülen durum
    /// sayısını da yaklaşık yapardı.
    private static func layout() -> KeyLayout { TurkishQ.layout() }

    /// Bir token'ın dedup sonrası durum sayıları.
    private struct Counts {
        /// Bugünkü anahtarla hayatta kalan durumlar.
        var withSurfaceId = 0
        /// `surfaceId` anahtardan çıkarılsaydı kalacak durumlar.
        var withoutSurfaceId = 0
        /// Yalnız morfoloji otomatına ait olanlar — bedelin gerçek yeri.
        var morphologyWithSurfaceId = 0
        var morphologyWithoutSurfaceId = 0
    }

    /// Kelimeyi tuş merkezlerine basarak çözer ve frontier'daki durumları sayar.
    ///
    /// Budama **açık** (üretim rejimi): sayılan küme beam'in fiilen tuttuğu
    /// yuvalar.
    private static func measure(_ word: String, decoder: Decoder,
                                layout: KeyLayout) -> Counts {
        var inc = IncrementalDecoder(decoder: decoder)
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            inc.append(TouchSample(down: layout.keys[k].center, timestamp: 0))
        }

        var c = Counts()
        var all: Set<DecoderStateKey> = []
        var stripped: Set<DecoderStateKey> = []
        var allMorph: Set<DecoderStateKey> = []
        var strippedMorph: Set<DecoderStateKey> = []

        for slots in inc.frontier {
            for s in slots {
                let key = inc.arena[Int(s)].key
                var bare = key
                bare.surfaceId = 0
                all.insert(key)
                stripped.insert(bare)
                // Form trie kaynağında `surfaceId ≡ node`, yani orada anahtarı
                // sıfırlamak hiçbir durumu birleştirmez. Ayrı sayılmasının
                // sebebi bu: karışık toplam, bedeli morfolojinin olmadığı bir
                // kuruluma da atfediyormuş gibi okunurdu.
                if decoder.lexicon.sources[Int(key.automaton)].morphology != nil {
                    allMorph.insert(key)
                    strippedMorph.insert(bare)
                }
            }
        }
        c.withSurfaceId = all.count
        c.withoutSurfaceId = stripped.count
        c.morphologyWithSurfaceId = allMorph.count
        c.morphologyWithoutSurfaceId = strippedMorph.count
        return c
    }

    /// Gerçek `tr-TR` paketiyle ölçüm: 70k form + 30k kök, morfoloji açık,
    /// budama açık, 12 kelime.
    ///
    /// Ölçülen (2026-08-01):
    ///
    /// ```
    ///                       tutulan   surfaceId'siz   fark
    /// toplam                 12 800         10 079   +2 721   (%27.0)
    /// morfoloji durumları     7 303          4 582   +2 721   (%59.4)
    /// form trie durumları     5 497          5 497        0
    /// ```
    ///
    /// **Bedel küçük değil.** İlk tahmin "yüzde birkaç"tı; ölçüm çürüttü.
    /// Morfoloji beam'i `surfaceId` yüzünden **1.6 katına** çıkıyor: tutulan
    /// morfoloji yuvalarının **%37'si** yalnızca yüzey ayrımı için duruyor.
    ///
    /// **Farkın tamamı morfolojinin.** İki fark birebir aynı (2 721) ve form
    /// trie tarafı tam olarak sıfır. Bu, §4.2'nin "form trie'de düğüm öneki
    /// tekil belirler" iddiasının üretim leksikonu üzerinde doğrulanması —
    /// ayrı bir test aynı şeyi oyuncak leksikonda da sınıyor, bu ise gerçek
    /// pakette.
    ///
    /// ## Bu sayı ne değil
    ///
    /// Bir tasarruf fırsatı değil: `surfaceId` çıkarılırsa farklı yüzeyler tek
    /// duruma katlanır ve `reconstruct` hangi yüzeyi yazacağını bilemez.
    /// Ölçülen şey doğruluğun fiyatı.
    ///
    /// Bir doğruluk kaybı ölçümü de değil: beam `beamWidth` ile kapalı olduğu
    /// için bu yuvalar başka adayların yerini alıyor **olabilir**, ama hangi
    /// adayın kaybedildiği bu ölçümde görünmüyor. Onu görmek için `kbbench`
    /// doğruluk kolu gerekir ve o ayrı bir iş.
    ///
    /// Karşı-olgu **aynı koşu** üzerine izdüşüm: tutulan durumların kaba
    /// anahtarla kaç tekile indiği. `surfaceId`'siz gerçek bir arama farklı
    /// durumlar tutardı; o aramayı koşmak, karşılaştırmayı iki farklı
    /// algoritma arasına taşımak olurdu.
    ///
    /// ## Test neyi koruyor
    ///
    /// Eşik yok, **patlama alarmı** var: oran 27'den 100'e çıkarsa morfoloji
    /// grafında bir şey değişmiş demektir (Faz 4 adayı) ve §9 yeniden
    /// okunmalıdır. Kapı gevşek bilerek — leksikon her güncellendiğinde
    /// anlamsızca kırılan bir eşik ölçümü değil gürültüyü kovalar.
    @Test("surfaceId bedeli ölçüldü: morfoloji beam'i 1.6 katı")
    func surfaceIdCostOnTheProductionLexicon() throws {
        let layout = Self.layout()
        let source = DirectoryPackSource(root: Self.packRoot)
        // Paket ağacı yoksa ölçüm yapılmadı; `0` kabul etmek sınamadan geçmek
        // olurdu.
        guard let loaded = try? PackLoader.load(layout: layout, source: source),
              loaded.decoder.lexicon.sources.contains(where: { $0.morphology != nil })
        else { return }

        // Üretim decoder'ı **olduğu gibi**: budama açık, beam genişliği aynı.
        let engine = loaded.decoder

        // Morfolojiyi çalıştıran kelimeler: türemiş biçimler ve kanonik vaka.
        let words = ["kalem", "kalemler", "kalemlerimizden", "kitap", "kitabı",
                     "geliyor", "gelmeyecek", "evlerimizde", "güzel", "yazdım",
                     "lslem", "burnu"]

        var total = Counts()
        for w in words {
            let c = Self.measure(w, decoder: engine, layout: layout)
            total.withSurfaceId += c.withSurfaceId
            total.withoutSurfaceId += c.withoutSurfaceId
            total.morphologyWithSurfaceId += c.morphologyWithSurfaceId
            total.morphologyWithoutSurfaceId += c.morphologyWithoutSurfaceId
        }

        #expect(total.withSurfaceId > 0, "hiç durum üretilmedi — ölçüm anlamsız")
        // `surfaceId` durum **ekleyemez**, yalnız ayırabilir: sıfırlamak iki
        // durumu birleştirebilir, ayıramaz. Ters yön çıkarsa sayım hatalıdır.
        #expect(total.withoutSurfaceId <= total.withSurfaceId)

        // **Farkın tamamı morfolojinin.** §4.2 üretim leksikonu üzerinde
        // burada doğrulanıyor: form trie tarafında `surfaceId` hiçbir durumu
        // ayırmıyorsa iki fark birebir eşit olmalı. Eşit değilse ya §4.2
        // yanlış ya sayım.
        #expect(total.withSurfaceId - total.withoutSurfaceId
                == total.morphologyWithSurfaceId - total.morphologyWithoutSurfaceId,
                "form trie tarafında da durum ayrılmış — §4.2 iddiası sınanmalı")

        let overhead = Double(total.withSurfaceId - total.withoutSurfaceId)
            / Double(total.withoutSurfaceId)
        // Patlama alarmı, hedef değil. Ölçülen %27; iki katına çıkması
        // morfoloji grafında yapısal bir değişiklik demek.
        #expect(overhead < 1.00, """
            surfaceId beam'i %\(Int(overhead * 100)) genişletiyor \
            (\(total.withoutSurfaceId) → \(total.withSurfaceId)). \
            Ölçüm 2026-08-01'de %27'ydi; graf ya da leksikon değiştiyse §9 \
            yeniden okunmalı.
            """)
    }

    /// Form trie tarafında `surfaceId` **hiçbir** durum ayırmıyor.
    ///
    /// §4.2'nin iddiası: form trie'de düğüm öneki tekil belirler, dolayısıyla
    /// `surfaceId ≡ node`. Bu bir tanım değil bir **iddia** ve sınanabilir:
    /// morfolojisiz bir leksikonda `surfaceId`'yi sıfırlamak durum sayısını
    /// değiştirmemeli. Değiştirseydi, iki farklı yüzey aynı trie düğümüne
    /// varıyor demekti ve §4.2 yanlış olurdu.
    @Test("Form trie'de surfaceId hiçbir durumu ayırmıyor")
    func surfaceIdIsFreeOnTheFormTrie() throws {
        let layout = Self.layout()
        let counts = ["kalem": 900.0, "işlem": 1500, "kalan": 700, "güzel": 800,
                      "kalemler": 200, "kitap": 1400]
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let trie = try FormTrie(data: Data(bytes))
        let decoder = Decoder(layout: layout, spatial: SpatialModel(layout: layout),
                              lexicon: LexiconSet(formTrie: trie, morphology: nil),
                              beamWidth: 128, disablePruning: true)

        for w in ["kalem", "işlem", "kalemler", "lslem"] {
            let c = Self.measure(w, decoder: decoder, layout: layout)
            #expect(c.withSurfaceId == c.withoutSurfaceId,
                    "\(w): form trie'de surfaceId durum ayırdı — §4.2 iddiası yanlış")
        }
    }
}
