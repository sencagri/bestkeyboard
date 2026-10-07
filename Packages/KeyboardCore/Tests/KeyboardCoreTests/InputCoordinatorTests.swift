import XCTest
import Foundation
import KBFoundation
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

    /// Seçim ve host müdahalesi destekleyen belge — oturum testleriyle ortak.
    private typealias Doc = FakeDocument

    private func engine(_ counts: [String: Double]) throws -> InputCoordinator.Engine {
        try TestLexicon.engine(counts, layout: layout)
    }

    private func makeCoordinator(_ counts: [String: Double] = ["kalem": 900, "işlem": 1500,
                                                              "kalan": 700, "güzel": 800])
        throws -> InputCoordinator {
        try TestLexicon.coordinator(counts, layout: layout)
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

    // MARK: - Commit raporu (§12.1 — karar teşhisi ve tekrarlanabilir test)

    /// Rapor, klavyenin kararını **gerekçesiyle** taşımalı: düzeltme
    /// uygulandıysa `Δ` ve `θ` dolu olmalı ve `Δ > θ` tutmalı.
    func testAutocorrectReportCarriesTheDecisionItMade() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("lslem", &c, doc)
        let r = c.space(into: doc)

        XCTAssertEqual(r.kind, .autocorrect)
        XCTAssertEqual(r.literal, "lslem")
        XCTAssertEqual(r.displayBefore, "lslem")
        XCTAssertEqual(r.committed, "kalem")
        XCTAssertEqual(r.bestWord, "kalem")
        XCTAssertEqual(r.touchCount, 5)
        guard let d = r.delta, let t = r.theta else {
            return XCTFail("düzeltme uygulandı ama Δ/θ kaydedilmemiş")
        }
        XCTAssertGreaterThan(d, t, "Δ > θ olmadan düzeltme uygulanamaz")
    }

    /// Düzeltme YAPILMADIĞINDA da karar verilmiştir; `Δ` ve `θ` yine kayıtlı
    /// olmalı. "Neden düzeltmedi" sorusu ancak böyle yanıtlanır — kullanıcının
    /// asıl sorduğu soru bu.
    func testCleanWordReportsWhyItWasNotCorrected() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        let r = c.space(into: doc)

        XCTAssertEqual(r.kind, .literal)
        XCTAssertEqual(r.committed, "kalem")
        XCTAssertEqual(r.literal, "kalem")
        // En iyi aday literal'in kendisiyse karar noktası hiç kurulmaz
        // (`best.word == display` erken çıkışı) — o durumda Δ/θ yok, ve bu
        // "ölçülmedi" demek, "sıfır" demek değil.
        if let d = r.delta, let t = r.theta { XCTAssertLessThanOrEqual(d, t) }
    }

    /// Büyük harf düzeltme DEĞİLDİR. `Ali` yazılırken literal `ali`, display
    /// `Ali` olur; `committed != literal` bakarak "otomatik düzeltme oldu"
    /// demek yanlış olurdu.
    func testCasingIsNotReportedAsAutocorrect() throws {
        var c = try makeCoordinator(["ali": 900, "kalem": 900])
        let doc = Doc()
        typeShifted("ali", uppercaseFirst: true, &c, doc)
        let r = c.space(into: doc)

        XCTAssertNotEqual(r.kind, .autocorrect)
        XCTAssertEqual(r.literal, "ali")
        XCTAssertEqual(r.committed, "Ali")
        XCTAssertTrue(r.casingApplied)
    }

    /// Öneriye dokunmak bir eşik kararı değildir — `Δ`/`θ` yazmak, verilmemiş
    /// bir kararı verilmiş göstermek olurdu.
    func testSuggestionPickIsReportedWithoutAThresholdDecision() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("lslem", &c, doc)
        let r = c.pickSuggestion("kalan", into: doc)

        XCTAssertEqual(r.kind, .suggestion)
        XCTAssertEqual(r.committed, "kalan")
        XCTAssertEqual(r.literal, "lslem")
        XCTAssertNil(r.delta)
        XCTAssertNil(r.theta)
    }

    /// Boş token'da commit yoktur; rapor bunu `.empty` ile söylemeli ki
    /// "boşluğa bastım ama bir şey olmadı" ile "boşluk hiç gelmedi" ayrılabilsin.
    func testSpaceOnEmptyTokenReportsEmpty() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        let r = c.space(into: doc)
        XCTAssertEqual(r.kind, .empty)
        XCTAssertEqual(r.touchCount, 0)
    }

    /// Sembolle kapatmada düzeltme **hiç denenmez**; rapor da öyle demeli.
    func testSymbolCommitReportsNoCorrectionAttempt() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("lslem", &c, doc)
        let r = c.insertSymbol(".", into: doc)

        XCTAssertEqual(r.kind, .literal)
        XCTAssertEqual(r.committed, "lslem", "sembol düzeltme yapmamalı")
        XCTAssertNil(r.delta)
    }

    /// Rapor eklemek **davranışı değiştirmemeli** — üretim çağrı yerleri
    /// sonucu yok sayıyor ve sonuç aynı olmalı.
    func testReportingDoesNotChangeWhatIsWritten() throws {
        var a = try makeCoordinator(); let da = Doc()
        type("lslem", &a, da); a.space(into: da)

        var b = try makeCoordinator(); let db = Doc()
        type("lslem", &b, db); _ = b.space(into: db)

        XCTAssertEqual(da.text, db.text)
        XCTAssertEqual(da.text, "kalem ")
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
            XCTAssertTrue(CorrectionPolicy.isProtectedToken(t), t)
        }
        for t in ["kalem", "güzel", "islem"] {
            XCTAssertFalse(CorrectionPolicy.isProtectedToken(t), t)
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
        c.correction.oovTheta = 0
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.space(into: doc, fieldProtectsLiteral: true)
        XCTAssertEqual(doc.text, "kalen ", "korumalı alanda düzeltme olmamalı")
    }

    /// Kontrol grubu: aynı girdi, aynı eşik, koruma kapalı → düzeltilir.
    /// Bu ikisi birlikte olmadan koruma testi bir şey kanıtlamaz.
    func testTheSameInputIsCorrectedWhenTheFieldDoesNotProtect() throws {
        var c = try makeCoordinator()
        c.correction.oovTheta = 0
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

// MARK: - Büyük harf ve semboller

extension InputCoordinatorTests {

    private func typeShifted(_ literal: String, uppercaseFirst: Bool,
                             allCaps: Bool = false,
                             _ c: inout InputCoordinator, _ doc: Doc) {
        for (i, ch) in literal.enumerated() {
            guard let k = layout.keyIndex(for: ch) else { continue }
            let t = TouchSample(down: layout.keys[k].center, timestamp: 0)
            let up = allCaps || (uppercaseFirst && i == 0)
            if up {
                c.insertUppercaseLetter(ch, uppercase: TurkishText.uppercased(ch),
                                        touch: t, into: doc)
            } else {
                c.insertLetter(ch, touch: t, into: doc)
            }
        }
    }

    /// **Codex'in yakaladığı hata.** `Kslem` boşlukta `kalem`'e çevrilip büyük
    /// harf sessizce kayboluyordu. Kullanıcı shift'e bastıysa bu bir niyet
    /// beyanıdır; düzeltme onu ezmemeli.
    func testCorrectionPreservesTheLeadingCapital() throws {
        var c = try makeCoordinator()
        c.correction.oovTheta = 0                       // düzeltme kesin uygulansın
        let doc = Doc()
        typeShifted("kalen", uppercaseFirst: true, &c, doc)
        XCTAssertEqual(doc.text, "Kalen")

        c.space(into: doc)
        XCTAssertEqual(doc.text, "Kalem ", "büyük harf korunmalı")
    }

    /// Caps-lock ile yazılmış token düzeltilirken de biçim korunur.
    func testCorrectionPreservesAllCaps() throws {
        var c = try makeCoordinator()
        c.correction.oovTheta = 0
        let doc = Doc()
        typeShifted("kalen", uppercaseFirst: false, allCaps: true, &c, doc)
        XCTAssertEqual(doc.text, "KALEN")

        c.space(into: doc)
        XCTAssertEqual(doc.text, "KALEM ", "caps-lock biçimi korunmalı")
    }

    /// Küçük harfle yazılmışsa aday da küçük kalır.
    func testLowercaseInputStaysLowercase() throws {
        var c = try makeCoordinator()
        c.correction.oovTheta = 0
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "kalem ")
    }

    /// Türkçe büyük harf: `i → İ`, `ı → I`.
    func testTurkishUppercasing() {
        XCTAssertEqual(TurkishText.uppercased("i"), "İ")
        XCTAssertEqual(TurkishText.uppercased("ı"), "I")
        XCTAssertEqual(TurkishText.uppercased("ç"), "Ç")
    }

    /// Büyük harf `touches.count == literal.count` değişmezini bozmamalı:
    /// kanıt küçük harf tuşuna ait.
    func testUppercaseKeepsTheEvidenceInvariant() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeShifted("kalem", uppercaseFirst: true, &c, doc)
        XCTAssertEqual(c.session.touches.count, c.session.literal.count)
        XCTAssertEqual(c.session.literal, "kalem", "kanıt küçük harf")
        XCTAssertEqual(c.session.display, "Kalem")
    }

    // MARK: Semboller

    /// Sembol token'ı kapatır ve ayırıcı **eklemez** — sembolün kendisi sınır.
    func testSymbolClosesTheTokenWithoutASeparator() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.insertSymbol(".", into: doc)
        XCTAssertEqual(doc.text, "kalem.")
        XCTAssertFalse(c.session.isComposing)
    }

    /// **Codex'in yakaladığı hata.** `kelime.` biçimindeki her kullanım
    /// kalıcı öğrenmeyi ve dil bağlamını kaybediyordu.
    func testSymbolCommitStillLearnsAndRemembersLanguage() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.insertSymbol(".", into: doc)

        XCTAssertEqual(c.calibration.sampleCount, 5,
                       "noktalama ile kapanan kelime de kalibrasyona girmeli")
        XCTAssertEqual(c.engine?.decoder.languageModel.previous, 0,
                       "dil bağlamı güncellenmeli")
    }

    /// Sembol düzeltme **yapmaz**: kullanıcı kelimeyi noktalamayla kapattı,
    /// niyeti boşluktan daha kesin.
    func testSymbolDoesNotAutoCorrect() throws {
        var c = try makeCoordinator()
        c.correction.oovTheta = 0
        let doc = Doc()
        typeWithDrift("kalen", driftingTo: "m", &c, doc)
        c.insertSymbol(".", into: doc)
        XCTAssertEqual(doc.text, "kalen.", "noktalama düzeltme tetiklememeli")
    }

    func testSymbolWithNoActiveTokenJustInserts() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        c.insertSymbol("(", into: doc)
        XCTAssertEqual(doc.text, "(")
    }
}

// MARK: - Seçim kipinde büyük harf ve sembol

extension InputCoordinatorTests {

    /// Seçili yüzeyin büyük harf biçimi de korunmalı.
    func testSelectionEditPreservesCasingOnSuggestionTap() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeShifted("kalem", uppercaseFirst: true, &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)
        XCTAssertEqual(doc.text, "Kalem kalan ")

        doc.hostSelects("Kalem")
        c.handleSelection("Kalem", into: doc)
        c.pickSuggestion("işlem", into: doc)
        XCTAssertEqual(doc.text, "İşlem kalan ", "seçimde de büyük harf korunmalı")
    }

    /// Boşlukla commit edilen seçimde de aynı koruma.
    func testSelectionEditPreservesCasingOnSpace() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        // Kurulum varsayılan eşikle: `θ = 0` olsaydı ilk boşluk zaten
        // düzeltirdi ve test kendi kurduğu durumu ölçemezdi.
        typeShifted("kalen", uppercaseFirst: true, &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)
        XCTAssertEqual(doc.text, "Kalen kalan ")
        c.correction.oovTheta = 0

        doc.hostSelects("Kalen")
        c.handleSelection("Kalen", into: doc)
        // `guard ... else { return }` testi sessizce geçirirdi: gerçek kanıt
        // bulunamazsa düzeltme zaten denenmez ve iddia hiç sınanmaz.
        XCTAssertTrue(c.session.selectionHasRealEvidence,
                      "kendi yazdığımız kelimede gerçek kanıt olmalı")
        c.space(into: doc)
        XCTAssertEqual(doc.text, "Kalem kalan ")
    }

    /// **Codex'in yakaladığı hata.** Seçim aktifken sembol basmak: host
    /// `insertText`'i seçimin YERİNE koyar, yani seçili kelime sembolle
    /// değişir. Oturum bunu commit sanmamalı.
    func testSymbolWhileASelectionIsActiveReplacesIt() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc); c.space(into: doc)
        type("kalan", &c, doc); c.space(into: doc)

        doc.hostSelects("kalem")
        c.handleSelection("kalem", into: doc)
        let before = c.calibration.sampleCount

        c.insertSymbol("!", into: doc)
        XCTAssertEqual(doc.text, "! kalan ", "seçim sembolle değişmeli")
        XCTAssertFalse(c.session.isEditingSelection)
        XCTAssertEqual(c.calibration.sampleCount, before,
                       "silinen kelime kalibrasyona girmemeli")
    }
}

// MARK: - Gayrıresmî katman (§4.B / §4.D)

extension InputCoordinatorTests {

    private func informalEngine() throws -> InputCoordinator.Engine {
        // Resmî + gayrıresmî iki AYRI kaynak, aynı dil.
        let formal = ["selam": 5000, "merhaba": 4000, "tamam": 6000, "cok": 100.0]
        let informal: [String: Double] = ["slm": 9000, "mrb": 4000, "tmm": 9000, "nbr": 7000]

        let trie = TestLexicon.formTrie
        // Gayrıresmî formlar **tek trie'de** birleşik: iki ayrı kaynak §7 tek
        // sahiplik kuralını ihlal ediyordu (aynı yüzey iki listede, farklı
        // toplamlara göre normalize edilmiş, maliyetleri karşılaştırılamaz).
        // `packbuild --informal` birleştirmeyi yapıyor ve çakışmayı derleme
        // hatası sayıyor.
        var merged = formal
        for (k, v) in informal {
            XCTAssertNil(merged[k], "test verisinde çakışma olmamalı: \(k)")
            merged[k] = v
        }
        let lex = LexiconSet(sources: [.forms(try trie(merged), language: 0)])
        let model = try CharNGramBuilder.build(words: Array(formal.keys) + Array(informal.keys))
        var ch = LiteralChannel(vocabulary: lex, charModel: model)
        ch.autoCorrectsOutOfVocabulary = true
        return .init(decoder: Decoder(layout: layout, spatial: SpatialModel(layout: layout),
                                      lexicon: lex, beamWidth: 128),
                     literalChannel: ch,
                     expansions: ExpansionMap(entries: [("slm", "selam"), ("mrb", "merhaba"),
                                                        ("tmm", "tamam"), ("nbr", "ne haber")]))
    }

    /// **Plan §4.B'nin kuralı.** Gayrıresmî formlar asla otomatik olarak resmî
    /// karşılığına çevrilmez: `slm` yazan `slm` demek istemiştir. Kısaltma bir
    /// üslup tercihidir, yazım hatası değil.
    func testInformalFormIsNeverAutoExpanded() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        c.correction.oovTheta = 0                  // düzeltme baskısı en yüksek
        let doc = Doc()
        type("slm", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(doc.text, "slm ", "kısaltma korunmalı")
    }

    /// Açılım yine de **ek öneri** olarak sunulur (§4.D).
    func testExpansionIsOfferedAsAnExtraSuggestion() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("slm", &c, doc)

        let shown = c.suggestionSurfaces()
        XCTAssertTrue(shown.contains("selam"), "açılım önerilmeli: \(shown)")
        XCTAssertEqual(shown.first, "slm", "ama kazanan kısaltma olmalı")
    }

    /// Açılım **kullanıcının yazdığı** yüzeyden aranır, düzeltilmiş adaydan
    /// değil.
    func testExpansionIsLookedUpFromWhatTheUserTyped() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("tmm", &c, doc)
        XCTAssertTrue(c.suggestionSurfaces().contains("tamam"))
    }

    /// Açılımı olmayan kelimede fazladan bir şey çıkmaz.
    func testWordWithoutAnExpansionGetsNoExtra() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("selam", &c, doc)
        XCTAssertFalse(c.suggestionSurfaces().contains("ne haber"))
    }

    /// Kullanıcı açılıma **dokunursa** uygulanır — karar onun.
    func testTappingAnExpansionApplies() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("slm", &c, doc)
        c.pickSuggestion("selam", isExpansion: true, into: doc)
        XCTAssertEqual(doc.text, "selam ")
    }

    /// **Öneri kimliği ve kaynağı motordan geliyor.**
    ///
    /// UI yalnız `[String]` alıyor ve dokunulan yüzey için `id = yüzey`,
    /// `origin = .candidate` **uyduruyordu**. `slm → selam` bir sıralama adayı
    /// değil kısaltma açılımı; kayıt onu aday seçimi diye anlatıyordu ve metin
    /// doğru çıktığı için hiçbir test görmüyordu.
    func testSuggestionCarriesItsIdentityAndOrigin() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("slm", &c, doc)

        let shown = c.suggestions()
        XCTAssertEqual(shown.map(\.surface), c.suggestionSurfaces(),
                       "iki yüzey listesi ayrışamaz")
        let expansion = try XCTUnwrap(shown.first { $0.surface == "selam" })
        XCTAssertEqual(expansion.id, "expansion:selam")
        guard case let .expansion(trigger) = expansion.origin else {
            return XCTFail("genişletme kaynağı bekleniyordu: \(expansion.origin)")
        }
        XCTAssertEqual(trigger, "slm", "tetikleyici kullanıcının YAZDIĞI yüzey")

        // Kontrol: aynı listedeki decoder adayı `candidate` kaynağı taşıyor.
        let candidate = try XCTUnwrap(shown.first { $0.surface == "slm" })
        guard case let .candidate(id) = candidate.origin else {
            return XCTFail("aday kaynağı bekleniyordu: \(candidate.origin)")
        }
        XCTAssertEqual(id, candidate.id)
        XCTAssertTrue(id.hasPrefix("slm#"), "aday kimliği word#source")
    }

    /// Genişletme commit'i **kendi türüyle** kaydediliyor.
    ///
    /// Şemada `.expansion` zaten vardı ama runtime onu hiç üretmiyordu.
    func testExpansionCommitHasItsOwnKind() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        type("slm", &c, doc)
        XCTAssertEqual(c.pickSuggestion("selam", isExpansion: true, into: doc).kind,
                       .expansion)

        let doc2 = Doc()
        type("slm", &c, doc2)
        XCTAssertEqual(c.pickSuggestion("slm", into: doc2).kind, .suggestion,
                       "aday seçimi genişletme değil")
    }

    /// Gayrıresmî formun **yazım hatası** düzeltilebilmeli: `slm` sözlükte
    /// olduğu için `sln` ona dönebilir.
    func testTypoOfAnInformalFormIsCorrectable() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        let doc = Doc()
        XCTAssertEqual(c.candidates(topK: 3).count, 0)
        type("sln", &c, doc)
        XCTAssertTrue(c.candidates(topK: 3).map(\.word).contains("slm"),
                      "kısaltmanın typo'su ona dönebilmeli")
    }

    /// Genişletme haritası yoksa hiçbir şey kırılmaz.
    func testMissingExpansionMapIsHarmless() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        XCTAssertFalse(c.suggestionSurfaces().isEmpty)
    }
}

// MARK: - Genişletme haritası paketi

final class ExpansionMapTests: XCTestCase {

    func testRoundTripPreservesEveryEntry() throws {
        let entries = [("slm", "selam"), ("nbr", "ne haber"), ("kib", "kendine iyi bak")]
        let m = ExpansionMap(entries: entries)
        let back = try ExpansionMap(packData: Data(m.packBytes()))
        for (k, v) in entries { XCTAssertEqual(back.expansions(of: k), [v]) }
    }

    /// Aynı girdi **aynı** binary'yi üretmeli: sözlük sırası çalışmadan
    /// çalışmaya değişir ve yeniden üretilebilirliği bozardı.
    func testPackingIsDeterministic() {
        let e = [("b", "iki"), ("a", "bir"), ("c", "üç")]
        XCTAssertEqual(ExpansionMap(entries: e).packBytes(),
                       ExpansionMap(entries: e.reversed()).packBytes())
    }

    func testMultipleExpansionsForOneKey() {
        let m = ExpansionMap(entries: [("sa", "selam"), ("sa", "selamünaleyküm")])
        XCTAssertEqual(m.expansions(of: "sa"), ["selam", "selamünaleyküm"])
    }

    /// §7 kanonik yüzey kimliği: ayrık yazılmış `ç` aynı girdiyi bulmalı.
    func testLookupIsNFCNormalized() {
        let m = ExpansionMap(entries: [("çk", "çok")])
        XCTAssertEqual(m.expansions(of: "c\u{327}k"), ["çok"])
    }

    func testUnknownKeyReturnsEmpty() {
        XCTAssertTrue(ExpansionMap(entries: [("a", "bir")]).expansions(of: "z").isEmpty)
    }

    func testCorruptedChecksumIsRejected() throws {
        var b = ExpansionMap(entries: [("slm", "selam")]).packBytes()
        b[ExpansionMap.container.headerSize] ^= 0xFF
        XCTAssertThrowsError(try ExpansionMap(packData: Data(b)))
    }

    func testTruncatedPackIsRejected() {
        let b = ExpansionMap(entries: [("slm", "selam")]).packBytes()
        XCTAssertThrowsError(try ExpansionMap(packData: Data(b.prefix(b.count - 2))))
    }

    /// Fazlalık bayt aynı içeriğin ikinci temsilini doğururdu.
    func testTrailingBytesAreRejected() {
        var b = ExpansionMap(entries: [("slm", "selam")]).packBytes()
        b.append(contentsOf: [0, 0])
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in ExpansionMap.container.headerSize..<b.count { h ^= UInt64(b[i]); h = h &* 0x0000_0100_0000_01B3 }
        for i in 0..<8 { b[16 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        XCTAssertThrowsError(try ExpansionMap(packData: Data(b)))
    }

    func testBadMagicIsRejected() {
        var b = ExpansionMap(entries: [("slm", "selam")]).packBytes()
        b[0] = 0
        XCTAssertThrowsError(try ExpansionMap(packData: Data(b)))
    }
}

// MARK: - Genişletme slotu ve tekrar sınıfı

extension InputCoordinatorTests {

    /// **Codex'in yakaladığı hata.** Genişletme sona eklenip `prefix(limit)`
    /// uygulanınca, üç decoder adayı pencere içinde kaldığında açılım tamamen
    /// kesiliyordu: `.bkx` girdisi var ama kullanıcı hiç görmüyordu.
    func testExpansionSurvivesWhenTheListIsFull() throws {
        var c = InputCoordinator(layout: layout)
        c.setEngine(try informalEngine())
        c.suggestionWindow = 1000        // her aday pencerede kalsın
        let doc = Doc()
        type("slm", &c, doc)

        let shown = c.suggestionSurfaces(limit: 3)
        XCTAssertTrue(shown.contains("selam"),
                      "liste dolu olsa da açılım için slot ayrılmalı: \(shown)")
        XCTAssertEqual(shown.first, "slm", "kazanan yine kısaltma")
        XCTAssertLessThanOrEqual(shown.count, 3)
    }

    /// Açılım yokken decoder adayları tüm slotları kullanır.
    func testWithoutExpansionAllSlotsGoToCandidates() throws {
        var c = try makeCoordinator()
        c.suggestionWindow = 1000
        let doc = Doc()
        type("kalem", &c, doc)
        XCTAssertEqual(c.suggestionSurfaces(limit: 3).count,
                       min(3, c.shownCandidates().count))
    }

    // MARK: - Türetilmiş kanıt: erişilebilirlik etkinleştirmesi (§8.9)

    /// Erişilebilirlik yolunun yazışı: **aynı** noktalar, ama gözlem değil.
    ///
    /// `type` ile tıpatıp aynı koordinatları kullanıyor olması tesadüf değil,
    /// testin kendisi: iki yol arasındaki tek fark bayrak. Fark davranışta
    /// çıkıyorsa sebebi bayraktır, koordinat değil.
    private func typeSynthetically(_ word: String, _ c: inout InputCoordinator,
                                   _ doc: Doc) {
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            c.insertLetter(ch, touch: TouchSample(down: layout.keys[k].center,
                                                  timestamp: 0),
                           synthetic: true, into: doc)
        }
    }

    /// **Kanonik vakanın negatifi.** Aynı dokunmalar parmakla gelince `lslem`
    /// `kalem`e düzeltiliyor (`testAutocorrectReportCarriesTheDecisionItMade`);
    /// VoiceOver'la gelince düzeltilmemeli.
    ///
    /// Sebep §8.9'da: kullanıcı her tuşu **duyarak** seçti, fat-finger diye bir
    /// şey yok. Düzeltmek, verilmemiş bir hatayı düzeltmek olurdu.
    func testSyntheticEvidenceIsNeverAutocorrected() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("lslem", &c, doc)
        let r = c.space(into: doc)

        XCTAssertEqual(r.kind, .literal)
        XCTAssertEqual(r.committed, "lslem")
        XCTAssertEqual(doc.text, "lslem ")
        // Karar **hiç sorulmadı**: `θ = ∞` yazmak, sorulmuş ve korumaya
        // düşmüş bir karar anlatmak olurdu.
        XCTAssertNil(r.delta)
        XCTAssertNil(r.theta)
    }

    /// Öneri **görünmeye devam ediyor**. Kapatılan tek şey otomatik uygulama;
    /// kullanıcı adaya dokunabilmeli — seçim kipindeki türetilmiş kanıtla aynı
    /// asimetri (§8.4).
    func testSyntheticEvidenceStillProducesSuggestions() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("lslem", &c, doc)
        XCTAssertEqual(c.candidates(topK: 1).first?.word, "kalem")
    }

    /// Kullanıcı öneriye dokunursa **uygulanıyor**: yasak olan otomatik karar,
    /// kullanıcının kendi kararı değil.
    func testSyntheticEvidenceAcceptsAnExplicitPick() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("lslem", &c, doc)
        let r = c.pickSuggestion("kalem", into: doc)
        XCTAssertEqual(r.kind, .suggestion)
        XCTAssertEqual(doc.text, "kalem ")
    }

    /// **Asıl koruma.** Sentetik dokunmanın sapması tanım gereği sıfır; onları
    /// öğrenmek kullanıcının gerçek parmak sapmasını sıfıra çekerdi (§8.1.1).
    func testSyntheticEvidenceProducesNoCalibrationSamples() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("kalem", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.calibration.sampleCount, 0)
    }

    /// Aynı kelime parmakla yazılınca örnek **üretiyor**. Bir önceki testin
    /// sıfırı, mekanizmanın hiç çalışmamasından değil bayraktan geliyor.
    func testRealEvidenceStillProducesCalibrationSamples() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.space(into: doc)
        XCTAssertGreaterThan(c.calibration.sampleCount, 0)
    }

    /// Öneri seçimi **güçlü** etiket üretiyor ama sentetikte yine öğrenilmiyor:
    /// hedefin kesin bilinmesi koordinatı gerçek yapmıyor.
    func testExplicitPickDoesNotLaunderSyntheticEvidence() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("kalem", &c, doc)
        c.pickSuggestion("kalem", into: doc)
        XCTAssertEqual(c.calibration.sampleCount, 0)
    }

    /// Leke **token başına**: kelime ortasında VoiceOver açılırsa o token'ın
    /// tamamı düşüyor. §5c asimetrisi bu tarafı seçiyor — bir örnek kaybetmek,
    /// sapmayı kirletmekten ucuz.
    func testMixedEvidenceTaintsTheWholeToken() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        type("kal", &c, doc)
        typeSynthetically("em", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.calibration.sampleCount, 0)
    }

    /// Leke token sınırında **düşüyor**: sonraki kelime parmakla yazılırsa
    /// normal öğreniyor. Kalıcı olsaydı bir kez VoiceOver kullanan kullanıcı
    /// kalibrasyonu bir daha hiç ilerletemezdi.
    func testTaintClearsAtTheTokenBoundary() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("kalem", &c, doc)
        c.space(into: doc)
        type("kalan", &c, doc)
        c.space(into: doc)
        XCTAssertGreaterThan(c.calibration.sampleCount, 0)
    }

    /// Token'a **geri dönülünce** leke de geri geliyor.
    ///
    /// `⌫` ile boşluğu silmek kelimeyi yeniden açıyor ve saklanan dokunmaları
    /// geri yüklüyor. Lekeyi geri yüklemeseydik sentetik yazılmış bir kelime,
    /// geri dönüp yeniden kapatıldığında gerçek gözlem sayılırdı.
    func testReopeningATokenRestoresItsTaint() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        typeSynthetically("kalem", &c, doc)
        c.space(into: doc)
        c.backspaceTap(into: doc)               // boşluk silindi, token açıldı
        XCTAssertTrue(c.session.evidenceIsSynthetic)
        c.space(into: doc)
        XCTAssertEqual(c.calibration.sampleCount, 0)
    }

    // MARK: - Yarım token devri (kaydedici bırakıldığında)

    /// Devralınan yüzey **kopuk**: yazmaya devam ediliyor, düzeltme yok.
    ///
    /// Devir olmadan yedek koordinatör boş başlıyordu ve `kal` yazılmışken
    /// gelen `em` tek başına yargılanıyordu — parçaya uygulanan bir düzeltme.
    func testAdoptedSurfaceKeepsTypingWithoutJudgingTheFragment() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        // Ölen koordinatörün belgeye yazdığı yarım token.
        doc.hostRewrites(to: "lsl")
        c.adoptDetachedSurface("lsl")
        type("em", &c, doc)

        XCTAssertTrue(c.session.isDetached)
        let r = c.space(into: doc)
        XCTAssertEqual(doc.text, "lslem ", "yüzey bozulmadan kapanmalı")
        XCTAssertEqual(r.kind, .literal)
        XCTAssertNil(r.delta, "kopuk token'da karar sorulmaz")
    }

    /// Öneri seçimi **no-op**: kanıt yokken yüzeyin hangi kısmının hangi
    /// dokunmadan geldiği bilinmiyor.
    ///
    /// Devir olmadan `pickSuggestion` yalnız `display.count` kadar siliyordu:
    /// `lsl` + `em` durumunda `kalem` seçmek belgeyi `lslkalem` yapardı.
    func testPickingASuggestionOnAnAdoptedSurfaceIsANoOp() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        doc.hostRewrites(to: "lsl")
        c.adoptDetachedSurface("lsl")
        type("em", &c, doc)

        let r = c.pickSuggestion("kalem", into: doc)
        XCTAssertEqual(doc.text, "lslem", "belge bozulmamalı")
        XCTAssertEqual(r.effect.evidenceStateAfter, .detached)
    }

    /// Devralınan token kalibrasyon örneği üretmiyor: dokunmaları yok.
    func testAdoptedSurfaceProducesNoCalibrationSamples() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        doc.hostRewrites(to: "kal")
        c.adoptDetachedSurface("kal")
        type("em", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.calibration.sampleCount, 0)
    }

    /// Devir bittiğinde klavye **normale dönüyor**: sonraki token tam yetkili.
    func testTheTokenAfterAnAdoptedOneIsFullyJudged() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        doc.hostRewrites(to: "kal")
        c.adoptDetachedSurface("kal")
        type("em", &c, doc)
        c.space(into: doc)

        type("lslem", &c, doc)
        let r = c.space(into: doc)
        XCTAssertEqual(r.kind, .autocorrect)
        XCTAssertEqual(r.committed, "kalem")
    }

    /// Boş yüzey devralınmıyor — kaydedici token sınırında bırakıldığında
    /// devredilecek bir şey yok ve boş bir "kopuk token" kurmak, sonraki
    /// kelimeyi kanıtsız başlatırdı.
    func testAdoptingAnEmptySurfaceDoesNothing() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        c.adoptDetachedSurface("")
        XCTAssertFalse(c.session.isDetached)
        type("lslem", &c, doc)
        XCTAssertEqual(c.space(into: doc).committed, "kalem")
    }

    /// Sentetik token kişisel sözlüğe **kanıt üretmiyor**.
    ///
    /// Ayrı bir kural değil, §8.7'nin kendi kuralının sonucu: kanıt yalnız
    /// *reddedilmiş* düzeltmedir ve burada düzeltme hiç denenmedi. Test kuralın
    /// bu yoldan da geçtiğini sabitliyor.
    func testSyntheticEvidenceTeachesNoPersonalWords() throws {
        var c = try makeCoordinator()
        let doc = Doc()
        for _ in 0..<3 {
            typeSynthetically("zort", &c, doc)
            c.space(into: doc)
        }
        XCTAssertTrue(c.personal.admitted.isEmpty)
        XCTAssertFalse(c.wantsPersonalSave)
    }
}

// MARK: - Tekrar insertion sınıfı (§8.5)

final class RepeatInsertionTests: XCTestCase {

    private let layout = TurkishQ.layout()

    private func touch(_ ch: Character) -> TouchSample {
        TouchSample(down: layout.keys[layout.keyIndex(for: ch)!].center, timestamp: 0)
    }

    /// Yüklem **tek yerde**: decoder ve oracle aynı fonksiyonu çağırıyor.
    /// Ayrı yazılsalardı eşdeğerlik testi ayrışmayı yakalardı — nitekim
    /// yakaladı.
    func testPredicateMatchesTheLastEmittedCharacter() {
        XCTAssertTrue(Decoder.isRepeatInsertion(touch: touch("k"), lastChar: "k",
                                                layout: layout))
        XCTAssertFalse(Decoder.isRepeatInsertion(touch: touch("k"), lastChar: "a",
                                                 layout: layout))
    }

    /// Son emit edilen karakter yoksa tekrar sınıfı devrede değil.
    func testNoLastCharacterMeansNoRepeat() {
        XCTAssertFalse(Decoder.isRepeatInsertion(touch: touch("k"), lastChar: nil,
                                                 layout: layout))
    }

    /// **Ürün kararı, sabitleniyor:** yüklem tam tuş eşitliği arıyor.
    /// `ü` emit edildikten sonra `u` dokunuşları tekrar SAYILMAZ — yani
    /// `guuuzel` uzatması `güzel`e giderken tekrar indirimi almaz.
    /// Eşdeğerlik sınıfını buraya da sokmak, `u`↔`ü` ayrımını taşıyan başka
    /// yerlerle tutarsızlık üretirdi.
    func testEquivalenceClassesDoNotCountAsRepeat() {
        XCTAssertFalse(Decoder.isRepeatInsertion(touch: touch("u"), lastChar: "ü",
                                                 layout: layout))
    }
}
