import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLexicon
@testable import KBDecoder
@testable import KBLearning
@testable import KBRuntime

/// Kişisel sözlük — sözleşme §8.7.
///
/// Üç ayrı katman ayrı ayrı tutuluyor: kabul politikası (saf sayaç), depo
/// (bayt formatı), ve motorun kurulumu (§7 tek sahiplik + `θ = ∞`).
final class PersonalLexiconTests: XCTestCase {

    // MARK: - Kanonik yüzey

    /// Leksikal anahtar §7 ile aynı: NFC + Türkçeye duyarlı küçük harf.
    func testCanonicalUsesTurkishLowercasing() {
        XCTAssertEqual(PersonalLexicon.canonical("Çağrı"), "çağrı")
        // `İ` locale'siz küçültülünce `i` + birleşen nokta olur (iki skaler) ve
        // trie sembol birimi tek skaler olduğu için kelime sessizce reddedilirdi.
        XCTAssertEqual(PersonalLexicon.canonical("İzmir"), "izmir")
        XCTAssertEqual(PersonalLexicon.canonical("KARDO"), "kardo")
    }

    /// Harf olmayan hiçbir şey kabul edilmez: korumalı token'lar (`x1`, `@ali`)
    /// zaten `θ = ∞` alıyor, onları sözlüğe koymak yalnız kirletirdi.
    func testCanonicalRejectsNonLetters() {
        XCTAssertNil(PersonalLexicon.canonical("x1"))
        XCTAssertNil(PersonalLexicon.canonical("@ali"))
        XCTAssertNil(PersonalLexicon.canonical("a.b"))
        XCTAssertNil(PersonalLexicon.canonical(""))
        XCTAssertNil(PersonalLexicon.canonical("a"), "tek harf kabul edilmemeli")
        XCTAssertNil(PersonalLexicon.canonical(String(repeating: "a", count: 41)))
    }

    // MARK: - Kabul politikası

    /// Üç zayıf gözlem kabul eder; ikisi etmez. Eşik §5c asimetrisinden
    /// geliyor: yanlış kabul aktif zarar, geç kabul yalnız gecikme.
    func testThreeWeakObservationsAdmit() {
        var p = PersonalLexicon()
        XCTAssertFalse(p.observe("sencagri", confidence: .weak))
        XCTAssertFalse(p.observe("sencagri", confidence: .weak))
        XCTAssertFalse(p.isAdmitted("sencagri"), "iki gözlem yetmemeli")
        XCTAssertTrue(p.observe("sencagri", confidence: .weak),
                      "kabul edilen küme değişti — çağıran motoru kurmalı")
        XCTAssertTrue(p.isAdmitted("sencagri"))
        XCTAssertEqual(p.admitted, ["sencagri"])
    }

    /// Dönüş değeri **geçişi** bildiriyor, üyeliği değil: kabulden sonraki
    /// gözlemler motoru yeniden kurdurmamalı.
    func testFurtherObservationsDoNotReportChange() {
        var p = PersonalLexicon()
        for _ in 0..<3 { _ = p.observe("kardo", confidence: .weak) }
        XCTAssertFalse(p.observe("kardo", confidence: .weak))
    }

    /// Açık seçim tek başına yeter: kullanıcı alternatifi görüp kendi yüzeyinde
    /// ısrar etmiştir.
    func testOneStrongObservationAdmits() {
        var p = PersonalLexicon()
        XCTAssertTrue(p.observe("reyiz", confidence: .strong))
        XCTAssertTrue(p.isAdmitted("reyiz"))
    }

    /// Uygun olmayan yüzey hiç girmiyor — sayaç bile tutulmuyor.
    func testIneligibleSurfacesAreNotCounted() {
        var p = PersonalLexicon()
        for _ in 0..<5 { _ = p.observe("mail@x.com", confidence: .strong) }
        XCTAssertTrue(p.isEmpty)
    }

    /// Yanlışlıkla öğretilen bir typo silinebilmeli: `θ = ∞` koruması onu aksi
    /// hâlde kalıcı kılardı.
    func testForgetRemovesAnAdmittedSurface() {
        var p = PersonalLexicon()
        _ = p.observe("kalne", confidence: .strong)
        XCTAssertTrue(p.forget("Kalne"), "kanonikleştirme silmede de geçerli")
        XCTAssertFalse(p.isAdmitted("kalne"))
        XCTAssertFalse(p.forget("kalne"), "olmayan yüzeyde değişiklik yok")
    }

    /// Kapasite dolduğunda en az kanıtlı, eşitlikte en eski girdi düşer.
    func testEvictionDropsTheWeakestEntry() {
        var p = PersonalLexicon()
        // Kapasiteyi dolduran zayıf girdiler.
        for i in 0..<PersonalLexicon.capacity {
            _ = p.observe(surface(i), confidence: .weak)
        }
        XCTAssertEqual(p.count, PersonalLexicon.capacity)
        // İlk girdi hem en zayıf hem en eski — düşmesi gereken o.
        _ = p.observe("sonradangelen", confidence: .strong)
        XCTAssertEqual(p.count, PersonalLexicon.capacity)
        XCTAssertNil(p.entries[surface(0)], "en eski zayıf girdi düşmeliydi")
        XCTAssertTrue(p.isAdmitted("sonradangelen"))
    }

    /// Kabul edilmiş bir girdi düştüyse çağıran motoru yeniden kurmalı.
    ///
    /// Eşit puanda en eski düşüyor: yeni gelen `.strong` ile aynı puana sahip
    /// olduğu için tie-break yaşa bakıyor.
    func testEvictingAnAdmittedSurfaceReportsChange() {
        var p = PersonalLexicon()
        for i in 0..<PersonalLexicon.capacity {
            _ = p.observe(surface(i), confidence: .strong)   // hepsi kabul edilmiş
        }
        XCTAssertTrue(p.observe("yeni", confidence: .strong),
                      "kabul edilmiş bir yüzey düştü — küme değişti")
        XCTAssertNil(p.entries[surface(0)])
        XCTAssertTrue(p.isAdmitted("yeni"))
    }

    /// **Dolu ve tamamı kabul edilmiş** sözlükte yeni bir zayıf gözlem hiçbir
    /// şey değiştirmiyor: puanı en düşük olan yeni girdinin kendisi ve o
    /// düşüyor. Yani sözlük tavana vurduğunda donuyor.
    ///
    /// Bilinçli: alternatif, kanıtı çok daha güçlü bir yüzeyi tek bir gözlem
    /// uğruna atmaktı. 512 kabul edilmiş kelimeye ulaşmış kullanıcı zaten
    /// korunuyor; kullanıcı yer açmak isterse `forget` var.
    func testAFullDictionaryDoesNotYieldToASingleWeakObservation() {
        var p = PersonalLexicon()
        for i in 0..<PersonalLexicon.capacity {
            _ = p.observe(surface(i), confidence: .strong)
        }
        XCTAssertFalse(p.observe("yeni", confidence: .weak))
        XCTAssertNotNil(p.entries[surface(0)])
        XCTAssertFalse(p.isAdmitted("yeni"))
    }

    private func surface(_ i: Int) -> String {
        // Yalnız harf, en az iki karakter.
        let alphabet = Array("abcdefghijklmnoprstuvyz")
        let a = alphabet[i % alphabet.count]
        let b = alphabet[(i / alphabet.count) % alphabet.count]
        let c = alphabet[(i / (alphabet.count * alphabet.count)) % alphabet.count]
        return "\(a)\(b)\(c)"
    }

    // MARK: - Depo

    func testStoreRoundTrip() throws {
        var p = PersonalLexicon()
        _ = p.observe("sencagri", confidence: .strong)
        _ = p.observe("zeynepcim", confidence: .weak)
        _ = p.observe("çağrışen", confidence: .weak)

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PersonalLexiconStore.save(p, to: dir)
        let back = try PersonalLexiconStore.load(from: dir)

        XCTAssertEqual(back.entries, p.entries)
        XCTAssertEqual(back.admitted, ["sencagri"])
    }

    /// Bozuk dosya **yok sayılıyor**: bozuk bir kişisel sözlükle çalışmak aktif
    /// zarardır (`θ = ∞` yanlış yüzeylere gider), boş başlamak yalnız erteler.
    func testCorruptStoreLoadsEmpty() throws {
        var p = PersonalLexicon()
        _ = p.observe("sencagri", confidence: .strong)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PersonalLexiconStore.save(p, to: dir)

        let url = dir.appendingPathComponent(PersonalLexiconStore.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[bytes.count - 1] ^= 0xFF
        try Data(bytes).write(to: url)

        XCTAssertThrowsError(try PersonalLexiconStore.load(from: dir))
        XCTAssertTrue(PersonalLexiconStore.loadOrEmpty(from: dir).isEmpty)
    }

    /// Aynı sözlük daima aynı baytları üretmeli — `Dictionary` sırası koşudan
    /// koşuya değişiyor ve dosya boşuna farklılaşırdı.
    func testStoreIsByteStable() throws {
        var p = PersonalLexicon()
        for w in ["biri", "ikisi", "üçü", "dördü"] { _ = p.observe(w, confidence: .strong) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PersonalLexiconStore.save(p, to: dir)
        let first = try Data(contentsOf: dir.appendingPathComponent(PersonalLexiconStore.fileName))
        try PersonalLexiconStore.save(p, to: dir)
        let second = try Data(contentsOf: dir.appendingPathComponent(PersonalLexiconStore.fileName))
        XCTAssertEqual(first, second)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Kaynak kurulumu

    private func packLexicon(_ counts: [String: Double]) throws -> LexiconSet {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        return LexiconSet(formTrie: try FormTrie(data: Data(bytes)), morphology: nil)
    }

    /// §7 tek sahiplik: pakette olan yüzey kişisel kaynağa **girmez**.
    /// Girseydi aynı yüzey iki kaynaktan iki farklı maliyet alır ve decoder
    /// ucuz olanı seçerdi.
    func testKnownSurfacesAreExcluded() throws {
        let base = try packLexicon(["kalem": 900, "işlem": 1500])
        let built = PersonalLexiconSource.build(words: ["kalem", "sencagri"], base: base)
        XCTAssertEqual(built?.words, ["sencagri"])
        XCTAssertNil(built?.source.formTrie?.lookup("kalem"))
    }

    /// Hepsi zaten biliniyorsa kaynak **kurulmaz** — boş bir trie eklemek
    /// leksikonu gereksiz yere bölerdi.
    func testNoSourceWhenEverySurfaceIsKnown() throws {
        let base = try packLexicon(["kalem": 900])
        XCTAssertNil(PersonalLexiconSource.build(words: ["kalem"], base: base))
    }

    /// Kişisel yüzeyin ham `F_lex`'i çıpanın ta kendisi olmalı: trie maliyet
    /// itmesiyle kuruluyor ve yol toplamı `L(w)`'ye eşit çıkmazsa kaynaklar
    /// arası maliyetler karşılaştırılamaz olurdu (§7.1).
    func testAdmittedSurfaceCostsTheAnchor() throws {
        let base = try packLexicon(["kalem": 900])
        let built = PersonalLexiconSource.build(words: ["sencagri"], base: base)
        XCTAssertEqual(built?.source.formTrie?.lookup("sencagri") ?? 0,
                       PersonalLexicon.lexCost, accuracy: 1e-3)
    }

    /// Aynı kelime kümesi aynı özeti üretmeli — kayıt bu özetle motoru
    /// tanımlıyor (§12.7).
    func testSourceDigestIsStable() throws {
        let base = try packLexicon(["kalem": 900])
        let a = PersonalLexiconSource.build(words: ["sencagri", "kardo"], base: base)
        let b = PersonalLexiconSource.build(words: ["sencagri", "kardo"], base: base)
        let c = PersonalLexiconSource.build(words: ["sencagri", "reyiz"], base: base)
        XCTAssertEqual(a?.sha256, b?.sha256)
        XCTAssertNotEqual(a?.sha256, c?.sha256)
    }

    // MARK: - Uçtan uca: koordinatör

    private let layout = TurkishQ.layout()

    private final class Doc: DocumentEditor {
        private(set) var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

    /// Karakter modeli **gerçekçi bir kelime kümesinden** kuruluyor.
    ///
    /// İki kelimelik oyuncak sözlükle kurulan model her sözlük dışı yüzeye
    /// 70+ nat veriyor ve `Δ` her zaman `θ`'yı aşıyor: o kurulumda hiçbir OOV
    /// kelime commit edilemezdi, yani test kişisel sözlüğü değil kendi
    /// oyuncağını ölçerdi.
    private func coordinator(_ counts: [String: Double] = TestLexicon.counts)
        throws -> InputCoordinator {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let trie = try FormTrie(data: Data(bytes))
        let lex = LexiconSet(formTrie: trie, morphology: nil)
        let model = try CharNGramBuilder.build(words: Array(counts.keys))
        var channel = LiteralChannel(vocabulary: lex, charModel: model)
        channel.autoCorrectsOutOfVocabulary = true
        var c = InputCoordinator(layout: layout)
        c.setEngine(.init(decoder: Decoder(layout: layout,
                                           spatial: SpatialModel(layout: layout),
                                           lexicon: lex, beamWidth: 128),
                          literalChannel: channel))
        return c
    }

    /// Tuş merkezine basarak yazar — kullanıcının hedefine tam bastığı durum.
    private func type(_ word: String, _ c: inout InputCoordinator, _ doc: Doc) {
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            c.insertLetter(ch, touch: TouchSample(down: layout.keys[k].center,
                                                  timestamp: 0), into: doc)
        }
    }

    /// Kanonik vaka: sözlük dışı kelime üç kez yazılınca `V`'ye giriyor ve
    /// `θ = ∞` alıyor — bir daha bozulamaz.
    func testThreeCommitsAdmitTheWordAndProtectIt() throws {
        var c = try coordinator()
        let doc = Doc()
        for _ in 0..<3 {
            type("sencagri", &c, doc)
            c.space(into: doc)
        }
        XCTAssertEqual(doc.text, "sencagri sencagri sencagri ")
        XCTAssertTrue(c.personal.isAdmitted("sencagri"))
        XCTAssertTrue(c.wantsPersonalSave, "çağıran diske yazmalı")

        // Motor **fiilen** değişti: kanal artık yüzeyi sözlükte görüyor.
        let score = try XCTUnwrap(c.engine?.literalChannel.score("sencagri"))
        XCTAssertTrue(score.isInVocabulary)
        XCTAssertTrue(score.demandsProtection, "kabul edilen kelime θ = ∞ almalı")
        XCTAssertEqual(score.lexCost, PersonalLexicon.lexCost, accuracy: 1e-3)

        // Ve decoder onu aday olarak üretebiliyor.
        type("sencagri", &c, doc)
        XCTAssertEqual(c.candidates(topK: 1).first?.word, "sencagri")
    }

    /// Kaynak kimliği kayda giriyor (§12.7): kabulden sonra dolmalı.
    func testAdmissionPublishesASourceReference() throws {
        var c = try coordinator()
        let doc = Doc()
        XCTAssertNil(c.personalSourceRef)
        for _ in 0..<3 { type("kardo", &c, doc); c.space(into: doc) }
        let ref = try XCTUnwrap(c.personalSourceRef)
        XCTAssertEqual(ref.wordCount, 1)
        XCTAssertGreaterThan(ref.byteCount, 0)
        XCTAssertEqual(ref.sourceOrder, 1, "paket kaynağından sonra gelmeli")
    }

    /// Parola alanında hiçbir şey öğrenilmiyor.
    ///
    /// Üretimde tampon zaten düşürülüyor, ama yedek yol doğrudan koordinatörü
    /// kullanıyor ve başka bir katmanın davranışına dayanan koruma, koruma
    /// değildir.
    func testNothingIsLearnedInSecureFields() throws {
        var c = try coordinator()
        c.fieldIsSecure = true
        let doc = Doc()
        for _ in 0..<5 { type("hunharca", &c, doc); c.space(into: doc) }
        XCTAssertTrue(c.personal.isEmpty)
    }

    /// `θ = ∞` olan yolda kanıt yok: klavye token'ı **yargılamadı**, dolayısıyla
    /// "değiştirmedi" bir olgu değil.
    func testProtectedFieldsProduceNoEvidence() throws {
        var c = try coordinator()
        let doc = Doc()
        for _ in 0..<5 {
            type("hunharca", &c, doc)
            c.space(into: doc, fieldProtectsLiteral: true)
        }
        XCTAssertTrue(c.personal.isEmpty)
    }

    /// Sözlükteki kelime kişisel sözlüğe **girmiyor** — kanıt yalnız OOV için
    /// toplanıyor, yoksa depo paket kelimeleriyle dolardı.
    func testKnownWordsAreNotLearned() throws {
        var c = try coordinator()
        let doc = Doc()
        for _ in 0..<5 { type("kalem", &c, doc); c.space(into: doc) }
        XCTAssertTrue(c.personal.isEmpty)
    }

    /// Düzeltme uygulandıysa kullanıcının yüzeyi belgede değil — öğrenilecek
    /// bir şey de yok.
    func testCorrectedTokensProduceNoEvidence() throws {
        var c = try coordinator()
        c.correction.oovTheta = 0            // her OOV düzeltilsin
        let doc = Doc()
        for _ in 0..<5 { type("kalen", &c, doc); c.space(into: doc) }
        XCTAssertEqual(doc.text, "kalem kalem kalem kalem kalem ")
        XCTAssertTrue(c.personal.isEmpty)
    }

    /// Sözlük diskten yüklenince motor **hemen** kuruluyor: kullanıcı klavyeyi
    /// her açtığında kelimelerini yeniden öğretmemeli.
    func testReplacingTheLexiconRebuildsTheEngine() throws {
        var c = try coordinator()
        var p = PersonalLexicon()
        _ = p.observe("reyiz", confidence: .strong)
        c.replacePersonalLexicon(p)
        XCTAssertTrue(try XCTUnwrap(c.engine?.literalChannel.score("reyiz")).isInVocabulary)
        XCTAssertFalse(c.wantsPersonalSave, "yükleme kaydetme isteği doğurmaz")
    }

    /// Silinen yüzey motordan da düşmeli — yoksa `θ = ∞` koruması sürerdi.
    func testForgettingRemovesTheWordFromTheEngine() throws {
        var c = try coordinator()
        var p = PersonalLexicon()
        _ = p.observe("kalne", confidence: .strong)
        c.replacePersonalLexicon(p)
        c.forgetPersonal("kalne")
        XCTAssertFalse(try XCTUnwrap(c.engine?.literalChannel.score("kalne")).isInVocabulary)
        XCTAssertNil(c.personalSourceRef)
    }

    // MARK: - Korpus içe aktarımı

    /// Metinde üç kez geçen sözlük dışı yüzey kabul ediliyor; bir kez geçen
    /// yalnız puan biriktiriyor. Yazarak öğrenmeyle **aynı eşik**.
    func testIngestAdmitsRepeatedUnknownWords() {
        var p = PersonalLexicon()
        let tokens = ["sencagri", "geldi", "sencagri", "gitti", "sencagri",
                      "kardo", "bir", "kez"]
        let report = p.ingest(tokens: tokens) { ["geldi", "gitti", "bir", "kez"].contains($0) }

        XCTAssertEqual(report.tokens, 8)
        XCTAssertEqual(report.candidates, 2, "yalnız sencagri ve kardo aday")
        XCTAssertEqual(report.admitted, ["sencagri"])
        XCTAssertTrue(report.changed)
        XCTAssertFalse(p.isAdmitted("kardo"), "tek geçiş kabul için yetmez")
        XCTAssertEqual(p.entries["kardo"]?.points, 1)
    }

    /// Aynı metni iki kez aktarmak sonucu değiştirmiyor: puan doyuruluyor.
    /// Doymasaydı tek bir içe aktarım, yazarak öğrenilmiş kelimeleri kapasite
    /// baskısı altında kurban ederdi.
    func testIngestIsIdempotent() {
        var p = PersonalLexicon()
        let tokens = Array(repeating: "sencagri", count: 50)
        _ = p.ingest(tokens: tokens) { _ in false }
        let after = p.entries["sencagri"]
        XCTAssertEqual(after?.points, PersonalLexicon.admissionPoints)
        let second = p.ingest(tokens: tokens) { _ in false }
        XCTAssertEqual(p.entries["sencagri"], after)
        XCTAssertTrue(second.admitted.isEmpty, "zaten kabul edilmişti")
        XCTAssertFalse(second.changed)
    }

    /// İçe aktarım yazarak biriken puanı **düşürmüyor**.
    func testIngestNeverLowersPoints() {
        var p = PersonalLexicon()
        for _ in 0..<5 { _ = p.observe("sencagri", confidence: .weak) }
        let before = p.entries["sencagri"]?.points ?? 0
        _ = p.ingest(tokens: ["sencagri"]) { _ in false }
        XCTAssertEqual(p.entries["sencagri"]?.points, before)
    }

    /// Bilinen kelimeler hiç girmiyor: kapasiteyi kullanıcının gerçek
    /// kelimeleri hak ediyor.
    func testIngestSkipsKnownSurfaces() {
        var p = PersonalLexicon()
        let tokens = Array(repeating: "kalem", count: 10)
        let report = p.ingest(tokens: tokens) { $0 == "kalem" }
        XCTAssertEqual(report.candidates, 0)
        XCTAssertTrue(p.isEmpty)
    }

    /// Koordinatör yolunda `V` üyeliği **motorun leksikonundan** soruluyor ve
    /// kabul motoru yeniden kuruyor.
    func testCoordinatorIngestProtectsTheWords() throws {
        var c = try coordinator()
        let report = c.ingestPersonal(
            tokens: ["sencagri", "sencagri", "sencagri", "kalem", "kalem", "kalem"])
        XCTAssertEqual(report.admitted, ["sencagri"], "kalem zaten sözlükte")
        XCTAssertTrue(c.wantsPersonalSave)
        XCTAssertTrue(try XCTUnwrap(c.engine?.literalChannel.score("sencagri"))
                        .demandsProtection)
    }

    /// Parola alanında içe aktarım da çalışmıyor.
    func testCoordinatorIngestRefusesSecureFields() throws {
        var c = try coordinator()
        c.fieldIsSecure = true
        let report = c.ingestPersonal(tokens: Array(repeating: "hunharca", count: 5))
        XCTAssertEqual(report.tokens, 0)
        XCTAssertTrue(c.personal.isEmpty)
    }

    /// Motor yeniden kurulurken **eski kişisel kaynak süzülüyor**: süzülmeseydi
    /// her kabulde bir öncekinin kopyası da taşınır ve aynı yüzey iki kaynaktan
    /// üretilirdi.
    func testRebuildingDoesNotAccumulateSources() throws {
        var c = try coordinator()
        var p = PersonalLexicon()
        _ = p.observe("reyiz", confidence: .strong)
        c.replacePersonalLexicon(p)
        _ = p.observe("kardo", confidence: .strong)
        c.replacePersonalLexicon(p)
        let sources = try XCTUnwrap(c.engine?.decoder.lexicon.sources)
        XCTAssertEqual(sources.filter { $0.kind == .personal }.count, 1)
        XCTAssertEqual(sources.count, 2)
    }
}
