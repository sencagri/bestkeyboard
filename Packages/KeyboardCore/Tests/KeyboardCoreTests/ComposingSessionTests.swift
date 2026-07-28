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

    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    var contextBeforeInput: String? { text }
}

private func touch(_ x: Double, _ y: Double = 0.5) -> TouchSample {
    TouchSample(down: Point(x: x, y: y), timestamp: 0)
}

final class ComposingSessionTests: XCTestCase {

    private func type(_ word: String, _ s: inout ComposingSession, _ doc: FakeDocument) {
        for (i, ch) in word.enumerated() {
            _ = s.insertLetter(ch, touch: touch(Double(i) / 10.0), into: doc)
        }
    }

    // MARK: - Temel yazım

    func testTypingKeepsThreeViewsInSync() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)

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
        type("lslm", &s, doc)                       // 4 harf yazıldı
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
        type("lslm", &s, doc)
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
        type("lslm", &s, doc)
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
        type("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.backspaceTap(into: doc)
        _ = s.finishToken(separator: " ", into: doc)

        XCTAssertEqual(s.backspaceTap(into: doc), .unchanged, "geri dönüş olmamalı")
        XCTAssertEqual(doc.text, "kale", "yalnız boşluk silinmiş olmalı")
    }

    /// Uzunluklar eşitken (yaygın durum) silme hizayı korur, kanıt kopmaz.
    func testDeletingAnAlignedCorrectionKeepsEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("guzel", &s, doc)
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
        type("ab", &s, doc)
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

        type("lslm", &s, doc);                          check("yazım")
        s.replaceDisplay(with: "kalem", into: doc);      check("düzeltme")
        _ = s.insertLetter("i", touch: touch(0.4), into: doc); check("düzeltme sonrası ekleme")
        _ = s.backspaceTap(into: doc);                  check("ayrışmış silme")
        _ = s.insertLetter("z", touch: touch(0.6), into: doc); check("kopukken ekleme")
        _ = s.finishToken(separator: " ", into: doc);    check("commit")
        type("iki", &s, doc);                           check("yeni token")
        _ = s.backspaceTap(into: doc);                  check("hizalı silme")
        _ = s.invalidate();                             check("invalidate")
    }

    // MARK: - Boşlukla commit

    func testFinishTokenWritesSeparatorAndClears() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)
        XCTAssertEqual(s.finishToken(separator: " ", into: doc), .cleared)

        XCTAssertEqual(doc.text, "kalem ")
        XCTAssertFalse(s.isComposing)
        XCTAssertTrue(s.touches.isEmpty)
    }

    // MARK: - Geri dönüş (kullanıcının 3. isteği)

    func testBackspaceIntoPreviousWordRestoresItsTouchEvidence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("lslm", &s, doc)
        s.replaceDisplay(with: "kalem", into: doc)
        _ = s.finishToken(separator: " ", into: doc)
        XCTAssertEqual(doc.text, "kalem ")

        // Boşluğu sil → kelimeye geri dön.
        XCTAssertEqual(s.backspaceTap(into: doc), .rebuilt)

        XCTAssertEqual(doc.text, "kalem", "yalnız boşluk silinmeli, kelime durmalı")
        XCTAssertEqual(s.display, "kalem")
        XCTAssertEqual(s.literal, "lslm", "kanıt kullanıcının bastığı harflerdi")
        XCTAssertEqual(s.touches.count, 4)
        XCTAssertTrue(s.isComposing, "yeni yazıyormuş gibi devam edebilmeli")
    }

    func testTypingContinuesAfterRestore() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        _ = s.backspaceTap(into: doc)

        _ = s.insertLetter("i", touch: touch(0.9), into: doc)
        XCTAssertEqual(doc.text, "kalemi")
        XCTAssertEqual(s.touches.count, 6)
    }

    func testRestoreOnlyReachesBackOneWordPerBackspace() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        type("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)

        _ = s.backspaceTap(into: doc)
        XCTAssertEqual(s.display, "iki")
        XCTAssertEqual(doc.text, "bir iki")
    }

    /// Geçmiş yalnız kendi yazdığımız metne dayanır. Host araya girdiyse
    /// eşleşme tutmaz ve normal silmeye düşülür.
    func testRestoreDoesNotFireWhenDocumentDivergedFromHistory() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.hostRewrites(to: "bambaşka ")
        XCTAssertEqual(s.backspaceTap(into: doc), .unchanged)
        XCTAssertEqual(doc.text, "bambaşka")
        XCTAssertFalse(s.isComposing)
    }

    func testHistoryDepthIsBounded() {
        var s = ComposingSession()
        let doc = FakeDocument()
        for i in 0..<(ComposingSession.maxHistoryDepth + 4) {
            type("w\(i)", &s, doc)
            _ = s.finishToken(separator: " ", into: doc)
        }
        // En eskiler düşmüş olmalı: son kelimeye dönülür, ilkine dönülemez.
        var restores = 0
        while s.backspaceTap(into: doc) == .rebuilt {
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
        type("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        _ = s.backspaceRepeat(into: doc)
        XCTAssertEqual(doc.text, "kalem")
        XCTAssertFalse(s.isComposing, "tekrar sırasında kelimeye girilmemeli")
    }

    func testWordDeleteRemovesTrailingSpaceAndWord() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        type("iki", &s, doc); _ = s.finishToken(separator: " ", into: doc)

        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "bir ")
        _ = s.deleteWordBackward(into: doc)
        XCTAssertEqual(doc.text, "")
    }

    func testWordDeleteConsumesComposingTokenWhole() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("bir", &s, doc); _ = s.finishToken(separator: " ", into: doc)
        type("yarım", &s, doc)

        XCTAssertEqual(s.deleteWordBackward(into: doc), .cleared)
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
        type("lslm", &s, doc)
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
        XCTAssertEqual(s.deleteWordBackward(into: doc), .unchanged)
        XCTAssertEqual(doc.text, "")
    }

    // MARK: - Host uzlaştırması

    func testAgreesWithHostDetectsDivergence() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)
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
        type("kalem", &s, doc)
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
        type("iki", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)

        doc.hostRewrites(to: "biriki ")
        XCTAssertEqual(s.backspaceTap(into: doc), .unchanged)
        XCTAssertEqual(doc.text, "biriki", "sonek çakışmasıyla geri dönülmemeli")
        XCTAssertFalse(s.isComposing)
    }

    func testInvalidateDropsEverything() {
        var s = ComposingSession()
        let doc = FakeDocument()
        type("kalem", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        type("iki", &s, doc)

        XCTAssertEqual(s.invalidate(), .cleared)
        XCTAssertFalse(s.isComposing)
        // Geçmiş de gitti: geri dönüş yok, düz silme var.
        XCTAssertEqual(s.backspaceTap(into: doc), .unchanged)
    }
}
