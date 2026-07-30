import XCTest

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

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestHarness", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["harness.keyboard"].waitForExistence(timeout: 10),
                      "klavye görünümü yok")
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
