import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLexicon
@testable import KBDecoder
@testable import KBRuntime

/// Emoji kataloğu ve son kullanılanlar.
///
/// Katalog **elle yazılmış** bir veri kümesi ve elle yazılmış veri sessizce
/// bozulur: yanlış bir kod noktası, iki grapheme'e bölünen bir dizi ya da
/// tekrar eden bir girdi hiçbir derleme hatası vermez. Ekrandaysa bozuk
/// hücre, tofu kutusu ya da taşan bir tuş olarak görünür.
final class EmojiTests: XCTestCase {

    // MARK: - Katalog

    /// **Her girdi tek grapheme.** Izgara hücre başına tek şey çiziyor;
    /// `👍🏽` gibi iki parçaya bölünen bir dizi hücreyi taşırır, ve daha
    /// kötüsü `insertSymbol(Character(...))` yolunda `Character(String)`
    /// tek grapheme istiyor.
    func testEveryEntryIsASingleGrapheme() {
        for c in EmojiCatalog.categories {
            for e in c.emoji {
                XCTAssertEqual(e.count, 1,
                               "'\(e)' (\(c.id)) \(e.count) grapheme — tek olmalı")
            }
        }
    }

    /// Her girdi gerçekten **emoji olarak çiziliyor**. Yanlışlıkla düz bir
    /// harf ya da noktalama eklemek en kolay hata ve ekranda tofu kutusu ya da
    /// metin görünümlü bir sembol olarak çıkar.
    ///
    /// İki koşul birlikte: karakter emoji **olabilmeli** (`isEmoji`), ve emoji
    /// **sunumunda** olmalı. İkincisinin üç meşru yolu var ve üçü de listede
    /// bulunuyor:
    /// - varsayılan emoji sunumu (`😀`),
    /// - VS16 ile açıkça emoji'ye çevrilmiş metin sembolü (`↗️`, `ℹ️`),
    /// - keycap dizisi (`0️⃣` — rakam + VS16 + U+20E3).
    ///
    /// Yalnız `isEmojiPresentation`'a bakmak son ikisini reddederdi; yalnız
    /// `isEmoji`'ye bakmak düz bir rakamı kabul ederdi.
    func testEveryEntryIsEmoji() {
        for c in EmojiCatalog.categories {
            for e in c.emoji {
                let scalars = Array(e.unicodeScalars)
                let canBeEmoji = scalars.contains { $0.properties.isEmoji }
                let presented = scalars.contains { $0.properties.isEmojiPresentation }
                    || scalars.contains { $0.value == 0xFE0F }   // VS16
                    || scalars.contains { $0.value == 0x20E3 }   // keycap
                XCTAssertTrue(canBeEmoji && presented,
                              "'\(e)' (\(c.id)) emoji olarak çizilmiyor")
            }
        }
    }

    /// **Kategori içinde tekrar yok.** Aynı emoji'yi iki hücrede göstermek
    /// yer israfı ve kullanıcıya listenin bakımsız olduğunu söyler.
    ///
    /// Kategoriler **arasında** tekrar serbest: `❤️` hem suratlarda hem
    /// sembollerde meşru.
    func testNoDuplicatesWithinACategory() {
        for c in EmojiCatalog.categories {
            var seen = Set<String>()
            for e in c.emoji {
                XCTAssertTrue(seen.insert(e).inserted, "'\(e)' \(c.id) içinde tekrar ediyor")
            }
        }
    }

    /// Kategori kimlikleri tekil ve boş değil — sekme durumu bunlara bakıyor.
    func testCategoryIdentitiesAreUniqueAndNonEmpty() {
        var ids = Set<String>()
        for c in EmojiCatalog.categories {
            XCTAssertFalse(c.id.isEmpty)
            XCTAssertFalse(c.emoji.isEmpty, "\(c.id) boş")
            XCTAssertEqual(c.symbol.count, 1, "\(c.id) sekme simgesi tek grapheme olmalı")
            XCTAssertFalse(c.title.isEmpty, "\(c.id) erişilebilirlik etiketi yok")
            XCTAssertTrue(ids.insert(c.id).inserted, "kategori kimliği tekrar ediyor: \(c.id)")
        }
        XCTAssertFalse(EmojiCatalog.categories.isEmpty)
    }

    /// Sekme simgesi kendi kategorisinde bulunmalı: sekmede gösterilen şeyin
    /// içeride olmaması, listenin simgeden bağımsız kaydığının işareti.
    func testCategorySymbolBelongsToItsCategory() {
        for c in EmojiCatalog.categories {
            XCTAssertTrue(c.emoji.contains(c.symbol),
                          "\(c.id) simgesi '\(c.symbol)' kendi listesinde yok")
        }
    }

    /// Bayraklar 🇹🇷 ile başlıyor ve liste RGI'dan **eksiksiz** üretildi —
    /// sayının düşmesi, yeniden üretimde bir alt grubun kaybolduğunu gösterir.
    func testFlagsStartWithTurkeyAndAreComplete() throws {
        let flags = try XCTUnwrap(EmojiCatalog.category(id: "flags")).emoji
        XCTAssertEqual(flags.first, "🇹🇷")
        let countries = flags.filter { e in
            e.unicodeScalars.count == 2
                && e.unicodeScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        }
        // Emoji 15.1'de 258 ülke bayrağı var.
        XCTAssertEqual(countries.count, 258)
        XCTAssertTrue(flags.contains("🏴󠁧󠁢󠁥󠁮󠁧󠁿"), "alt bölge bayrakları eksik")
        XCTAssertTrue(flags.contains("🏳️‍🌈"), "genel bayraklar eksik")
    }

    // MARK: - Son kullanılanlar

    func testMostRecentlyUsedComesFirst() {
        var r = EmojiRecents()
        XCTAssertTrue(r.use("😀"))
        XCTAssertTrue(r.use("🎉"))
        XCTAssertEqual(r.items, ["🎉", "😀"])
    }

    /// Tekrar kullanılan emoji **başa taşınıyor**, ikinci kez eklenmiyor.
    func testReusingMovesToFrontWithoutDuplicating() {
        var r = EmojiRecents()
        r.use("😀"); r.use("🎉"); r.use("😀")
        XCTAssertEqual(r.items, ["😀", "🎉"])
    }

    /// Aynı emoji zaten baştaysa liste değişmiyor — çağıran boşuna diske
    /// yazmasın.
    func testNoChangeWhenAlreadyFirst() {
        var r = EmojiRecents()
        r.use("😀")
        XCTAssertFalse(r.use("😀"))
    }

    func testCapacityIsEnforced() {
        var r = EmojiRecents()
        for e in EmojiCatalog.all.prefix(EmojiRecents.capacity + 10) { r.use(e) }
        XCTAssertEqual(r.items.count, EmojiRecents.capacity)
    }

    /// Depodan gelen bozuk liste **yükleme sırasında** düzeltiliyor: tekrarlar
    /// düşüyor, sınır uygulanıyor. Olduğu gibi kabul etmek `use`'un koruduğu
    /// değişmezleri yükleme yolunda delerdi.
    func testLoadingSanitizesTheList() {
        let dirty = Array(repeating: "😀", count: 5)
            + EmojiCatalog.all.prefix(EmojiRecents.capacity + 20)
        let r = EmojiRecents(items: dirty)
        XCTAssertEqual(r.items.count, EmojiRecents.capacity)
        XCTAssertEqual(Set(r.items).count, r.items.count, "tekrar kalmış")
    }

    /// Tek grapheme olmayan girdi listeye girmiyor.
    func testMultiGraphemeInputIsRejected() {
        var r = EmojiRecents()
        XCTAssertFalse(r.use("😀😀"))
        XCTAssertFalse(r.use(""))
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - Giriş yolu

    private let layout = TurkishQ.layout()

    private final class Doc: DocumentEditor {
        private(set) var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

    private func coordinator() throws -> InputCoordinator {
        let counts = TestLexicon.counts
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let lex = LexiconSet(formTrie: try FormTrie(data: Data(bytes)), morphology: nil)
        var channel = LiteralChannel(vocabulary: lex,
                                     charModel: try CharNGramBuilder.build(
                                        words: Array(counts.keys)))
        channel.autoCorrectsOutOfVocabulary = true
        var c = InputCoordinator(layout: layout)
        c.setEngine(.init(decoder: Decoder(layout: layout,
                                           spatial: SpatialModel(layout: layout),
                                           lexicon: lex, beamWidth: 128),
                          literalChannel: channel))
        return c
    }

    private func type(_ word: String, _ c: inout InputCoordinator, _ doc: Doc) {
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            c.insertLetter(ch, touch: TouchSample(down: layout.keys[k].center,
                                                  timestamp: 0), into: doc)
        }
    }

    /// Emoji **sembol yolundan** giriyor: token'ı kapatıyor, düzeltme
    /// denenmiyor, ve belgeye olduğu gibi yazılıyor.
    func testEmojiClosesTheTokenWithoutCorrection() throws {
        var c = try coordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        let report = c.insertSymbol("😀", into: doc)

        XCTAssertEqual(doc.text, "kalem😀")
        XCTAssertFalse(c.session.isComposing, "emoji token sınırı olmalı")
        XCTAssertEqual(report.kind, .literal)
        // Sembolde düzeltme **hiç denenmiyor**; `Δ`/`θ` bu yüzden yok.
        XCTAssertNil(report.delta)
        XCTAssertNil(report.theta)
    }

    /// Çok skalerli emoji **bölünmeden** yazılıyor.
    ///
    /// `❤️` iki skaler (U+2764 + VS16) ama tek grapheme. Belgeye yarısının
    /// gitmesi ya da `Character(String)` yolunda çökmesi, tam da katalogdaki
    /// VS16'lı girdilerin açtığı risk.
    func testMultiScalarEmojiSurvivesIntact() throws {
        var c = try coordinator()
        let doc = Doc()
        for e in ["❤️", "0️⃣", "🕷️"] {
            _ = c.insertSymbol(Character(e), into: doc)
        }
        XCTAssertEqual(doc.text, "❤️0️⃣🕷️")
        XCTAssertEqual(doc.text.count, 3, "her emoji tek grapheme kalmalı")
    }

    /// Emoji cümleyi bitirmiyor: kendisinden önceki kelime bağlam olarak
    /// kalıyor (§2 öznitelik 13). `.` gibi davransaydı emoji koyan kullanıcı
    /// bağlamını kaybederdi.
    func testEmojiDoesNotEndTheSentence() {
        XCTAssertFalse(InputCoordinator.endsSentence("😀"))
        XCTAssertTrue(InputCoordinator.endsSentence("."))
    }

    /// Katalogdaki **her** emoji giriş yolundan geçebilmeli. Tek bir bozuk
    /// girdi, kullanıcı ona dokunduğunda klavyeyi düşürürdü.
    func testEveryCatalogEntryCanBeInserted() throws {
        var c = try coordinator()
        let doc = Doc()
        var expected = ""
        for e in EmojiCatalog.all {
            guard e.count == 1 else { continue }   // ayrı test tutuyor
            _ = c.insertSymbol(Character(e), into: doc)
            expected += e
        }
        XCTAssertEqual(doc.text, expected)
    }
}
