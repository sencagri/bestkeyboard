import XCTest

/// UI testlerinin ortak adımları — her test dosyası kendi kopyasını tutuyordu.
extension XCUIApplication {
    /// Uygulamayı **klavye tezgahıyla** açar (`-uiTestHarness`): uzantı
    /// gerekmeden klavye görünümü ekranda.
    static func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestHarness", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["harness.keyboard"].waitForExistence(timeout: 10),
                      "klavye görünümü yok")
        return app
    }

    /// Ana ekrandaki deneme alanı (metin görünümü ya da alanı).
    var editableField: XCUIElement {
        textViews.firstMatch.exists ? textViews.firstMatch : textFields.firstMatch
    }

    /// Sistem klavyesi açıksa 🌐 ile BestKeyboard'a geçer; `marker` (klavyeye
    /// özgü bir düğme) görünene kadar en çok üç kez dener.
    @discardableResult
    func switchToBestKeyboard(until marker: XCUIElement) -> Bool {
        for _ in 0..<3 where !marker.waitForExistence(timeout: 2) {
            let globe = buttons.matching(NSPredicate(format:
                "label IN {'Next keyboard', 'Sonraki klavye', 'Diğer klavye'}")).firstMatch
            guard globe.exists else { break }
            globe.tap()
        }
        return marker.exists
    }
}
