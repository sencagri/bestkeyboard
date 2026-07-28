import XCTest

/// Uçtan uca dikey dilim testi: gerçek UIKit dokunma olayları →
/// normalize koordinat → uzamsal model → beam search → öneri.
///
/// Erişilebilirlik kimliği yerine **normalize koordinatla** dokunur; test
/// edilen şey zaten uzamsal yol olduğu için en sadık yöntem budur.
final class DecodeUITests: XCTestCase {

    /// Türkçe Q'da harflerin klavye görünümü içindeki normalize konumu.
    /// `KeyLayout` ile aynı geometri: R1 12 tuş, R2 11 tuş, R3 9 tuş ortalanmış,
    /// 4 satır (son satır işlev tuşları).
    private static let row1 = Array("qwertyuıopğü")
    private static let row2 = Array("asdfghjklşi")
    private static let row3 = Array("zxcvbnmöç")

    private func normalizedPoint(for ch: Character) -> CGVector {
        let rowH = 0.25
        if let i = Self.row1.firstIndex(of: ch) {
            return CGVector(dx: (Double(i) + 0.5) / 12.0, dy: rowH * 0.5)
        }
        if let i = Self.row2.firstIndex(of: ch) {
            return CGVector(dx: (Double(i) + 0.5) / 11.0, dy: rowH * 1.5)
        }
        if let i = Self.row3.firstIndex(of: ch) {
            let w = 1.0 / 11.0
            let xStart = (1.0 - 9.0 * w) / 2.0
            return CGVector(dx: xStart + (Double(i) + 0.5) * w, dy: rowH * 2.5)
        }
        XCTFail("layout'ta olmayan karakter: \(ch)")
        return .zero
    }

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestHarness", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["harness.keyboard"].waitForExistence(timeout: 10),
                      "klavye görünümü yok")
        // Paketin yüklenmesini bekle.
        let status = app.staticTexts["harness.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !(status.label.contains("paket hazır")) {
            usleep(200_000)
        }
        XCTAssertTrue(status.label.contains("paket hazır"), "paket yüklenmedi: \(status.label)")
        return app
    }

    private func type(_ s: String, in app: XCUIApplication) {
        let kb = app.otherElements["harness.keyboard"]
        for ch in s {
            kb.coordinate(withNormalizedOffset: normalizedPoint(for: ch)).tap()
            usleep(80_000)
        }
    }

    /// Kanonik vaka — projenin varlık sebebi.
    func testLslemDecodesToKalem() throws {
        let app = launchHarness()
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
        let app = launchHarness()
        type("guzel", in: app)
        XCTAssertEqual(app.staticTexts["harness.top"].label, "güzel",
                       "adaylar: \(app.staticTexts["harness.all"].label)")
    }

    /// Doğru yazılmış kelime bozulmamalı.
    func testExactWordUnchanged() throws {
        let app = launchHarness()
        type("kitap", in: app)
        XCTAssertEqual(app.staticTexts["harness.top"].label, "kitap",
                       "adaylar: \(app.staticTexts["harness.all"].label)")
    }
}
