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
        // Eşik `cadence.initialDelay` (0.45 sn); 0.9 rahatça aşıyor.
        period.press(forDuration: 0.9)
        usleep(200_000)
        XCTAssertEqual(app.staticTexts["harness.literal"].label, "literal: kalem,",
                       "uzun basma virgül üretmeli ve noktayı bastırmalı")
    }
}
