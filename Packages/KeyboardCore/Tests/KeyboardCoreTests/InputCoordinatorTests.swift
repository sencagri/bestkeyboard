import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLexicon
@testable import KBMorphology
@testable import KBDecoder
@testable import KBLearning
@testable import KBRuntime

/// Uçtan uca girdi akışı — Codex'in "uzantı hedefinde test altyapısı yok"
/// diye kayda geçirdiğim borcu kapatıyor.
///
/// Bütün karar mantığı artık `InputCoordinator`'da olduğu için commit kararı,
/// kalibrasyon öğrenmesi ve seçim kipinin etkileşimi `swift test` altında
/// koşuyor. `UIInputViewController` ince bir adaptöre indi.
final class InputCoordinatorTests: XCTestCase {

    private let layout = TurkishQ.layout()

    private final class Doc: DocumentEditor {
        private(set) var text = ""
        private var selection: Range<String.Index>?
        private var cursor: String.Index { selection?.lowerBound ?? text.endIndex }

        func insertText(_ t: String) {
            if let r = selection {
                text.replaceSubrange(r, with: t); selection = nil
            } else {
                text.insert(contentsOf: t, at: cursor)
            }
        }
        func deleteBackward() {
            if let r = selection { text.removeSubrange(r); selection = nil }
            else if cursor > text.startIndex { text.remove(at: text.index(before: cursor)) }
        }
        var contextBeforeInput: String? { String(text[text.startIndex..<cursor]) }
        var contextAfterInput: String? {
            String(text[(selection?.upperBound ?? text.endIndex)...])
        }
        var selectedText: String? { selection.map { String(text[$0]) } }
        func hostSelects(_ s: String) { selection = text.range(of: s) }
        func hostRewrites(to s: String) { text = s; selection = nil }
    }

    private func engine(_ counts: [String: Double]) throws -> InputCoordinator.Engine {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let trie = try FormTrie(data: Data(bytes))
        let lex = LexiconSet(formTrie: trie, morphology: nil)
        let model = try CharNGramBuilder.build(words: Array(counts.keys))
        var channel = LiteralChannel(vocabulary: lex, charModel: model)
        channel.autoCorrectsOutOfVocabulary = true
        return .init(decoder: Decoder(layout: layout,
                                      spatial: SpatialModel(layout: layout),
                                      lexicon: lex, beamWidth: 128),
                     literalChannel: channel)
    }

    private func makeCoordinator(_ counts: [String: Double] = ["kalem": 900, "işlem": 1500,
                                                              "kalan": 700, "güzel": 800])
        throws -> InputCoordinator {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try engine(counts))
        return c
    }

    /// Parmağı **kaymış** yazım: son harf hedef ile komşusu arasında, ama
    /// literal komşuya düşecek kadar yakın. Gerçek bir typo böyle oluşur ve
    /// `cost(literal)`'in uzamsal terimini yükselten şey de budur.
    private func typeWithDrift(_ literal: String, driftingTo neighbour: Character,
                               _ c: inout InputCoordinator, _ doc: Doc) {
        let chars = Array(literal)
        for (i, ch) in chars.enumerated() {
            guard let k = layout.keyIndex(for: ch) else { continue }
            var p = layout.keys[k].center
            if i == chars.count - 1, let n = layout.keyIndex(for: neighbour) {
                let m = layout.keys[n].center
                p = Point(x: p.x * 0.6 + m.x * 0.4, y: p.y * 0.6 + m.y * 0.4)
            }
            c.insertLetter(ch, touch: TouchSample(down: p, timestamp: 0), into: doc)
        }
    }

    /// Tuş merkezine dokunarak yazar — kullanıcının hedefine tam bastığı durum.
    private func type(_ word: String, _ c: inout InputCoordinator, _ doc: Doc) {
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            c.insertLetter(ch, touch: TouchSample(down: layout.keys[k].center, timestamp: 0),
                           into: doc)
        }
    }

    // MARK: - Temel akış

    func testTypingAndSpaceCommitsTheWord() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalem ")
    }

    /// Kanonik vaka: `lslem` → `kalem`, `işlem` DEĞİL.
    func testTheCanonicalCaseSurvivesTheFullPipeline() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("lslem", &c, doc)
        XCTAssertEqual(c.candidates(topK: 1).first?.word, "kalem")

        // Yalnız aday listesi değil, **belgeye uygulanana kadar** tüm hat:
        // `space` → eşik kararı → `replaceDisplay` → `finishToken`.
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalem ", "düzeltme belgeye uygulanmalı")
    }

    /// `işlem` kazanamamalı — marj gösterim penceresinden geniş olmalı.
    func testTheRivalLosesByAWideMargin() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("lslem", &c, doc)
        let r = c.candidates(topK: 3)
        // `guard ... else { return }` testi sessizce başarılı yapıyordu:
        // `işlem` listede yoksa marj hiç doğrulanmıyordu.
        let best = try XCTUnwrap(r.first)
        let rival = try XCTUnwrap(r.first { $0.word == "işlem" })
        XCTAssertGreaterThan(rival.cost - best.cost, 3.0)
    }

    /// Bilinen kelime **asla** bozulmaz (§8: `θ = ∞`).
    func testKnownWordIsNeverAutoCorrected() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalan", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalan ", "sözlükteki kelime korunmalı")
    }

    func testProtectedTokenClassification() {
        for t in ["192.168.1.42", "camelCase", "k8s", "@ali", "v2.3.1", "#etiket"] {
            XCTAssertTrue(InputCoordinator.isProtectedToken(t), t)
        }
        for t in ["kalem", "güzel", "islem"] {
            XCTAssertFalse(InputCoordinator.isProtectedToken(t), t)
        }
    }

    /// Alan türü koruması (§8): `.URL`, `.emailAddress`, sayı klavyeleri.
    /// Sınıflandırma testi yetmez — korumanın **commit davranışına** bağlandığı
    /// doğrulanmalı.
    /// Alan türü koruması `θ = ∞` yapar.
    ///
    /// Eşik sıfırlanarak izole ediliyor: `θ_oov = 0` ile düzeltme kesin
    /// uygulanır, dolayısıyla uygulanmıyorsa sebebi **yalnız** alan koruması
    /// olabilir. Aksi hâlde test eşiğin ayarına bağlı kalır ve `θ` değişince
    /// sessizce anlamsızlaşırdı.
    func testFieldProtectionSuppressesAutoCorrection() throws {
        var c = try makeCoordinator()
        c.oovTheta = 0
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.space(into: doc, fieldProtectsLiteral: true)
        XCTAssertEqual(doc.text, "kalen ", "korumalı alanda düzeltme olmamalı")
    }

    /// Kontrol grubu: aynı girdi, aynı eşik, koruma kapalı → düzeltilir.
    /// Bu ikisi birlikte olmadan koruma testi bir şey kanıtlamaz.
    func testTheSameInputIsCorrectedWhenTheFieldDoesNotProtect() throws {
        var c = try makeCoordinator()
        c.oovTheta = 0
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.space(into: doc, fieldProtectsLiteral: false)
        XCTAssertEqual(doc.text, "kalem ", "korumasız alanda düzeltilmeli")
    }

    /// Eşiğin **kendisi** de bir kapı: aynı girdi varsayılan `θ_oov` ile
    /// düzeltilmez.
    ///
    /// Ölçüldü: bu girdide `Δ ≈ 13`, `θ_oov = 17`. Tek karakterlik sınır
    /// kayması eşiği aşmıyor — §8.1.1'in muhafazakâr ucunun doğrudan sonucu.
    /// Gerçek typo'lar birden çok karakterde sapar ve `Δ` birikir (ölçümde
    /// medyan 25.5).
    func testASingleBoundarySlipDoesNotReachTheDefaultThreshold() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalen ", "tek karakterlik kayma θ_oov'u aşmamalı")
    }

    /// **Tam tuş merkezine** basılan sözlük dışı kelime düzeltilmez.
    ///
    /// Eksiklik değil, §8.1.1'in tam olarak istediği davranış: parmak
    /// hedefindeyse `cost(literal)`'in uzamsal terimi düşüktür, `Δ` küçük kalır
    /// ve `θ_oov` devreye girmez. Doğru yazılmış özel adları koruyan mekanizma
    /// budur.
    func testAWordTypedExactlyOnTheKeysIsNotCorrected() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalen", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalen ", "hedefe tam basılan OOV kelime korunmalı")
    }

    // MARK: - Codex'in istediği uçtan uca test

    /// **Asıl borç.** Türetilmiş kanıtlı seçimde boşluk:
    /// belge değişmemeli **ve** kalibrasyon örneği artmamalı.
    func testSyntheticSelectionSpaceChangesNothingAndTeachesNothing() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        doc.hostRewrites(to: "guzel bir gün ")
        doc.hostSelects("guzel")

        c.handleSelection("guzel", into: doc)
        XCTAssertTrue(c.session.isEditingSelection)
        XCTAssertFalse(c.session.selectionHasRealEvidence,
                       "geçmiş boş — kanıt türetilmiş olmalı")

        let before = c.calibration.sampleCount
        c.space(into: doc)

        XCTAssertEqual(doc.text, "guzel bir gün ", "belge değişmemeli")
        XCTAssertEqual(c.calibration.sampleCount, before,
                       "türetilmiş dokunmalar kalibrasyona SIZMAMALI")
        XCTAssertFalse(c.session.isEditingSelection)
    }

    /// Türetilmiş seçimde kullanıcı adaya **dokunursa** uygulanır — ve yine
    /// kalibrasyona hiçbir şey girmez.
    func testTappingASuggestionOnASyntheticSelectionAppliesButDoesNotTeach() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        doc.hostRewrites(to: "guzel bir gün ")
        doc.hostSelects("guzel")
        c.handleSelection("guzel", into: doc)

        let before = c.calibration.sampleCount
        c.pickSuggestion("güzel", into: doc)

        XCTAssertEqual(doc.text, "güzel bir gün ")
        XCTAssertEqual(c.calibration.sampleCount, before,
                       "seçim düzenlemesi kalibrasyon öğretmemeli")
    }

    /// Seçim düzenlemesi ayırıcı **eklemez** — zaten belgede.
    func testSelectionEditAddsNoSeparator() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)
        XCTAssertEqual(doc.text, "kalem kalan ")

        doc.hostSelects("kalem")
        c.handleSelection("kalem", into: doc)
        c.pickSuggestion("işlem", into: doc)
        XCTAssertEqual(doc.text, "işlem kalan ", "fazladan boşluk olmamalı")
    }

    // MARK: - Kalibrasyon öğrenmesi

    /// Normal commit **zayıf** etiket üretir (plan §3).
    func testNormalCommitCollectsWeakSamples() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.space(into: doc)

        XCTAssertEqual(c.calibration.sampleCount, 5)
        XCTAssertEqual(c.calibration.strongCount, 0, "otomatik commit zayıftır")
    }

    /// Öneriye dokunmak **güçlü** etiket üretir — ama yalnız seçilen kelime
    /// literal'e eşitse (döngüsellik koruması).
    func testTappingTheLiteralAsASuggestionCollectsStrongSamples() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.pickSuggestion("kalem", into: doc)

        XCTAssertEqual(c.calibration.strongCount, 5)
    }

    /// Farklı bir aday seçilirse hizalama kayda dayanmaz → hiçbir şey öğrenilmez.
    func testTappingADifferentSuggestionTeachesNothing() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalen", &c, doc)
        c.pickSuggestion("kalem", into: doc)

        XCTAssertEqual(c.calibration.sampleCount, 0,
                       "literal ≠ commit → yazım hatası öğretilmemeli")
    }

    /// Eşik dolunca çağırana "kaydet" sinyali verilir.
    func testSaveIsRequestedAfterEnoughSamples() throws {
        var c = try makeCoordinator()
        c.saveEvery = 10
        let doc = Doc()
        XCTAssertFalse(c.wantsCalibrationSave)
        for _ in 0..<3 { type("kalem", &c, doc); c.space(into: doc) }
        XCTAssertTrue(c.wantsCalibrationSave)

        c.calibrationSaved()
        XCTAssertFalse(c.wantsCalibrationSave)
        XCTAssertEqual(c.samplesSinceSave, 0)
    }

    // MARK: - Motor yokken

    /// Paket yüklenmeden de yazılabilmeli (§11.A iki aşamalı init).
    func testTypingWorksBeforeTheEngineIsLoaded() {
        var c = InputCoordinator(layout: layout)
        let doc = Doc()
        type("kalem", &c, doc)
        XCTAssertEqual(doc.text, "kalem")
        XCTAssertTrue(c.candidates().isEmpty)

        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalem ", "motor yokken düzeltme denenmemeli")
    }

    // MARK: - Geri silme ve geri dönüş

    func testBackspaceIntoThePreviousWordRestoresEvidence() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc); c.space(into: doc)

        c.backspaceTap(into: doc)
        XCTAssertEqual(doc.text, "kalem", "yalnız boşluk silinmeli")
        XCTAssertEqual(c.session.literal, "kalem")
        XCTAssertEqual(c.session.touches.count, 5)
    }

    func testWordDeleteRemovesAWholeWord() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)

        c.deleteWord(into: doc)
        XCTAssertEqual(doc.text, "kalem ")
    }

    // MARK: - Dil durumu

    /// Commit edilen kelimenin dili oturuma yazılır ve **sonraki** token'da
    /// geçerli olur (§5b token sınırı kuralı).
    func testCommittedLanguageIsRemembered() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.engine?.decoder.languageModel.previous, 0)
    }

    /// Seçim düzenlemesi dil durumunu **taşımaz**: geçmişteki bir kelimeyi
    /// düzeltmek "son yazılan kelime" değil.
    func testSelectionEditDoesNotMoveTheLanguageState() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)

        doc.hostSelects("kalem")
        c.handleSelection("kalem", into: doc)
        let before = c.engine?.decoder.languageModel.previous
        c.pickSuggestion("işlem", into: doc)
        XCTAssertEqual(c.engine?.decoder.languageModel.previous, before)
    }

    // MARK: - İmleç hareketi

    /// §8.4: imleç hareketi geçmişi silmemeli, yoksa çift dokunuşun ikinci
    /// yarısı eşleşecek kanıt bulamıyordu.
    func testCursorMovePreservesHistory() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        for w in ["kalem", "kalan", "güzel"] { type(w, &c, doc); c.space(into: doc) }
        XCTAssertEqual(c.session.historyDepth, 3)

        doc.hostSelects("kalem")          // imleç metnin başına gitti
        c.handleSelection(nil, into: doc) // henüz seçim okunmadı: imleç hareketi
        XCTAssertEqual(c.session.historyDepth, 3)

        c.handleSelection("kalem", into: doc)
        XCTAssertTrue(c.session.isEditingSelection)
        XCTAssertTrue(c.session.selectionHasRealEvidence,
                      "kendi yazdığımız kelimede gerçek kanıt kullanılmalı")
    }
}
