import XCTest
import KBGeometry
import KBSpatial
@testable import KBRuntime

/// Belge taklidi.
///
/// `insertText`/`deleteBackward` üzerinden bir metin tutar; `contextBeforeInput`
/// gerçek `UITextDocumentProxy` gibi imlecin **öncesini** döndürür. Testler
/// belgeyi doğrudan yazmaz — yalnız oturumun ürettiği düzenlemelerle değişir,
/// yoksa test kendi kendini doğrulardı.
private final class FakeDocument: DocumentEditor {
    private(set) var text: String = ""
    /// Host'un yaptığı, bizim bilmediğimiz değişiklik.
    func hostRewrites(to s: String) { text = s }

    func insertText(_ t: String) {
        // Seçim varken `insertText` seçimi DEĞİŞTİRİR — gerçek proxy böyle.
        if let r = selection {
            text.replaceSubrange(r, with: t)
            selection = nil
        } else {
            text.insert(contentsOf: t, at: cursor)
        }
    }
    func deleteBackward() {
        if let r = selection {
            // Seçim varken silme **seçimin tamamını** siler.
            text.removeSubrange(r)
            selection = nil
        } else if cursor > text.startIndex {
            text.remove(at: text.index(before: cursor))
        }
    }

    /// Seçim bir **aralık**, metin değil: metinle modellemek "aynı kelime iki
    /// kez geçiyor" sorununu gizlerdi — testin yakalaması gereken şey tam da o.
    private var selection: Range<String.Index>?
    private var cursor: String.Index { selection?.lowerBound ?? text.endIndex }

    var contextBeforeInput: String? {
        let full = String(text[text.startIndex..<cursor])
        guard contextWindow > 0, full.count > contextWindow else { return full }
        return String(full.suffix(contextWindow))
    }
    var contextAfterInput: String? {
        String(text[(selection?.upperBound ?? text.endIndex)...])
    }
    var selectedText: String? { selection.map { String(text[$0]) } }

    /// `occurrence`: kaçıncı geçtiği yer seçilsin (0 tabanlı).
    func hostSelects(_ s: String, occurrence: Int = 0) {
        var searchStart = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let r = text.range(of: s, range: searchStart..<text.endIndex) else {
                found = nil; break
            }
            found = r
            searchStart = r.upperBound
        }
        selection = found
    }
    func hostClearsSelection() { selection = nil }

    /// `documentContextBeforeInput`'ın **sınırlı** olduğu durum.
    ///
    /// Gerçek `UITextDocumentProxy` belgenin tamamını vermek zorunda değil; uzun
    /// bir denemede pencere kısalıyor. Sıfır = sınırsız.
    var contextWindow = 0
}

private func touch(_ x: Double, _ y: Double = 0.5) -> TouchSample {
    TouchSample(down: Point(x: x, y: y), timestamp: 0)
}

final class ComposingSessionTests: XCTestCase {

    fileprivate func typeWord(_ word: String, _ s: inout ComposingSession, _ doc: FakeDocument) {
        for (i, ch) in word.enumerated() {
            _ = s.insertLetter(ch, touch: touch(Double(i) / 10.0), into: doc)
        }
    }

    // MARK: - Temel yazım

    func testTypingKeepsThreeViewsInSync() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)

        XCTAssertEqual(doc.text, "kalem")
        XCTAssertEqual(s.literal, "kalem")
        XCTAssertEqual(s.display, "kalem")
        XCTAssertEqual(s.touches.count, 5)
    }

    func testInsertLetterReportsAppendedSoBeamIsNotRebuilt() {
        var s = ComposingSession()
        let doc = FakeDocument()
        XCTAssertEqual(s.insertLetter("a", touch: touch(0.1), into: doc), .appended)
    }

    // MARK: - Otomatik düzeltme sonrası ayrışma

    /// Asıl regresyon: düzeltmeden sonra belgede `kalem`, literal'de `lslm`
    /// duruyor. Silinecek karakter sayısı **belgedeki** yüzeyden okunmalı.
    func testDeleteCountFollowsDisplayNotLiteral() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)                       // 4 harf yazıldı
        s.replaceDisplay(with: "kalem", into: doc)  // 5 harfli yüzeye düzeltildi

        XCTAssertEqual(doc.text, "kalem")
        XCTAssertEqual(s.literal, "lslm")
        XCTAssertEqual(s.touches.count, 4)

        _ = s.backspaceTap(into: doc)
        XCTAssertEqual(doc.text, "kale")            // literal uzunluğu kullanılsaydı taşardı
        XCTAssertEqual(s.display, "kale")
    }

    /// Uzunluklar ayrışmışken silmek konumsal eşlemeyi kurtarılamaz kılar;
    /// kanıt kopar ve token'ın kalanı düz klavye gibi çalışır.
    func testEditingADivergedSurfaceDetachesEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)

        _ = s.backspaceTap(into: doc)
        XCTAssertTrue(s.isDetached)
        XCTAssertTrue(s.touches.isEmpty, "kanıt saklanmamalı")
        XCTAssertEqual(s.literal, "")
        XCTAssertEqual(s.display, "kale", "belgedeki metin korunmalı")
    }

    /// Kanıt koptuktan sonra yazmaya devam etmek belgeyi doğru büyütür ama
    /// decoder'a sahte kanıt vermez.
    func testTypingWhileDetachedDoesNotFabricateEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.backspaceTap(into: doc)               // → kopuk

        _ = s.insertLetter("x", touch: touch(0.5), into: doc)
        XCTAssertEqual(doc.text, "kalex")
        XCTAssertTrue(s.touches.isEmpty)
        XCTAssertEqual(s.literal, "")
    }

    /// Kopuk token geçmişe yazılmaz: yükleyecek kanıtı yok, ama boş kanıt
    /// üzerine yazılan harfler yüzeyin tamamıymış gibi görünüp yanlış
    /// düzeltme üretirdi.
    func testDetachedTokenIsNotRecordedForRestore() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.backspaceTap(into: doc)
        _ = s.finishToken(separator: " ", into: doc)

        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .unchanged, "geri dönüş olmamalı")
        XCTAssertEqual(doc.text, "kale", "yalnız boşluk silinmiş olmalı")
    }

    /// Uzunluklar eşitken (yaygın durum) silme hizayı korur, kanıt kopmaz.
    func testDeletingAnAlignedCorrectionKeepsEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("guzel", &s, doc)
        s.replaceDisplay(with: "güzel", into: doc)

        _ = s.backspaceTap(into: doc)
        XCTAssertFalse(s.isDetached)
        XCTAssertEqual(s.display, "güze")
        XCTAssertEqual(s.literal, "guze")
        XCTAssertEqual(s.touches.count, 4)
    }

    /// Kopuk token tamamen silindiğinde temiz sayfa açılır.
    func testDetachClearsWhenTokenIsFullyDeleted() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("ab", &s, doc)
        s.replaceDisplay(with: "abcde", into: doc)

        for _ in 0..<5 { _ = s.backspaceTap(into: doc) }
        XCTAssertEqual(doc.text, "")
        XCTAssertFalse(s.isDetached)
        XCTAssertFalse(s.isComposing)

        // Yeniden yazınca kanıt normal toplanır.
        _ = s.insertLetter("a", touch: touch(0.1), into: doc)
        XCTAssertEqual(s.touches.count, 1)
        XCTAssertEqual(s.literal, "a")
    }

    /// Değişmez: dokunma `i`, literal karakter `i`'nin kanıtıdır.
    /// `costOfLiteral` bu eşlemeye dayanıyor.
    func testTouchLiteralAlignmentInvariantHoldsThroughEveryOperation() {
        var s = ComposingSession()
        let doc = FakeDocument()

        func check(_ label: String) {
            XCTAssertEqual(s.touches.count, s.literal.count, "değişmez bozuldu: \(label)")
        }

        typeWord("lslm", &s, doc);                          check("yazım")
        s.replaceDisplay(with: "kalem", into: doc);      check("düzeltme")
        _ = s.insertLetter("i", touch: touch(0.4), into: doc); check("düzeltme sonrası ekleme")
        _ = s.backspaceTap(into: doc);                  check("ayrışmış silme")
        _ = s.insertLetter("z", touch: touch(0.6), into: doc); check("kopukken ekleme")
        _ = s.finishToken(separator: " ", into: doc);    check("commit")
        typeWord("iki", &s, doc);                           check("yeni token")
        _ = s.backspaceTap(into: doc);                  check("hizalı silme")
        _ = s.invalidate();                             check("invalidate")
    }

    // MARK: - Boşlukla commit

    func testFinishTokenWritesSeparatorAndClears() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        XCTAssertEqual(s.finishToken(separator: " ", into: doc), .cleared)

        XCTAssertEqual(doc.text, "kalem ")
        XCTAssertFalse(s.isComposing)
        XCTAssertTrue(s.touches.isEmpty)
    }

    // MARK: - Geri dönüş (kullanıcının 3. isteği)

    func testBackspaceIntoPreviousWordRestoresItsTouchEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(doc.text, "kalem ")

        // Boşluğu sil → kelimeye geri dön.
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .rebuilt)

        XCTAssertEqual(doc.text, "kalem", "yalnız boşluk silinmeli, kelime durmalı")
        XCTAssertEqual(s.display, "kalem")
        XCTAssertEqual(s.literal, "lslm", "kanıt kullanıcının bastığı harflerdi")
        XCTAssertEqual(s.touches.count, 4)
        XCTAssertTrue(s.isComposing, "yeni yazıyormuş gibi devam edebilmeli")
    }

    func testTypingContinuesAfterRestore() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        _ = s.backspaceTap(into: doc)

        _ = s.insertLetter("i", touch: touch(0.9), into: doc)
        XCTAssertEqual(doc.text, "kalemi")
        XCTAssertEqual(s.touches.count, 6)
    }

    func testRestoreOnlyReachesBackOneWordPerBackspace() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)

        _ = s.backspaceTap(into: doc)
        XCTAssertEqual(s.display, "iki")
        XCTAssertEqual(doc.text, "bir iki")
    }

    /// Geçmiş yalnız kendi yazdığımız metne dayanır. Host araya girdiyse
    /// eşleşme tutmaz ve normal silmeye düşülür.
    func testRestoreDoesNotFireWhenDocumentDivergedFromHistory() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.hostRewrites(to: "bambaşka ")
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .unchanged)
        XCTAssertEqual(doc.text, "bambaşka")
        XCTAssertFalse(s.isComposing)
    }

    // MARK: - Sınırlı bağlam penceresi

    /// **Uzun belgede atıf kaybolmuyor.**
    ///
    /// `documentContextBeforeInput` belgenin tamamını vermek zorunda değil. Önce
    /// `verifyLedger` sonek karşılaştırmasını tam defter üzerinde yapıyordu:
    /// pencere kısaldığı anda **doğru** bir defter reddediliyor ve atıf sonsuza
    /// dek `.unattributed`'a düşüyordu. Yani özellik uzun oturumlarda — tam da
    /// ölçmek istediğimiz yerde — sessizce kapanıyordu.
    func testAttributionSurvivesABoundedContextWindow() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for i in 0..<12 {
            typeWord("kelime\(i)", &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
        // Pencere son iki kelimeyi görecek kadar; defter on iki kelime anlatıyor.
        doc.contextWindow = 20
        typeWord("son", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        // Ayırıcıyı silmek: pencere içindeki segment, kimliği **korunuyor**.
        let d = s.backspaceTap(into: doc)
        XCTAssertEqual(d.outcome, .rebuilt,
                       "pencere kısa diye geri açma kaybolmamalı")
        XCTAssertEqual(s.display, "son")
    }

    /// Pencerenin **kapsamadığı** segmentler atılıyor: kimliği doğrulanamayan
    /// bir token'a silme atfetmek uydurma olgu olurdu.
    func testDeletionBeyondTheWindowIsUnattributed() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("üç", &s, doc);  _ = s.finishToken(separator: " ", into: doc)

        // Yalnız son üç karakter görünüyor ("üç " ⇒ 3 grapheme).
        doc.contextWindow = 3
        // İlk silme ayırıcıyı alıyor ve "üç"ü geri açıyor; pencere onu kapsıyor.
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .rebuilt)
        // Şimdi composing "üç"; harflerini silip pencerenin ötesine geçiyoruz.
        _ = s.backspaceTap(into: doc)
        _ = s.backspaceTap(into: doc)
        let d = s.backspaceTap(into: doc)
        // Pencerenin dışındaki `iki` kimliğine atıf **yapılmıyor**.
        XCTAssertEqual(d.effect.value?.deleted, [.unattributed],
                       "görünmeyen bölgeye kimlik atanamaz")
    }

    /// Boş bağlam kanıt değil: `hasSuffix("")` her defteri geçirirdi.
    func testEmptyContextClearsTheLedger() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.contextWindow = 0
        doc.hostRewrites(to: "")
        let d = s.backspaceTap(into: doc)
        XCTAssertEqual(d.effect.value?.deleted, [],
                       "boş belgede silinecek bir şey yok")
    }

    func testHistoryDepthIsBounded() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for i in 0..<(ComposingSession.maxHistoryDepth + 4) {
            typeWord("w\(i)", &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
        // En eskiler düşmüş olmalı: son kelimeye dönülür, ilkine dönülemez.
        var restores = 0
        while s.backspaceTap(into: doc).outcome == .rebuilt {
            restores += 1
            while s.isComposing { _ = s.backspaceTap(into: doc) }
            if restores > ComposingSession.maxHistoryDepth + 2 { break }
        }
        XCTAssertLessThanOrEqual(restores, ComposingSession.maxHistoryDepth)
    }

    // MARK: - Tekrar (uzun basma)

    /// Tekrar sırasında geri dönüş **olmamalı** — kullanıcı toplu siliyor.
    func testRepeatDeleteDoesNotRestorePreviousWord() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        _ = s.backspaceRepeat(into: doc)
        XCTAssertEqual(doc.text, "kalem")
        XCTAssertFalse(s.isComposing, "tekrar sırasında kelimeye girilmemeli")
    }

    func testWordDeleteRemovesTrailingSpaceAndWord() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)

        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "bir ")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "")
    }

    func testWordDeleteConsumesComposingTokenWhole() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("yarım", &s, doc)

        XCTAssertEqual(s.deleteWordBackward(into: doc).outcome, .cleared)
        XCTAssertEqual(doc.text, "bir ")
        XCTAssertFalse(s.isComposing)
    }

    /// Satır sonu silme sınırıdır; tek uzun basma birkaç satırı yutmamalı.
    func testWordDeleteStopsAtNewline() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "birinci\nikinci")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "birinci\n")
    }

    /// Regresyon: bağlam satır sonuyla bitince eski kod hiçbir kelime seçemiyor,
    /// "en az bir karakter" düşüşüne takılıp satır sonunu **ve** aynı çağrıda
    /// önceki satırın kelimesini silmeye başlıyordu. Sınırı geçmek bir sonraki
    /// tekrara kalmalı.
    func testWordDeleteAtLineStartRemovesOnlyTheNewline() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "birinci\n")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "birinci")
    }

    /// CRLF Swift'te **tek** `Character`. Eski kod `== "\n"` karşılaştırdığı
    /// için bu dalı hiç görmüyor, satır sonunu kelime silme koluna düşürüyordu.
    func testWordDeleteTreatsCRLFAsASingleBoundary() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "birinci\r\n")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "birinci")
    }

    /// U+2028 gibi satır ayırıcılar da sınırdır.
    func testWordDeleteTreatsUnicodeLineSeparatorAsBoundary() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "birinci\u{2028}")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "birinci")
    }

    /// Kopuk token'a öneri uygulanamaz — kural çağıranın nezaketine bırakılmaz.
    func testReplaceDisplayIsRefusedWhileDetached() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.backspaceTap(into: doc)              // → kopuk, belge "kale"

        XCTAssertFalse(s.replaceDisplay(with: "kalemler", into: doc))
        XCTAssertEqual(doc.text, "kale", "belge değişmemeli")
        XCTAssertEqual(s.display, "kale")
    }

    func testWordDeleteOnBlankLinesPeelsOneNewlineAtATime() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "a\n\n\n")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "a\n\n")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "a\n")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "a")
    }

    func testWordDeleteOnEmptyDocumentIsHarmless() {
        var s = ComposingSession()
        let doc = FakeDocument()
        XCTAssertEqual(s.deleteWordBackward(into: doc).outcome, .unchanged)
        XCTAssertEqual(doc.text, "")
    }

    // MARK: - Host uzlaştırması

    func testAgreesWithHostDetectsDivergence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        XCTAssertTrue(s.agreesWithHost(doc))

        doc.hostRewrites(to: "başka şey")
        XCTAssertFalse(s.agreesWithHost(doc))
    }

    func testEmptySessionWithNoHistoryAlwaysAgrees() {
        let s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "her ne varsa")
        XCTAssertTrue(s.agreesWithHost(doc))
    }

    /// Composing boşken de geçmiş host metnine dair bir iddia taşır.
    /// Doğrulanmazsa host metni değiştikten sonra eski bir kelimenin
    /// dokunmaları yepyeni bir konuma bağlanabilirdi.
    func testHostDivergenceIsDetectedWhileOnlyHistoryIsLive() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        XCTAssertTrue(s.agreesWithHost(doc))

        doc.hostRewrites(to: "bambaşka bir metin")
        XCTAssertFalse(s.agreesWithHost(doc))
    }

    /// Sonek eşleşmesi yetmez: `iki` geçmişteyken belgede `biriki ` durursa
    /// `biriki`nin son üç harfine başka bir kelimenin dokunmaları bağlanırdı.
    func testRestoreRequiresWholeTokenEqualityNotSuffixMatch() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("iki", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.hostRewrites(to: "biriki ")
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .unchanged)
        XCTAssertEqual(doc.text, "biriki", "sonek çakışmasıyla geri dönülmemeli")
        XCTAssertFalse(s.isComposing)
    }

    func testInvalidateDropsEverything() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        typeWord("iki", &s, doc)

        XCTAssertEqual(s.invalidate(), .cleared)
        XCTAssertFalse(s.isComposing)
        // Geçmiş de gitti: geri dönüş yok, düz silme var.
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .unchanged)
    }
}

// MARK: - Seçili kelimeyi düzenleme

extension ComposingSessionTests {

    /// Üç kelime yazıp belgeyi `"bir iki üç "` hâline getirir.
    private func writeThree(_ s: inout ComposingSession, _ doc: FakeDocument) {
        for w in ["bir", "iki", "üç"] {
            typeWord(w, &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
    }

    /// Kullanıcının sorusu: *"geçmiş bir kelimeyi seçtiğim zaman onun state'ini
    /// hatırlayıp ona göre düzeltme öneremiyor mu?"* — yazdığımız ve konumu
    /// doğrulanabilen kelimeler için evet.
    func testSelectingAWordWeTypedRestoresItsTouchEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.finishToken(separator: " ", into: doc)
        typeWord("bir", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(doc.text, "kalem bir ")

        doc.hostSelects("kalem")
        XCTAssertEqual(s.beginEditingSelection("kalem", into: doc), .rebuilt)

        XCTAssertTrue(s.isEditingSelection)
        XCTAssertEqual(s.display, "kalem")
        XCTAssertEqual(s.literal, "lslm", "kanıt kullanıcının bastığı harflerdi")
        XCTAssertEqual(s.touches.count, 4)
    }

    // MARK: Konum doğrulaması

    /// **Asıl güvenlik kapısı.** Aynı kelime iki kez yazıldıysa hangi geçtiği
    /// yerin seçildiğini `selectedText` söylemez; yanlış kanıtı bağlamaktansa
    /// hiç bağlamamak gerekir.
    func testAmbiguousSurfaceIsRejected() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for w in ["kalem", "bir", "kalem"] {
            typeWord(w, &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
        doc.hostSelects("kalem", occurrence: 0)
        XCTAssertEqual(s.beginEditingSelection("kalem", into: doc), .cleared,
                       "iki kez geçen yüzeyde kanıt bağlanmamalı")
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Konum doğrulaması: seçimin ardında beklediğimiz metin durmalı.
    /// Host araya bir şey eklediyse eşleşme reddedilir.
    func testSelectionIsRejectedWhenTheFollowingTextDoesNotMatchHistory() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostRewrites(to: "bir BAŞKA üç ")   // host araya girdi
        doc.hostSelects("bir")

        XCTAssertEqual(s.beginEditingSelection("bir", into: doc), .cleared)
        XCTAssertFalse(s.isEditingSelection)
    }

    func testMiddleWordIsAcceptedWhenTheTailMatches() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")

        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .rebuilt)
        XCTAssertEqual(s.display, "iki")
    }

    /// Biz yazmadığımız bir kelimede uzamsal kanıt yok.
    func testSelectingAWordWeDidNotTypeYieldsNothing() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        doc.hostSelects("kalem")
        doc.hostRewrites(to: "bambaşka ")
        doc.hostSelects("bambaşka")

        XCTAssertEqual(s.beginEditingSelection("bambaşka", into: doc), .cleared)
        XCTAssertFalse(s.isEditingSelection)
        XCTAssertTrue(s.touches.isEmpty)
    }

    func testMultiWordSelectionIsRejected() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        XCTAssertEqual(s.beginEditingSelection("bir iki", into: doc), .cleared)
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Kenarlarda boşluk bırakan seçim **reddedilir**: kabul edip kırpmak,
    /// değiştirme sırasında o boşlukları yok ederdi.
    func testWhitespacePaddedSelectionIsRejected() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(s.beginEditingSelection(" kalem ", into: doc), .cleared)
    }

    /// Tekrarlı geri çağrı durumu bozmamalı.
    func testRepeatedSelectionCallbackIsIdempotent() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")

        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .rebuilt)
        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .unchanged)
        XCTAssertTrue(s.isEditingSelection, "ikinci çağrı durumu temizlememeli")
        XCTAssertEqual(s.display, "iki")
    }

    // MARK: Değiştirme ve commit

    func testReplacingASelectionDoesNotEatPrecedingText() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertTrue(s.replaceDisplay(with: "ikinci", into: doc))
        XCTAssertEqual(doc.text, "bir ikinci üç ", "komşu metin korunmalı")
        XCTAssertFalse(s.isEditingSelection)
    }

    /// **Blocker regresyonu.** `finishToken` çağırmak ayırıcıyı ikinci kez
    /// eklerdi; düzeltme uygulanmadıysa daha kötüsü, `insertText(" ")` seçili
    /// kelimenin tamamını boşlukla değiştirirdi.
    func testCommittingASelectionEditAddsNoSeparator() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertEqual(s.commitSelectionEdit("ikinci", into: doc), .cleared)
        XCTAssertEqual(doc.text, "bir ikinci üç ", "fazladan boşluk olmamalı")
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Düzeltme uygulanmadan commit: seçim olduğu gibi kalmalı.
    func testCommittingWithoutASurfaceLeavesTheSelectionIntact() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertEqual(s.commitSelectionEdit(nil, into: doc), .cleared)
        XCTAssertEqual(doc.text, "bir iki üç ", "kelime bozulmamalı")
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Aynı yüzeyle commit de belgeyi bozmamalı.
    func testCommittingTheSameSurfaceIsHarmless() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        _ = s.commitSelectionEdit("iki", into: doc)
        XCTAssertEqual(doc.text, "bir iki üç ")
    }

    // MARK: Seçim kipinde yazma ve silme

    /// Host `insertText`'i seçimin YERİNE koyar; oturum eski `display` üzerine
    /// eklemeye devam etseydi belge `x` iken oturum `ikix` sanırdı.
    func testTypingWhileASelectionIsActiveStartsAFreshToken() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        _ = s.insertLetter("x", touch: touch(0.5), into: doc)
        XCTAssertEqual(doc.text, "bir x üç ")
        XCTAssertEqual(s.display, "x")
        XCTAssertEqual(s.literal, "x")
        XCTAssertEqual(s.touches.count, 1)
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Seçim varken silme **seçimin tamamını** siler, tek karakteri değil.
    func testBackspaceWhileASelectionIsActiveDeletesTheWholeSelection() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .cleared)
        XCTAssertEqual(doc.text, "bir  üç ")
        XCTAssertFalse(s.isEditingSelection)
        XCTAssertFalse(s.isComposing)
    }

    func testWordDeleteWhileASelectionIsActiveDeletesTheSelection() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertEqual(s.deleteWordBackward(into: doc).outcome, .cleared)
        XCTAssertEqual(doc.text, "bir  üç ")
    }

    // MARK: Host mutabakatı ve geçmiş

    func testHostAgreementUsesTheSelectionWhileEditingIt() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)
        XCTAssertTrue(s.agreesWithHost(doc))

        doc.hostSelects("üç")
        XCTAssertFalse(s.agreesWithHost(doc))
    }

    /// Seçim düzenlemesinden sonra geçmiş **tamamen** atılır: belge sırasını
    /// artık temsil edemez ve kısmi tutmak sonraki geri dönüşün yanlış kelimeyi
    /// hedeflemesine yol açardı.
    func testHistoryIsInvalidatedAfterASelectionEdit() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)
        _ = s.commitSelectionEdit("ikinci", into: doc)

        doc.hostClearsSelection()
        XCTAssertEqual(s.backspaceTap(into: doc).outcome, .unchanged,
                       "geçmişe dayalı geri dönüş artık yapılmamalı")
    }

    func testEndEditingSelectionClearsState() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree(&s, doc)
        doc.hostSelects("iki")
        _ = s.beginEditingSelection("iki", into: doc)

        XCTAssertEqual(s.endEditingSelection(), .cleared)
        XCTAssertFalse(s.isEditingSelection)
        XCTAssertFalse(s.isComposing)
    }

    func testEndEditingSelectionIsANoOpWhenNotEditing() {
        var s = ComposingSession()
        XCTAssertEqual(s.endEditingSelection(), .unchanged)
    }
}

// MARK: - İki taraflı konum doğrulaması

extension ComposingSessionTests {

    private func writeThree2(_ s: inout ComposingSession, _ doc: FakeDocument) {
        for w in ["bir", "iki", "üç"] {
            typeWord(w, &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
    }

    /// Codex'in karşı örneği: host **solu** değiştirirse belgedeki yüzey artık
    /// bizim yazdığımız token olmayabilir. Yalnız sağ bağlamı doğrulamak
    /// başka bir kelimenin kanıtını bağlamaya yol açardı.
    func testLeftContextIsVerifiedToo() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree2(&s, doc)
        // Host `bir`i başka bir şeyle değiştirdi: sağ bağlam hâlâ " üç ".
        doc.hostRewrites(to: "SAHTE iki üç ")
        doc.hostSelects("iki")

        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .cleared,
                       "sol bağlam uyuşmuyorsa kanıt bağlanmamalı")
    }

    /// Görünen pencerede aynı yüzey iki kez varsa hangisinin seçildiği
    /// belirsiz — geçmişte tekil olsa bile.
    func testDuplicateSurfaceInTheDocumentWindowIsRejected() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        typeWord("üç", &s, doc);  _ = s.finishToken(separator: " ", into: doc)
        // Host sona ikinci bir `iki` ekledi.
        doc.hostRewrites(to: "iki üç iki ")
        doc.hostSelects("iki", occurrence: 0)

        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .cleared)
    }

    /// Ayırıcı **kaydedilir**: satır sonuyla kapatılmış kelimeler sabit `" "`
    /// varsayımı yüzünden yanlışlıkla reddediliyordu.
    func testNewlineSeparatedWordsAreStillSelectable() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("bir", &s, doc); _ = s.finishToken(separator: "\n", into: doc)
        typeWord("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(doc.text, "bir\niki ")

        doc.hostSelects("bir")
        XCTAssertEqual(s.beginEditingSelection("bir", into: doc), .rebuilt,
                       "satır sonuyla kapatılmış kelime de seçilebilmeli")
        XCTAssertEqual(s.display, "bir")
    }

    /// Sol bağlam doğru olduğunda kabul edilmeli — kapı fazla katı olmamalı.
    func testCorrectBothSidedContextIsAccepted() {
        var s = ComposingSession()
        let doc = FakeDocument()
        writeThree2(&s, doc)
        doc.hostSelects("üç")
        XCTAssertEqual(s.beginEditingSelection("üç", into: doc), .rebuilt)
        XCTAssertEqual(s.literal, "üç")
    }
}

// MARK: - İmleç hareketi geçmişi korumalı

extension ComposingSessionTests {

    /// **Cihazda bulunan hata.** Kullanıcı bir kelimeye çift dokunduğunda ilk
    /// dokunuş imleci taşıyor; o anda tam `invalidate()` geçmişi siliyordu ve
    /// ikinci dokunuş seçimi oluşturunca eşleşecek kanıt kalmıyordu.
    func testCursorMoveKeepsHistorySoSelectionCanStillMatch() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for w in ["yanş", "beceremem", "doğrusu"] {
            typeWord(w, &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
        XCTAssertEqual(s.historyDepth, 3)

        // 1. dokunuş: imleç başa gitti, tampon host'la uyuşmuyor.
        doc.hostSelects("yanş")          // imleç artık metnin başında
        XCTAssertEqual(s.invalidateComposing(), .cleared)
        XCTAssertEqual(s.historyDepth, 3, "imleç hareketi geçmişi silmemeli")

        // 2. dokunuş: seçim oluştu — kanıt hâlâ orada.
        XCTAssertEqual(s.beginEditingSelection("yanş", into: doc), .rebuilt)
        XCTAssertEqual(s.literal, "yanş")
        XCTAssertEqual(s.touches.count, 4)
    }

    /// Tam `invalidate` hâlâ her şeyi atıyor — satır sonu ve alan değişimi için.
    func testFullInvalidateStillClearsHistory() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(s.historyDepth, 1)

        _ = s.invalidate()
        XCTAssertEqual(s.historyDepth, 0)
    }

    /// Geçmişi korumak güvenli: bayat bir kayıt konum doğrulamasından geçemez.
    func testStaleHistoryIsStillRejectedByPositionVerification() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for w in ["bir", "iki"] {
            typeWord(w, &s, doc); _ = s.finishToken(separator: " ", into: doc)
        }
        _ = s.invalidateComposing()          // geçmiş korunuyor

        // Host metni tamamen değiştirdi.
        doc.hostRewrites(to: "bambaşka iki metin ")
        doc.hostSelects("iki")
        XCTAssertEqual(s.beginEditingSelection("iki", into: doc), .cleared,
                       "bayat kayıt konum doğrulamasından geçmemeli")
    }
}

// MARK: - Türetilmiş kanıtla seçim

extension ComposingSessionTests {

    private func centres(_ word: String) -> [TouchSample] {
        word.enumerated().map { i, _ in touch(Double(i) / 10.0) }
    }

    /// Gerçek kanıt yoksa (uygulama yeniden başladı, kelime geçmişte yok,
    /// ya da onu biz yazmadık) yüzeyden türetilmiş kanıtla yine de öneri
    /// üretilebilmeli — özellik geçmişe bağımlı kalmamalı.
    func testSyntheticEvidenceOpensSelectionEditingWithoutHistory() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "guzel bir gün ")
        doc.hostSelects("guzel")

        XCTAssertEqual(s.historyDepth, 0)
        XCTAssertEqual(s.beginEditingSelection("guzel", into: doc), .cleared)

        XCTAssertEqual(s.beginEditingSelectionSynthetic("guzel", touches: centres("guzel")),
                       .rebuilt)
        XCTAssertTrue(s.isEditingSelection)
        XCTAssertEqual(s.display, "guzel")
        XCTAssertEqual(s.literal, "guzel")
        XCTAssertEqual(s.touches.count, 5)
    }

    /// Türetilmiş kanıt **gerçek gözlem değildir** ve öyle işaretlenmez.
    func testSyntheticEvidenceIsFlaggedAsNotReal() {
        var s = ComposingSession()
        _ = s.beginEditingSelectionSynthetic("guzel", touches: centres("guzel"))
        XCTAssertFalse(s.selectionHasRealEvidence,
                       "türetilmiş kanıt otomatik uygulamaya yetki vermemeli")
    }

    /// Gerçek kanıt bulunduğunda bayrak doğru.
    func testRealEvidenceIsFlaggedAsReal() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for w in ["bir", "iki"] {
            typeWord(w, &s, doc); _ = s.finishToken(separator: " ", into: doc)
        }
        doc.hostSelects("bir")
        XCTAssertEqual(s.beginEditingSelection("bir", into: doc), .rebuilt)
        XCTAssertTrue(s.selectionHasRealEvidence)
    }

    func testSyntheticSelectionRejectsMismatchedTouchCount() {
        var s = ComposingSession()
        XCTAssertEqual(s.beginEditingSelectionSynthetic("guzel", touches: centres("gu")),
                       .cleared)
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Türetilmiş kipte de değiştirme belgeyi bozmamalı.
    func testReplacingASyntheticSelectionWorks() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "guzel bir gün ")
        doc.hostSelects("guzel")
        _ = s.beginEditingSelectionSynthetic("guzel", touches: centres("guzel"))

        XCTAssertTrue(s.replaceDisplay(with: "güzel", into: doc))
        XCTAssertEqual(doc.text, "güzel bir gün ")
    }

    /// Kip kapanınca bayrak da sıfırlanmalı.
    func testFlagResetsWhenSelectionEnds() {
        var s = ComposingSession()
        let doc = FakeDocument()
        doc.hostRewrites(to: "guzel ")
        _ = s.beginEditingSelectionSynthetic("guzel", touches: centres("guzel"))
        _ = s.endEditingSelection()
        XCTAssertFalse(s.selectionHasRealEvidence)
        XCTAssertFalse(s.isEditingSelection)
    }
}

// MARK: - Zayıf bağlam ve boşluklu seçim

extension ComposingSessionTests {

    /// **Boş doğrulama kabul edilmez.** Geçmişte tek girdi varsa `expectedBefore`
    /// boş, `expectedAfter` yalnız ayırıcı — iki taraflı doğrulama fiilen
    /// hiçbir şey kanıtlamaz. Host'un yapıştırdığı aynı görünümlü bir kelime
    /// "bizim yazdığımız" sanılıp eski dokunmalar gerçek kanıt olarak
    /// bağlanabilirdi.
    func testSingleEntryHistoryIsTooWeakToGrantRealEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.hostSelects("kalem")
        XCTAssertEqual(s.beginEditingSelection("kalem", into: doc), .cleared,
                       "tek girdilik geçmiş gerçek kanıt için yeterli değil")
        XCTAssertFalse(s.selectionHasRealEvidence)
    }

    /// Yeterli bağlam varsa gerçek kanıt kabul edilir — kapı fazla katı olmamalı.
    func testSufficientContextStillGrantsRealEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for w in ["bir", "iki", "üç"] {
            typeWord(w, &s, doc); _ = s.finishToken(separator: " ", into: doc)
        }
        doc.hostSelects("bir")
        XCTAssertEqual(s.beginEditingSelection("bir", into: doc), .rebuilt)
        XCTAssertTrue(s.selectionHasRealEvidence)
    }

    /// Türetilmiş yol da boşluklu yüzey kabul etmemeli: aday uygulanırken
    /// `insertText` host'un tüm seçimini değiştirir ve o boşlukları silerdi.
    func testSyntheticSelectionRejectsWhitespacePaddedSurface() {
        var s = ComposingSession()
        XCTAssertEqual(
            s.beginEditingSelectionSynthetic(" guzel ", touches: centres(" guzel ")),
            .cleared)
        XCTAssertFalse(s.isEditingSelection)
    }

    /// Zayıf bağlam reddi türetilmiş yola düşmeyi engellememeli — öneri yine
    /// görünmeli, yalnız otomatik uygulama olmamalı.
    func testWeakContextStillAllowsSyntheticFallback() {
        var s = ComposingSession()
        let doc = FakeDocument()
        typeWord("guzel", &s, doc); _ = s.finishToken(separator: " ", into: doc)

        doc.hostSelects("guzel")
        XCTAssertEqual(s.beginEditingSelection("guzel", into: doc), .cleared)
        XCTAssertEqual(s.beginEditingSelectionSynthetic("guzel", touches: centres("guzel")),
                       .rebuilt)
        XCTAssertTrue(s.isEditingSelection)
        XCTAssertFalse(s.selectionHasRealEvidence, "otomatik uygulamaya yetki yok")
    }
}
