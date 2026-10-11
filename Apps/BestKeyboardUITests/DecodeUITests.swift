import XCTest
import UIKit

/// Uçtan uca dikey dilim testi: gerçek UIKit dokunma olayları →
/// normalize koordinat → uzamsal model → beam search → öneri.
///
/// Erişilebilirlik kimliği yerine **normalize koordinatla** dokunur; test
/// edilen şey zaten uzamsal yol olduğu için en sadık yöntem budur.
final class DecodeUITests: XCTestCase {

    /// Tuşlara **erişilebilirlik öğesiyle** dokunulur, koordinat hesabıyla değil.
    ///
    /// Önceki sürüm `TurkishQ` geometrisini testte yeniden tanımlıyordu; layout
    /// değişip test sabitleri değişmediğinde dokunuşlar sessizce başka tuşlara
    /// kayabilirdi (ve decoder belirsizliği bunu bazen gizlerdi). `KeyboardView`
    /// artık her tuşu `key.<char>` kimlikli bir erişilebilirlik öğesi olarak
    /// dışa açıyor; tek doğruluk kaynağı üretim layout'u.

    /// Tezgah açık ve paket yüklenmiş.
    private func launchReadyHarness() -> XCUIApplication {
        let app = XCUIApplication.launchHarness()
        // Paketin yüklenmesini bekle.
        let status = app.staticTexts["harness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        // Tezgah "hazır — <rapor>" yazıyor; test uzun süre "paket hazır"
        // bekliyordu ve hiç eşleşmiyordu — süite kırmızıydı.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !status.label.hasPrefix("hazır") {
            usleep(200_000)
        }
        XCTAssertTrue(status.label.hasPrefix("hazır"), "paket yüklenmedi: \(status.label)")
        return app
    }

    private func type(_ s: String, in app: XCUIApplication) {
        let kb = app.otherElements["harness.keyboard"]
        for ch in s {
            let key = kb.keys["key.\(ch)"]
            XCTAssertTrue(key.waitForExistence(timeout: 2), "tuş bulunamadı: key.\(ch)")
            key.tap()
            usleep(60_000)
        }
    }

    /// Kanonik vaka — projenin varlık sebebi.
    func testLslemDecodesToKalem() throws {
        let app = launchReadyHarness()
        type("lslem", in: app)

        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: lslem")

        let top = app.staticTexts["harness.top"]
        XCTAssertEqual(top.label, "kalem",
                       "top-1 'kalem' olmalı. Adaylar: \(app.staticTexts["harness.all"].label)")

        // `işlem` ilk iki öneride görünmemeli (marj politikası).
        let all = app.staticTexts["harness.all"].label
        let shown = all.split(separator: " ").filter { !$0.contains(".") }.prefix(2)
        XCTAssertFalse(shown.contains("işlem"), "işlem ikinci öneri olmamalı: \(all)")
    }

    /// Deasciification — Türkçe için kritik (§2.3).
    func testGuzelDecodesToGuzel() throws {
        let app = launchReadyHarness()
        type("guzel", in: app)
        XCTAssertEqual(app.staticTexts["harness.top"].label, "güzel",
                       "adaylar: \(app.staticTexts["harness.all"].label)")
    }

    /// Doğru yazılmış kelime bozulmamalı.
    func testExactWordUnchanged() throws {
        let app = launchReadyHarness()
        type("kitap", in: app)
        XCTAssertEqual(app.staticTexts["harness.top"].label, "kitap",
                       "adaylar: \(app.staticTexts["harness.all"].label)")
    }

    // MARK: - Nokta tuşu (§ 3. satır, 10. yuva)

    /// Nokta **kod çözmeye girmiyor** — testin buradaki sebebi tam olarak bu.
    ///
    /// Tuş `ç`'nin yanında ve harflerle aynı ızgarada duruyor, yani görünüşte
    /// harflerden ayırt edilemez. Ayrım modelde: `.` `KeyLayout`'a değil işlev
    /// yuvalarına ait, dolayısıyla literal'e giriyor ama aday üretmiyor.
    func testPeriodKeyTypesADotWithoutDecoding() throws {
        let app = launchReadyHarness()
        type("kalem", in: app)
        let kb = app.otherElements["harness.keyboard"]
        let period = kb.keys["key.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 2), "nokta tuşu yok")
        period.tap()
        usleep(120_000)
        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: kalem.")
    }

    /// Basılı tutunca **virgül**, ve nokta *yazılmıyor*.
    ///
    /// İkinci kısım birincisinden önemli: uzun basma tek atışlık bir eşik ve
    /// bırakışta commit bastırılmazsa kullanıcı `,.` alırdı.
    func testHoldingPeriodTypesACommaInstead() throws {
        let app = launchReadyHarness()
        type("kalem", in: app)
        let kb = app.otherElements["harness.keyboard"]
        let period = kb.keys["key.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 2), "nokta tuşu yok")
        // Nokta eşiği silme hızından bağımsız 0.5 sn; 0.9 rahatça aşıyor.
        period.press(forDuration: 0.9)
        usleep(200_000)
        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: kalem,",
                       "uzun basma virgül üretmeli ve noktayı bastırmalı")
    }

    func testPeriodDragCancelsPendingHoldAndConsumedHoldDoesNotCommitAgain() {
        let app = launchReadyHarness()
        let keyboard = app.otherElements["harness.keyboard"]
        let period = keyboard.keys["key.period"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let letter = keyboard.keys["key.q"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = app.staticTexts["harness.status"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let literal = app.staticTexts["harness.literal"]
        period.press(forDuration: 0.05, thenDragTo: letter)
        XCTAssertEqual(literal.label, "literal: q")
        keyboard.keys["key.period"].tap()
        XCTAssertEqual(literal.label, "literal: q.")
        period.press(forDuration: 0.8, thenDragTo: letter)
        XCTAssertEqual(literal.label, "literal: q.,")
        keyboard.keys["key.period"].tap()
        XCTAssertEqual(literal.label, "literal: q.,.")
        period.press(forDuration: 0.05, thenDragTo: outside)
        XCTAssertEqual(literal.label, "literal: q.,.")
        period.press(forDuration: 0.8, thenDragTo: outside)
        XCTAssertEqual(literal.label, "literal: q.,.,")
        keyboard.keys["key.period"].tap()
        XCTAssertEqual(literal.label, "literal: q.,.,.")
    }

    func testPeriodIgnoresFastDeleteSetting() {
        let app = XCUIApplication.launchHarness(arguments: ["-uiTestFastDelete"])
        let period = app.otherElements["harness.keyboard"].keys["key.period"]
        period.press(forDuration: 0.15)
        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: .")
        period.press(forDuration: 0.9)
        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: .,")
    }

    func testNumbersStayForDigitsAndReturnToLettersAtBoundary() {
        let app = XCUIApplication.launchHarness()
        let kb = app.otherElements["harness.keyboard"]
        for boundary in ["space", "ret"] {
            kb.keys["key.numbers"].tap()
            kb.keys["key.1"].tap()
            kb.keys["key.2"].tap()
            XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: 12")
            kb.keys["key.\(boundary)"].tap()
            XCTAssertTrue(kb.keys["key.q"].waitForExistence(timeout: 2))
        }
    }

    func testLearningShowsImportedWordsAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        XCTAssertTrue(paste.isHittable)
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("listedenemesi listedenemesi aktarimdenemesi")
        app.buttons["Öğren"].tap()
        app.terminate()
        app.launch()
        app.staticTexts["Öğrenme"].firstMatch.tap()
        let imported = app.buttons["learning.İçe aktarılanlar"]
        for _ in 0..<3 where !imported.isHittable { app.swipeUp() }
        XCTAssertTrue(imported.waitForExistence(timeout: 5))
        imported.tap()
        XCTAssertTrue(app.buttons["learning.remove.Metin"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("listedenemesi")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "listedenemesi")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "aktarimdenemesi")).firstMatch.exists)
    }

}

extension DecodeUITests {
    /// Uses the installed keyboard extension inside a real UITextView, not the
    /// app harness. The simulator must have BestKeyboard enabled beforehand.
    func testNativeKeyboardLiteralSelectionAndNumberBoundary() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let q = app.keys["key.q"]
        guard app.switchToBestKeyboard(until: q) else {
            XCTFail("Gerçek BestKeyboard uzantısı etkin değil"); return
        }
        for ch in "qrmenü" { app.keys["key.\(ch)"].tap() }
        app.keys["key.x"].tap()
        app.keys["key.backspace"].tap()
        let original = app.buttons["suggestion.0"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "qrmenü ")
        app.keys["key.numbers"].tap()
        app.keys["key.1"].tap()
        app.keys["key.2"].tap()
        app.keys["key.space"].tap()
        XCTAssertTrue(q.waitForExistence(timeout: 3))
        app.keys["key.period"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "qrmenü 12 .")
        app.keys["key.space"].tap()
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.tap()
        XCTAssertTrue(((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")) ?? "").hasSuffix("merhaba dünya "))
        for (input, expected) in [("iyiki", "iyi ki"), ("obzaman", "o zaman"),
                                  ("qrmenüdenbaç", "qrmenüden aç"),
                                  ("kitaplarımızdakilerdenbevdekilerimizdekilerden", "kitaplarımızdakilerden evdekilerimizdekilerden")] {
            for ch in input { app.keys["key.\(ch)"].tap() }
            let shortRepair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", expected)).firstMatch
            XCTAssertTrue(shortRepair.waitForExistence(timeout: 5))
            shortRepair.tap()
            XCTAssertTrue(((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")) ?? "").hasSuffix(expected + " "))
        }
    }

    func testNativeSelectedWordKeepsSuggestionsAndConfirmationEndsSelection() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for ch in "qrmenü" { app.keys["key.\(ch)"].tap() }
        app.buttons["suggestion.0"].tap()
        // Select the first word through the host's real UIKit selection gesture.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 16)).doubleTap()
        let original = app.buttons["suggestion.0"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.lowercased(with: Locale(identifier: "tr_TR")).contains("qrmenü"))
        original.tap()
        app.keys["key.x"].tap()
        let text = (editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")) ?? ""
        XCTAssertTrue(text.hasPrefix("qrmenüx"), text)
    }

    func testNativeSelectedWordOffersTwoWordRepair() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 16)).doubleTap()
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya ")
        app.keys["key.x"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünyax ")
    }

    func testNativeCompoundEmojiDeletionAfterPhraseRepair() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya ")
        app.keys["key.backspace"].tap()
        for emoji in ["🇹🇷", "🏳️‍🌈", "🏴‍☠️"] {
            for panelDelete in [false, true] {
                app.buttons["key.emoji"].tap()
                let flags = app.buttons["Bayraklar"]
                XCTAssertTrue(flags.waitForExistence(timeout: 3))
                flags.tap()
                let cell = app.cells.matching(NSPredicate(format: "label == %@", emoji)).firstMatch
                XCTAssertTrue(cell.waitForExistence(timeout: 3), emoji)
                cell.tap()
                XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya" + emoji)
                if panelDelete {
                    app.buttons["key.emoji.backspace"].tap()
                    app.buttons["key.emoji.close"].tap()
                } else {
                    app.buttons["key.emoji.close"].tap()
                    app.keys["key.backspace"].tap()
                }
                XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya", emoji)
                app.keys["key.x"].tap()
                XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünyax", emoji)
                app.keys["key.backspace"].tap()
            }
        }
    }

    func testNativeQuotedEmailSelectionConfirmation() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        app.keys["key.numbers"].tap()
        app.keys["key.\""].tap()
        app.keys["key.letters"].tap()
        for ch in "çağrı" { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        for ch in "şen" { app.keys["key.\(ch)"].tap() }
        app.keys["key.numbers"].tap()
        app.keys["key.\""].tap()
        app.keys["key.@"].tap()
        app.keys["key.letters"].tap()
        for ch in "örnek" { app.keys["key.\(ch)"].tap() }
        app.keys["key.period"].tap()
        for ch in "com" { app.keys["key.\(ch)"].tap() }
        let email = (editor.value as? String) ?? ""
        XCTAssertEqual(email.lowercased(with: Locale(identifier: "tr_TR")), "\"çağrı şen\"@örnek.com")
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", email)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Whole quoted email must be selected and offered")
        original.tap()
        XCTAssertEqual(editor.value as? String, email)
        app.keys["key.x"].tap()
        XCTAssertEqual(editor.value as? String, email + "x")
        app.keys["key.backspace"].tap()
        XCTAssertEqual(editor.value as? String, email)
    }

    func testNativeBackspaceRepeatStopsAfterDraggingOutside() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for _ in 0..<20 {
            app.keys["key.s"].tap(); app.keys["key.u"].tap(); app.keys["key.space"].tap()
        }
        let initial = (editor.value as? String) ?? ""
        XCTAssertEqual(initial.lowercased(with: Locale(identifier: "tr_TR")), String(repeating: "su ", count: 20))
        let backspace = app.keys["key.backspace"]
        let outside = editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 16))
        backspace.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1, thenDragTo: outside)
        let afterHold = (editor.value as? String) ?? ""
        XCTAssertFalse(afterHold.isEmpty, "Test must retain text to detect a leaking repeat timer")
        XCTAssertLessThan(afterHold.count, initial.count)
        usleep(700_000)
        XCTAssertEqual(editor.value as? String, afterHold, "Deletion continued after release")
        backspace.press(forDuration: 0.01)
        XCTAssertEqual(editor.value as? String, String(afterHold.dropLast()))
        let afterTap = (editor.value as? String) ?? ""
        app.keys["key.x"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), (afterTap + "x").lowercased(with: Locale(identifier: "tr_TR")))
    }

    func testNativeTrackpadVerticalMoveASCII() throws {
        try assertNativeTrackpadVerticalMove(emoji: false)
    }

    func testNativeTrackpadVerticalMoveAcrossEmoji() throws {
        try assertNativeTrackpadVerticalMove(emoji: true)
    }

    private func assertNativeTrackpadVerticalMove(emoji: Bool) throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        app.keys["key.a"].tap(); app.keys["key.b"].tap()
        if emoji {
            app.buttons["key.emoji"].tap()
            let flags = app.buttons["Bayraklar"]
            XCTAssertTrue(flags.waitForExistence(timeout: 3)); flags.tap()
            let cell = app.cells.matching(NSPredicate(format: "label == %@", "🇹🇷")).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 3)); cell.tap()
            app.buttons["key.emoji.close"].tap()
        } else { app.keys["key.z"].tap() }
        app.keys["key.c"].tap(); app.keys["key.d"].tap()
        app.keys["key.ret"].tap(); app.keys["key.x"].tap()
        let original = "ab" + (emoji ? "🇹🇷" : "z") + "cd\nx"
        func text() -> String { (editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")) ?? "" }
        XCTAssertEqual(text(), original)
        let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertEqual(text(), original, "Trackpad must not insert a space")
        app.keys["key.q"].tap()
        XCTAssertEqual(text(), "aqb" + (emoji ? "🇹🇷" : "z") + "cd\nx", "Vertical movement must preserve the one-character column")
    }

    func testNativeGroupedPhoneSelectionConfirmation() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        let phone = "0532 123 45 67"
        for (index, group) in phone.split(separator: " ").enumerated() {
            if index > 0 { app.keys["key.space"].tap() }
            app.keys["key.numbers"].tap()
            for ch in group { app.keys["key.\(ch)"].tap() }
        }
        XCTAssertEqual(editor.value as? String, phone)
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", phone)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Whole phone must be selected and offered")
        original.tap()
        XCTAssertEqual(editor.value as? String, phone)
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
        app.keys["key.x"].tap()
        XCTAssertEqual(editor.value as? String, phone + "x")
        app.keys["key.backspace"].tap()
        XCTAssertEqual(editor.value as? String, phone)
    }

    func testNativePhraseSelectionBetweenEmojiAndIPAddress() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        app.buttons["key.emoji"].tap()
        let flags = app.buttons["Bayraklar"]
        XCTAssertTrue(flags.waitForExistence(timeout: 3)); flags.tap()
        let flag = app.cells.matching(NSPredicate(format: "label == %@", "🇹🇷")).firstMatch
        XCTAssertTrue(flag.waitForExistence(timeout: 3)); flag.tap()
        app.buttons["key.emoji.close"].tap()
        app.keys["key.space"].tap()
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        app.keys["key.numbers"].tap()
        for ch in "192.0.2.1" { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        func text() -> String { (editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")) ?? "" }
        XCTAssertEqual(text(), "🇹🇷 merhababdünya 192.0.2.1 ")
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85, dy: 16)).doubleTap()
        XCTAssertTrue(app.buttons["suggestion.0"].label.lowercased(with: Locale(identifier: "tr_TR")).contains("merhababdünya"))
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5)); repair.tap()
        XCTAssertEqual(text(), "🇹🇷 merhaba dünya 192.0.2.1 ")
        app.keys["key.x"].tap()
        XCTAssertEqual(text(), "🇹🇷 merhaba dünyax 192.0.2.1 ")
        app.keys["key.backspace"].tap()
        XCTAssertEqual(text(), "🇹🇷 merhaba dünya 192.0.2.1 ")
    }

    func testNativeRepeatedPhraseReopenKeepsLiteralSuggestion() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya ")
        for cycle in 1...3 {
            app.keys["key.backspace"].tap()
            XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), "merhaba dünya")
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "dünya")).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 3), "Literal missing on reopen cycle \(cycle)")
            app.keys["key.space"].tap()
        }
    }

    func testNativePhrasePickLearnsIncomingNextWord() throws {
        let app = XCUIApplication()
        app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        // A fresh alphabetic context prevents prior test history from supplying
        // the expected incoming pair and hiding a learning failure.
        let letters = Array("abcdefghijklmnop")
        let prefix = "deneme" + String((0..<8).map { _ in letters.randomElement()! })
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        let next = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", "merhaba")).firstMatch
        XCTAssertFalse(next.exists)
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.tap()
        app.keys["key.ret"].tap()
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
    }

    func testNativeSelectedPhraseReconcilesNextWordHistory() throws {
        try assertNativeSelectedPhraseHistory(punctuation: false)
    }

    func testNativePunctuatedSelectedPhraseReconcilesHistory() throws {
        try assertNativeSelectedPhraseHistory(punctuation: true)
    }

    private func assertNativeSelectedPhraseHistory(punctuation: Bool) throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        let alphabet = Array("abcdefghijklmnop")
        let prefix = "qx" + String((0..<4).map { _ in alphabet.randomElement()! })
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.buttons["suggestion.0"].tap()
        let next = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", "merhaba")).firstMatch
        XCTAssertFalse(next.exists)
        for ch in "merhababdünya" { app.keys["key.\(ch)"].tap() }
        if punctuation { app.keys["key.period"].tap() }
        app.keys["key.space"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), prefix + " merhababdünya" + (punctuation ? ". " : " "))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 115, dy: 16)).doubleTap()
        XCTAssertTrue(app.buttons["suggestion.0"].label.lowercased(with: Locale(identifier: "tr_TR")).contains("merhababdünya"))
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "merhaba dünya")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5)); repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), prefix + " merhaba dünya" + (punctuation ? ". " : " "))
        app.keys["key.ret"].tap()
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let old = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", "merhababdünya")).firstMatch
        XCTAssertFalse(old.exists)
    }

    func testNativeSingleWordSelectionReconcilesHistory() throws {
        try assertNativeSingleWordSelectionHistory(punctuation: false)
        try assertNativeSingleWordSelectionHistory(punctuation: true)
    }

    func testNativeBracketedSingleWordSelectionReconcilesHistory() throws {
        try assertNativeSingleWordSelectionHistory(punctuation: false, wrapped: true)
    }

    private func assertNativeSingleWordSelectionHistory(punctuation: Bool, wrapped: Bool = false) throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        let alphabet = Array("abcdefghijklmnop")
        let prefix = "qx" + String((0..<4).map { _ in alphabet.randomElement()! })
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.buttons["suggestion.0"].tap()
        let next = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", "kalem")).firstMatch
        XCTAssertFalse(next.exists)
        if wrapped { app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap(); app.keys["key.["].tap(); app.keys["key.letters"].tap() }
        for ch in "kalen" { app.keys["key.\(ch)"].tap() }
        if wrapped {
            app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap(); app.keys["key.]"].tap(); app.keys["key.space"].tap()
        } else if punctuation {
            app.keys["key.period"].tap(); app.keys["key.space"].tap()
        } else {
            app.buttons["suggestion.0"].tap()
        }
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), prefix + (wrapped ? " [kalen] " : " kalen" + (punctuation ? ". " : " ")))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85, dy: 16)).doubleTap()
        XCTAssertTrue(app.buttons["suggestion.0"].label.lowercased(with: Locale(identifier: "tr_TR")).contains("kalen"))
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@", "suggestion.", "kalem")).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5)); repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), prefix + (wrapped ? " [kalem] " : " kalem" + (punctuation ? ". " : " ")))
        app.keys["key.ret"].tap()
        for ch in prefix { app.keys["key.\(ch)"].tap() }
        app.keys["key.space"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let old = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", "kalen")).firstMatch
        XCTAssertFalse(old.exists)
    }

    func testNativeIPv6HistoryPreservesColonEdges() throws {
        for (address, prefix) in [("2001:db8::", "2001:db8:"), ("::ffff:192.0.2.1", "::ffff:192.0.2."), ("::1", "::")] {
            let app = XCUIApplication(); app.launch()
            let learning = app.staticTexts["Öğrenme"].firstMatch
            XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
            let paste = app.staticTexts["Metin yapıştır"].firstMatch
            for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
            paste.tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
            func typeAddress(_ value: String) {
                for ch in value {
                    if ch.isNumber || ":.".contains(ch) {
                        if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                    } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                    app.keys["key.\(ch)"].tap()
                }
            }
            typeAddress(address); app.keys["key.space"].tap(); app.keys["key.ret"].tap()
            typeAddress(prefix)
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", address)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
            XCTAssertEqual(editor.value as? String, address + " \n" + address)
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
        }
    }

    func testNativeObservedAddressCompletionsAndContinuation() throws {
        for (address, prefix) in [("https://example.com/docs", "https://example.com/do"),
                                  ("dev@example.com", "dev@exa"), ("+905321234567", "+90532"),
                                  ("+905469827613", "+90 546 982 7")] {
            let app = XCUIApplication(); app.launch()
            let learning = app.staticTexts["Öğrenme"].firstMatch
            XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
            let paste = app.staticTexts["Metin yapıştır"].firstMatch
            for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
            paste.tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
            func typeAddress(_ value: String) {
                for ch in value {
                    if ch == " " { app.keys["key.space"].tap(); continue }
                    if ch == "+" {
                        if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                        if !app.keys["key.+"].exists { app.keys["key.symbols"].tap() }
                    } else if ch.isNumber || ":./@".contains(ch) {
                        if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                    } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                    app.keys["key.\(ch)"].tap()
                }
            }
            typeAddress(address)
            let learned = try XCTUnwrap(editor.value as? String)
            XCTAssertEqual(learned.lowercased(with: Locale(identifier: "tr_TR")), address)
            app.keys["key.space"].tap(); app.keys["key.ret"].tap()
            typeAddress(prefix)
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", learned)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5), learned); offer.tap()
            XCTAssertEqual(editor.value as? String, learned + " \n" + learned)
            XCTAssertTrue(app.keys["key.x"].waitForExistence(timeout: 3))
            app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, learned + " \n" + learned + "x")
            if prefix.contains(" ") {
                app.keys["key.ret"].tap(); typeAddress("+9054698")
                let partial = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", "+90 546 982")).firstMatch
                XCTAssertFalse(partial.exists, "A reformatted completion must retire its provisional short phone")
            }
        }
    }

    func testNativeCompletionAfterMovingIntoAddressPreservesRightTail() throws {
        for (address, prefix) in [("10.0.0.123", "10."), ("dev@example.com", "dev@exa")] {
            let app = XCUIApplication(); app.launch()
            let learning = app.staticTexts["Öğrenme"].firstMatch
            XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
            let paste = app.staticTexts["Metin yapıştır"].firstMatch
            for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
            paste.tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
            func typeAddress(_ value: String) {
                for ch in value {
                    if ch.isNumber || ".@".contains(ch) {
                        if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                    } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                    app.keys["key.\(ch)"].tap()
                }
            }
            typeAddress(address)
            let learned = try XCTUnwrap(editor.value as? String)
            XCTAssertEqual(learned.lowercased(with: Locale(identifier: "tr_TR")), address)
            app.keys["key.space"].tap(); app.keys["key.ret"].tap(); typeAddress(prefix)
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", learned)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
            app.keys["key.ret"].tap(); typeAddress("abc")
            let document = try XCTUnwrap(editor.value as? String)
            let thirdLine = String(document.suffix(3))
            XCTAssertEqual(document, learned + " \n" + learned + "\n" + thirdLine)
            let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -45)))
            XCTAssertEqual(editor.value as? String, document)
            XCTAssertFalse(offer.exists, "Exact existing address must not be offered again at an interior cursor")
            app.keys["key.backspace"].press(forDuration: 0.01)
            let shortened = String(learned.prefix(2)) + learned.dropFirst(3)
            XCTAssertEqual(editor.value as? String, learned + " \n" + shortened + "\n" + thirdLine)
            XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
            XCTAssertEqual(editor.value as? String, document, "Completion must retain the right fragment exactly once")
            app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, learned + " \n" + learned + "x\n" + thirdLine)
        }
    }

    func testNativeQuotedEmailCompletionDoesNotLearnPartialName() throws {
        try assertNativeQuotedEmailCompletionHistory(middle: false)
    }

    func testNativeMiddleQuotedEmailCompletionDoesNotLearnPartialName() throws {
        try assertNativeQuotedEmailCompletionHistory(middle: true)
    }

    private func assertNativeQuotedEmailCompletionHistory(middle: Bool) throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        let alphabet = Array("abcdefghijklmnop")
        let name = "qx" + String((0..<4).map { _ in alphabet.randomElement()! })
        let tag = "qz" + String((0..<4).map { _ in alphabet.randomElement()! })
        func type(_ value: String) {
            for ch in value {
                if ch == " " { app.keys["key.space"].tap(); continue }
                if ".@\"".contains(ch) {
                    if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        type("önce ")
        let seedPrefix = try XCTUnwrap(editor.value as? String)
        type("\"" + name + " last\"@example.com")
        let learned = String(try XCTUnwrap(editor.value as? String).dropFirst(seedPrefix.count))
        // Rastgele ad ilk boşlukta düzeltilebilir; tekrar aynı, gerçekten
        // öğrenilmiş adresin önekini yaz (farklı bir rastgele sözcüğü değil).
        let learnedPrefix = String(learned.prefix { $0 != " " })
        app.keys["key.space"].tap(); app.keys["key.ret"].tap()
        type(tag); app.buttons["suggestion.0"].tap()
        let partial = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", String(learnedPrefix.dropFirst()))).firstMatch
        XCTAssertFalse(partial.exists)
        var expectedMiddle: String?
        if middle {
            type("ample.com"); app.keys["key.ret"].tap(); type(tag); app.keys["key.space"].tap()
            var document = try XCTUnwrap(editor.value as? String)
            let tailRange = try XCTUnwrap(document.range(of: "ample.com", options: .backwards))
            document.replaceSubrange(tailRange, with: learned)
            expectedMiddle = document
            let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -45)))
        }
        type(learnedPrefix + (middle ? " last\"@e" : " last\"@exa"))
        let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", learned)).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
        if let expectedMiddle { XCTAssertEqual(editor.value as? String, expectedMiddle) }
        else { XCTAssertTrue((editor.value as? String)?.hasSuffix(learned) == true) }
        app.keys["key.ret"].tap(); type(tag); app.keys["key.space"].tap()
        XCTAssertFalse(partial.exists, "A partial quoted mailbox name must not become a next-word prediction")
    }

    func testNativeNBSPPhoneCompletionPreservesRightTail() throws {
        let phone = "+90\u{00a0}532\u{00a0}123\u{00a0}45\u{00a0}67"
        UIPasteboard.general.string = phone + " \n" + phone + "\nabcde"
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        editor.press(forDuration: 1.0)
        let pasteItem = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
        if pasteItem.waitForExistence(timeout: 3) { pasteItem.tap() }
        else {
            let pasteButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
            XCTAssertTrue(pasteButton.waitForExistence(timeout: 3)); pasteButton.tap()
        }
        XCTAssertEqual(editor.value as? String, phone + " \n" + phone + "\nabcde")
        app.buttons["key.settings"].tap()
        let learn = app.buttons["Bu alandaki metinden öğren"].firstMatch
        XCTAssertTrue(learn.waitForExistence(timeout: 5)); learn.tap()
        app.buttons["Bitti"].firstMatch.tap()
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 5))
        let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", phone)).firstMatch
        let document = try XCTUnwrap(editor.value as? String)
        let thirdLine = String(document.suffix(5))
        XCTAssertEqual(document, phone + " \n" + phone + "\n" + thirdLine)
        let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -45)))
        app.keys["key.backspace"].press(forDuration: 0.01)
        XCTAssertEqual(editor.value as? String, phone + " \n" + phone.prefix(4) + phone.dropFirst(5) + "\n" + thirdLine)
        XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
        XCTAssertEqual(editor.value as? String, document)
        app.keys["key.x"].tap()
        XCTAssertEqual(editor.value as? String, phone + " \n" + phone + "x\n" + thirdLine)
    }

    func testNativeReformattedPhoneCompletionInsideParentheses() throws {
        let phone = "+90 (532) 123-45-67"
        let rightToken = "2) 123-45-67"
        UIPasteboard.general.string = phone + "\n" + rightToken + "\nabc"
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        editor.press(forDuration: 1.0)
        let pasteItem = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
        if pasteItem.waitForExistence(timeout: 3) { pasteItem.tap() }
        else {
            let pasteButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
            XCTAssertTrue(pasteButton.waitForExistence(timeout: 3)); pasteButton.tap()
        }
        XCTAssertEqual(editor.value as? String, phone + "\n" + rightToken + "\nabc")
        app.buttons["key.settings"].tap()
        let learn = app.buttons["Bu alandaki metinden öğren"].firstMatch
        XCTAssertTrue(learn.waitForExistence(timeout: 5)); learn.tap()
        app.buttons["Bitti"].firstMatch.tap()
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.keys["key.backspace"].press(forDuration: 0.01) }
        XCTAssertEqual(editor.value as? String, phone + "\n" + rightToken + "\n")
        let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -45)))
        for ch in "+90(53" {
            if ch == "+" {
                if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                if !app.keys["key.+"].exists { app.keys["key.symbols"].tap() }
            } else if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
            app.keys["key.\(ch)"].tap()
        }
        XCTAssertEqual(editor.value as? String, phone + "\n+90(53" + rightToken + "\n")
        let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", phone)).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
        XCTAssertEqual(editor.value as? String, phone + "\n" + phone + "\n")
        XCTAssertTrue(app.keys["key.x"].waitForExistence(timeout: 3)); app.keys["key.x"].tap()
        XCTAssertEqual(editor.value as? String, phone + "\n" + phone + "x\n")
    }

    func testNativeTrackpadAtDocumentBoundaryDoesNotInsertSpace() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
        for offset in [CGVector(dx: 0, dy: -45), CGVector(dx: 0, dy: 45),
                       CGVector(dx: -45, dy: 0), CGVector(dx: 45, dy: 0)] {
            let origin = app.keys["key.space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.5, thenDragTo: origin.withOffset(offset))
            XCTAssertEqual(editor.value as? String, "", "A deliberate cursor drag at the boundary must not type a space: \(offset)")
            if (editor.value as? String)?.isEmpty == false { app.keys["key.backspace"].press(forDuration: 0.01) }
        }
        app.keys["key.space"].tap()
        XCTAssertEqual(editor.value as? String, " ", "Ordinary space remains available")
        app.keys["key.backspace"].press(forDuration: 0.01)
        app.keys["key.space"].press(forDuration: 0.5)
        XCTAssertEqual(editor.value as? String, " ", "A stationary hold is still a space")
    }

    func testNativeUnicodeRightTailCompletionAndContinuation() throws {
        for address in ["https://example.com/ışık", "https://example.com/s\u{0327}ube", "https://example.com/👩🏽‍💻/belge"] {
            let prefix = "https://example.com"
            let right = String(address.dropFirst(prefix.count + 1))
            UIPasteboard.general.string = address
            let app = XCUIApplication()
            app.launchArguments = ["-nativeKeyboardFixture", "-fixtureBefore", "(" + prefix, "-fixtureAfter", right + ") sonra"]
            app.launch()
            let editor = app.textViews["native.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("Keyboard unavailable"); return }
            editor.press(forDuration: 1.0)
            let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
            if paste.waitForExistence(timeout: 3) { paste.tap() }
            else {
                let button = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "Yapıştır"])).firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
            }
            XCTAssertEqual(editor.value as? String, address)
            app.buttons["key.settings"].tap()
            let learn = app.buttons["Bu alandaki metinden öğren"].firstMatch
            XCTAssertTrue(learn.waitForExistence(timeout: 5)); learn.tap()
            app.buttons["Bitti"].firstMatch.tap()
            app.buttons["native.fixture"].tap()
            XCTAssertTrue(app.switchToBestKeyboard(until: app.keys["key.q"]))
            XCTAssertEqual(editor.value as? String, "(" + prefix + right + ") sonra")
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", address)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.tap()
            XCTAssertEqual(editor.value as? String, "(" + address + ") sonra")
            XCTAssertTrue(app.keys["key.x"].waitForExistence(timeout: 3)); app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, "(" + address + ")x sonra", "Unicode right tail must be traversed fully")
        }
    }

    func testNativeWrappedAddressCompletionPreservesDelimiters() throws {
        for (address, prefix, open, close, right) in [("https://example.com/f(1)", "https://example.com/f", "(", ")", "1)"),
                                                ("dev@example.c0m", "dev@example.", "\"", "\"", "0m"),
                                                ("https://example.com/f(x)", "https://example.com/f(", "(", ")", ""),
                                                ("dev@example.com", "dev@exa", "\"", "\"", "")] {
            let app = XCUIApplication()
            app.launchArguments = ["-nativeKeyboardFixture", "-fixtureBefore", open + prefix, "-fixtureAfter", right + close]
            app.launch()
            let editor = app.textViews["native.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("Keyboard unavailable"); return }
            func typeAddress(_ value: String) {
                for ch in value {
                    if ch == " " { app.keys["key.space"].tap(); continue }
                    if ch == "+" {
                        if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                        if !app.keys["key.+"].exists { app.keys["key.symbols"].tap() }
                    } else if ch.isNumber || ":./@()\"".contains(ch) {
                        if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                    } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                    app.keys["key.\(ch)"].tap()
                }
            }
            typeAddress(address)
            let learned = try XCTUnwrap(editor.value as? String)
            XCTAssertEqual(learned.lowercased(with: Locale(identifier: "tr_TR")), address)
            app.keys["key.space"].tap()
            app.buttons["native.fixture"].tap()
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, open + prefix + right + close)
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", learned)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5), learned); offer.tap()
            XCTAssertEqual(editor.value as? String, open + learned + close)
            XCTAssertTrue(app.keys["key.x"].waitForExistence(timeout: 3)); app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, open + learned + close + "x", "Cursor must pass the preserved outer delimiter")
        }
    }

    func testNativeCaseFoldedEmailCompletionAndContinuation() throws {
        for (address, prefix) in [("dev@EXAMPLE.com", "dev@exa")] {
            let app = XCUIApplication(); app.launch()
            let learning = app.staticTexts["Öğrenme"].firstMatch
            XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
            let paste = app.staticTexts["Metin yapıştır"].firstMatch
            for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
            paste.tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
            guard app.switchToBestKeyboard(until: app.keys["key.q"]) else { XCTFail("BestKeyboard etkin değil"); return }
            func typeAddress(_ value: String) {
                for ch in value {
                    if ch == " " { app.keys["key.space"].tap(); continue }
                    if ch == "+" {
                        if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                        if !app.keys["key.+"].exists { app.keys["key.symbols"].tap() }
                    } else if ch.isNumber || ":./@".contains(ch) {
                        if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                    } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                    if ch.isUppercase { app.keys["key.shift"].tap() }
                    app.keys["key.\(String(ch).lowercased())"].tap()
                }
            }
            typeAddress(address)
            let learned = try XCTUnwrap(editor.value as? String)
            XCTAssertEqual(learned.lowercased(with: Locale(identifier: "tr_TR")), address.lowercased())
            XCTAssertTrue(learned.contains("@EXAMPLE.com"))
            app.keys["key.space"].tap(); app.keys["key.ret"].tap()
            typeAddress(prefix)
            let offer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", learned)).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 5), learned); offer.tap()
            XCTAssertEqual(editor.value as? String, learned + " \n" + learned)
            XCTAssertTrue(app.keys["key.x"].waitForExistence(timeout: 3))
            app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, learned + " \n" + learned + "x")

        }
    }

    func testNativeNumericPunctuationPreservesStructuredValues() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        var expected = ""
        for value in ["-12,50", "192.168.1.1:8080", "(532)123-45-67"] {
            app.keys["key.numbers"].tap()
            for ch in value {
                app.keys["key.\(ch)"].tap()
                expected.append(ch)
                XCTAssertEqual(editor.value as? String, expected)
                XCTAssertTrue(app.keys["key.1"].exists, "Numeric punctuation must retain the numeric plane")
            }
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
        }
        // The dedicated letter-plane period has a comma hold; the numeric dot
        // remains a literal numeric symbol even when held.
        app.keys["key.numbers"].tap()
        app.keys["key.1"].tap(); expected += "1"
        app.keys["key.."].press(forDuration: 0.8); expected += "."
        app.keys["key.5"].tap(); expected += "5"
        XCTAssertEqual(editor.value as? String, expected)
        app.keys["key.ret"].tap(); expected += "\n"
        XCTAssertEqual(editor.value as? String, expected)
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
        app.keys["key.x"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(), expected + "x")
    }

    func testNativeDeveloperSymbolsSurvivePlaneSwitches() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        var expected = ""
        let numeric = Set("1234567890-/:;()₺&@\".,?!'")
        let symbolic = Set("[]{}#%^*+=_\\|~<>€$¥•`âîû")
        for value in ["{\"id\":1}", "a_b", "c:\\tmp", "`tcp/ip`", "[::1]"] {
            for ch in value {
                if symbolic.contains(ch) {
                    if !app.keys["key.`"].exists {
                        if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                        app.keys["key.symbols"].tap()
                    }
                } else if numeric.contains(ch) {
                    if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                } else if !app.keys["key.q"].exists {
                    app.keys["key.letters"].tap()
                }
                app.keys["key.\(ch)"].tap()
                expected.append(ch)
                XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected,
                               "Symbol/plane change corrupted the document")
            }
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
        }
        app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
        app.keys["key.tab"].tap(); expected += "\t"
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
        app.keys["key.letters"].tap(); app.keys["key.x"].tap(); expected += "x"
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
    }

    func testNativeSelectedStructuredValuesDeleteAndContinue() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        let numeric = Set("1234567890:/.")
        for value in ["qrmenü", "0532 123 45 67", "https://ornek.com/a"] {
            for ch in value {
                if ch == " " { app.keys["key.space"].tap(); continue }
                if numeric.contains(ch) {
                    if !app.keys["key.1"].exists { app.keys["key.numbers"].tap() }
                } else if !app.keys["key.q"].exists {
                    app.keys["key.letters"].tap()
                }
                app.keys["key.\(ch)"].tap()
            }
            let original = (editor.value as? String) ?? ""
            XCTAssertEqual(original.lowercased(with: Locale(identifier: "tr_TR")), value)
            editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "suggestion.", original)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 5), "Whole value must be selected before deletion")
            app.keys["key.backspace"].press(forDuration: 0.01)
            XCTAssertEqual(editor.value as? String, "", "One delete must remove exactly the selection")
            if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
            app.keys["key.x"].tap()
            XCTAssertEqual((editor.value as? String)?.lowercased(), "x")
            app.keys["key.backspace"].press(forDuration: 0.01)
            XCTAssertEqual(editor.value as? String, "")
        }
    }

    func testNativeMiddleWordDeletionPreservesSurroundings() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        for word in ["qrmenü", "kalem"] {
            for token in ["önce", word, "sonra"] {
                for ch in token { app.keys["key.\(ch)"].tap() }
                app.keys["key.space"].tap()
            }
            func currentText() -> String {
                ((editor.value as? String) ?? "").lowercased(with: Locale(identifier: "tr_TR"))
            }
            XCTAssertEqual(currentText(), "önce " + word + " sonra ")
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85, dy: 16)).doubleTap()
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", word)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 5), "The middle word must be selected")
            app.keys["key.backspace"].press(forDuration: 0.01)
            // UIKit removes adjacent spacing here; the system-keyboard control
            // verifies the same text and caret behavior in this host.
            XCTAssertEqual(currentText(), "önce sonra ")
            app.keys["key.x"].tap()
            XCTAssertEqual(currentText(), "öncex sonra ")
            app.keys["key.backspace"].press(forDuration: 0.01)
            XCTAssertEqual(currentText(), "önce sonra ")
            // Select the entire paragraph to reset using the same native path.
            editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            app.keys["key.backspace"].press(forDuration: 0.01)
            XCTAssertEqual(currentText(), "")
        }
    }

    func testSystemMiddleWordDeletionControl() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        for word in ["qrmenü"] {
            for token in ["önce", word, "sonra"] {
                for ch in token { app.keys["key.\(ch)"].tap() }
                app.keys["key.space"].tap()
            }
            func currentText() -> String {
                ((editor.value as? String) ?? "").lowercased(with: Locale(identifier: "tr_TR"))
            }
            XCTAssertEqual(currentText(), "önce " + word + " sonra ")
            let systemDelete = app.keys["delete"]
            for _ in 0..<3 where !systemDelete.exists {
                let globe = app.buttons.matching(NSPredicate(format:
                    "label IN {'Next keyboard', 'Sonraki klavye', 'Diğer klavye'}")).firstMatch
                XCTAssertTrue(globe.exists); globe.tap()
            }
            XCTAssertTrue(systemDelete.waitForExistence(timeout: 5))
            XCTAssertFalse(app.keys["key.q"].exists)
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85, dy: 16)).doubleTap()
            systemDelete.tap()
            XCTAssertEqual(currentText(), "önce sonra ")
            app.keys["x"].tap()
            XCTAssertEqual(currentText(), "öncex sonra ")
            systemDelete.tap()
            XCTAssertEqual(currentText(), "önce sonra ")
            // Select the entire paragraph to reset using the same native path.
            editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            systemDelete.tap()
            XCTAssertEqual(currentText(), "")
        }
    }

    func testNativeCircumflexWordsSurvivePlaneChangesAndSpace() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        var expected = ""
        for word in ["kârımızdan", "resmî", "sükûn", "hikâyelerden"] {
            for ch in word {
                if "âîû".contains(ch) {
                    if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                    if !app.keys["key.â"].exists { app.keys["key.symbols"].tap() }
                } else if !app.keys["key.q"].exists {
                    app.keys["key.letters"].tap()
                }
                app.keys["key.\(ch)"].tap()
                expected.append(ch)
                XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
            }
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
            app.keys["key.backspace"].press(forDuration: 0.01); expected.removeLast()
            XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
        }
    }

    func testNativeLockedShiftAppliesToCircumflexSymbols() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        var expected = ""
        app.keys["key.shift"].doubleTap()
        for word in ["kâr", "resmî", "sükûn"] {
            for ch in word {
                if "âîû".contains(ch) {
                    if app.keys["key.q"].exists { app.keys["key.numbers"].tap() }
                    if !app.keys["key.â"].exists { app.keys["key.symbols"].tap() }
                } else if !app.keys["key.q"].exists {
                    app.keys["key.letters"].tap()
                }
                app.keys["key.\(ch)"].tap()
                expected += String(ch).uppercased(with: Locale(identifier: "tr_TR"))
                XCTAssertEqual(editor.value as? String, expected)
            }
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 3))
            app.keys["key.backspace"].press(forDuration: 0.01); expected.removeLast()
            XCTAssertEqual(editor.value as? String, expected)
            app.keys["key.space"].tap(); expected += " "
            XCTAssertEqual(editor.value as? String, expected)
        }
    }

    func testNativeCircumflexConsumesOneShotShift() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
        XCTAssertEqual(app.keys["key.â"].label, "Â")
        app.keys["key.â"].tap()
        XCTAssertEqual(editor.value as? String, "Â")
        XCTAssertEqual(app.keys["key.â"].label, "â")
        app.keys["key.letters"].tap(); app.keys["key.b"].tap()
        XCTAssertEqual(editor.value as? String, "Âb")
    }

    func testNativeCircumflexFieldImportEnablesSelectedInflectedRepair() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        let alphabet = Array("abcdefghijklmnop")
        let root = "qx" + String((0..<4).map { _ in alphabet.randomElement()! }) + "âvi"
        func typeWord(_ word: String) {
            for ch in word {
                if ch == "â" {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        for _ in 0..<3 { typeWord(root); app.keys["key.space"].tap() }
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), String(repeating: root + " ", count: 3))
        app.buttons["key.settings"].tap()
        let learn = app.buttons["Bu alandaki metinden öğren"].firstMatch
        XCTAssertTrue(learn.waitForExistence(timeout: 5)); learn.tap()
        app.buttons["Bitti"].firstMatch.tap()
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 5))
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        app.keys["key.backspace"].press(forDuration: 0.01)
        XCTAssertEqual(editor.value as? String, "")
        typeWord(root + "denbaç")
        let expected = root + "den aç"
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", expected)).firstMatch
        // Keep the live-composition observation separate from import validation.
        print("CIRCUMFLEX_LIVE_REPAIR_AVAILABLE: \(repair.exists)")
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 16)).doubleTap()
        XCTAssertTrue(repair.waitForExistence(timeout: 5), "Imported circumflex root must support the selected inflected phrase")
        repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected)
    }

    func testNativeCircumflexFieldImportEnablesLiveInflectedRepair() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        let alphabet = Array("abcdefghijklmnop")
        let root = "qx" + String((0..<4).map { _ in alphabet.randomElement()! }) + "âvi"
        func typeWord(_ word: String) {
            for ch in word {
                if ch == "â" {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        for _ in 0..<3 { typeWord(root); app.keys["key.space"].tap() }
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), String(repeating: root + " ", count: 3))
        app.buttons["key.settings"].tap()
        let learn = app.buttons["Bu alandaki metinden öğren"].firstMatch
        XCTAssertTrue(learn.waitForExistence(timeout: 5)); learn.tap()
        app.buttons["Bitti"].firstMatch.tap()
        XCTAssertTrue(app.keys["key.q"].waitForExistence(timeout: 5))
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        app.keys["key.backspace"].press(forDuration: 0.01)
        XCTAssertEqual(editor.value as? String, "")
        typeWord(root + "denbaç")
        let expected = root + "den aç"
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", expected)).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 5), "Imported circumflex root must support the live inflected phrase")
        repair.tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")), expected + " ")
    }

    func testNativeCircumflexOriginalPickLearnsWholeWord() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        func typeWord(_ word: String) {
            for ch in word {
                if "âîû".contains(ch) {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        let alphabet = Array("abcdefghijklmnop")
        for (ending, suffix) in [("âvi", "den"), ("îlo", "dan"), ("ûnu", "dan")] {
            let root = "qx" + String((0..<4).map { _ in alphabet.randomElement()! }) + ending
            typeWord(root)
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", root)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 5)); literal.tap()
            XCTAssertTrue((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")).hasSuffix(root + " ") == true)
            typeWord(root + suffix + "baç")
            let expected = root + suffix + " aç"
            let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", expected)).firstMatch
            XCTAssertTrue(repair.waitForExistence(timeout: 5), "Explicit original pick must admit the whole root: \(root)")
            repair.tap()
            XCTAssertTrue((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")).hasSuffix(expected + " ") == true)
        }
    }

    func testNativeLockedShiftCircumflexWholeWordLearning() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        app.keys["key.shift"].doubleTap()
        func typeWord(_ word: String) {
            for ch in word {
                if "âîû".contains(ch) {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        let alphabet = Array("abcdefghijklmnop")
        for (ending, suffix) in [("âvi", "den"), ("îlo", "dan"), ("ûnu", "dan")] {
            let root = "qx" + String((0..<4).map { _ in alphabet.randomElement()! }) + ending
            typeWord(root)
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", root)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 5)); literal.tap()
            XCTAssertTrue((editor.value as? String)?.hasSuffix(root.uppercased(with: Locale(identifier: "tr_TR")) + " ") == true)
            typeWord(root + suffix + "baç")
            let expected = root + suffix + " aç"
            let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", expected)).firstMatch
            XCTAssertTrue(repair.waitForExistence(timeout: 5), "Explicit original pick must admit the whole root: \(root)")
            repair.tap()
            XCTAssertTrue((editor.value as? String)?.hasSuffix(expected.uppercased(with: Locale(identifier: "tr_TR")) + " ") == true)
        }
    }

    func testNativeWrappedCircumflexOriginalAndRepair() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        func typeWord(_ word: String) {
            for ch in word {
                if "âîû".contains(ch) {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
        }
        let alphabet = Array("abcdefghijklmnop")
        for (opening, ending, suffix) in [("(", "âvi", "den"), ("\"", "îlo", "dan"), ("'", "ûnu", "dan")] {
            let root = "qx" + String((0..<4).map { _ in alphabet.randomElement()! }) + ending
            app.keys["key.numbers"].tap(); app.keys["key." + opening].tap()
            app.keys["key.letters"].tap()
            typeWord(root)
            let literal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", root)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 5)); literal.tap()
            XCTAssertTrue((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")).hasSuffix(opening + root + " ") == true)
            app.keys["key.numbers"].tap(); app.keys["key." + opening].tap()
            app.keys["key.letters"].tap()
            typeWord(root + suffix + "baç")
            let expected = root + suffix + " aç"
            let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[cd] %@", "suggestion.", expected)).firstMatch
            XCTAssertTrue(repair.waitForExistence(timeout: 5), "Explicit original pick must admit the whole root: \(root)")
            repair.tap()
            XCTAssertTrue((editor.value as? String)?.lowercased(with: Locale(identifier: "tr_TR")).hasSuffix(opening + expected + " ") == true)
        }
    }

    func testNativeSelectedCircumflexCapsKeepAlternatives() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        app.keys["key.shift"].doubleTap()
        for word in ["resmî", "millî", "dinî", "fiilî"] {
            for ch in word {
                if ch == "î" {
                    app.keys["key.numbers"].tap(); app.keys["key.symbols"].tap()
                } else if !app.keys["key.q"].exists { app.keys["key.letters"].tap() }
                app.keys["key.\(ch)"].tap()
            }
            app.keys["key.space"].tap()
            let expected = word.uppercased(with: Locale(identifier: "tr_TR"))
            XCTAssertEqual(editor.value as? String, expected + " ")
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 16)).doubleTap()
            let original = app.buttons["suggestion.0"]
            XCTAssertTrue(original.waitForExistence(timeout: 5))
            XCTAssertEqual(original.label, expected)
            let alternative = app.buttons["suggestion.1"]
            XCTAssertTrue(alternative.exists && alternative.isHittable)
            XCTAssertFalse(alternative.label.isEmpty)
            original.tap()
            app.keys["key.x"].tap()
            XCTAssertEqual(editor.value as? String, expected + "X ")
            editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            app.keys["key.backspace"].press(forDuration: 0.01)
            XCTAssertEqual(editor.value as? String, "")
        }
    }

    func testNativeParagraphSelectionKeepsTitleCaseWithLeadingSpace() throws {
        let app = XCUIApplication(); app.launch()
        let learning = app.staticTexts["Öğrenme"].firstMatch
        XCTAssertTrue(learning.waitForExistence(timeout: 10)); learning.tap()
        let paste = app.staticTexts["Metin yapıştır"].firstMatch
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        paste.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        guard app.switchToBestKeyboard(until: app.keys["key.q"]) else {
            XCTFail("BestKeyboard extension is not active"); return
        }
        app.keys["key.space"].tap()
        for ch in "kalen" { app.keys["key.\(ch)"].tap() }
        XCTAssertEqual(editor.value as? String, " Kalen")
        editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[c] %@", "suggestion.", "kalem")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        XCTAssertEqual(editor.value as? String, " Kalem")
        app.keys["key.space"].tap(); app.keys["key.x"].tap()
        XCTAssertEqual(editor.value as? String, " Kalem x")
    }

    func testTechnicalSymbolKeysAreReachable() {
        let app = launchReadyHarness()
        let keyboard = app.otherElements["harness.keyboard"]
        keyboard.keys["key.numbers"].tap()
        keyboard.keys["key.symbols"].tap()
        for id in ["key.`", "key.â", "key.î", "key.û", "key.tab"] {
            XCTAssertTrue(keyboard.keys[id].exists, id)
        }
    }
}
