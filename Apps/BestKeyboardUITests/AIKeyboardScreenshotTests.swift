import XCTest

/// Yapay zeka kartının **gerçek klavyede** ekran görüntüleri (tasarım 22–23).
///
/// Simülatörde BestKeyboard etkin klavye değilse atlanıyor: CI'da ve klavye
/// eklenmemiş bir makinede başarısız sayılmasın.
final class AIKeyboardScreenshotTests: XCTestCase {
    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testAICardAndSlashCommand() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let springboardKeyboard = app.buttons["Yapay zeka tuşları"]
        // Sistem klavyesi açıksa 🌐 ile BestKeyboard'a geç.
        for _ in 0..<3 where !springboardKeyboard.waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format:
                "label IN {'Next keyboard', 'Sonraki klavye', 'Diğer klavye'}")).firstMatch
            guard globe.exists else { break }
            globe.tap()
        }
        guard springboardKeyboard.waitForExistence(timeout: 8) else {
            attach("klavye-yok")
            throw XCTSkip("BestKeyboard etkin klavye değil")
        }
        field.typeText("yarın akşam müsaitim, yedide buluşalım")
        springboardKeyboard.tap()
        sleep(1)
        attach("22-kart-sec")

        // Kart açıkken çubuk erişilebilirlikten gizli; kart kendi düğmesiyle kapanıyor.
        app.buttons["Kartı kapat"].tap()
        sleep(1)
        // `/çe` **klavyenin kendi tuşlarıyla**: `typeText` metni klavyeyi
        // atlayarak yazıyor ve uzantı değişikliği hiç duymuyordu.
        func key(_ label: String) -> XCUIElement {
            app.keys.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        app.keys["key.space"].tap()
        app.keys["key.numbers"].tap()
        key("/").tap()
        if !key("ç").exists { app.keys["key.letters"].tap() }
        key("ç").tap()
        key("e").tap()
        sleep(1)
        attach("23-slash")
    }

    func testFancyFonts() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let aa = app.buttons["Fontlu yazı"]
        for _ in 0..<3 where !aa.waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format:
                "label IN {'Next keyboard', 'Sonraki klavye', 'Diğer klavye'}")).firstMatch
            guard globe.exists else { break }
            globe.tap()
        }
        guard aa.exists else { throw XCTSkip("BestKeyboard etkin klavye değil") }
        aa.tap()
        sleep(1)
        for id in ["key.letter.10", "key.letter.11", "key.letter.12"] where app.keys[id].exists { app.keys[id].tap() }
        // Harf kimlikleri bilinmiyorsa ilk üç harf tuşu.
        let letters = app.keys.matching(NSPredicate(format: "identifier BEGINSWITH 'key.' AND NOT identifier BEGINSWITH 'key.numRow'"))
        for i in 0..<min(4, letters.count) { letters.element(boundBy: i).tap() }
        sleep(1)
        attach("24-fontlu")
    }
}
