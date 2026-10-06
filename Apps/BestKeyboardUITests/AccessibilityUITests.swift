import XCTest

/// Tuş yüzeyinin **erişilebilirlik ağacı** — gerçek bir istemciyle okunuyor.
///
/// ## Neden bu testler var
///
/// §8.9'un tamamı `swift test` altında koşamıyor: etiketler, `keyboardKey`
/// niteliği ve öğe listesinin ne zaman kurulduğu UIKit'e ait ve `Apps/`
/// hedefinde birim testi yok. O yüzden bunlar kodu **okuyarak** doğrulanmıştı,
/// ve o tur boyunca üç ayrı kusur tam da okuyarak bulundu — yani okuma yeterli
/// bir yöntem değil.
///
/// XCUITest gerçek bir erişilebilirlik istemcisi: ağacı VoiceOver'ın sorduğu
/// yoldan soruyor. Bu, cihazda VoiceOver turunun yerini **tutmaz** ama
/// aralarındaki boşluğu daraltıyor.
///
/// ## Neyi kapsamıyor
///
/// `accessibilityActivate()` yolunu **sınamıyor**: XCUITest `.tap()` gerçek bir
/// dokunma sentezliyor, yani `touchesBegan/Ended`'den geçiyor. Sentetik kanıt
/// yolunun kendisi `InputCoordinatorTests`'te (`swift test`) kapalı; burada
/// sınanan şey öğelerin **var olduğu, doğru adlandığı ve doğru zamanda
/// güncellendiği**.
final class AccessibilityUITests: XCTestCase {

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestHarness", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["harness.keyboard"].waitForExistence(timeout: 10),
                      "klavye görünümü yok")
        return app
    }

    /// İşlev tuşları **Türkçe** okunuyor, enum adıyla değil.
    ///
    /// Etiketler eskiden `"\(fk)"` ile üretiliyordu: ekran okuyucu Türkçe
    /// konuşan kullanıcıya `shift`, `backspace`, `numbers` diyordu. Kimlik
    /// (`key.shift`) XCUITest'in, etiket kullanıcının — test ikisinin
    /// **ayrıldığını** da sabitliyor: kimlikle bulup etikete bakıyor.
    func testFunctionKeysAreLabelledInTurkish() throws {
        let app = launchHarness()
        let kb = app.otherElements["harness.keyboard"]
        let expected = ["key.shift": "büyük harf",
                        "key.backspace": "sil",
                        "key.space": "boşluk",
                        "key.numbers": "rakamlar",
                        "key.ret": "satır sonu",
                        // Nokta da işlev yuvasında duruyor ama kullanıcı için
                        // sıradan bir karakter tuşu; "period" diye okunması
                        // enum adının sızması olurdu.
                        "key.period": "nokta"]
        for (id, label) in expected {
            let key = kb.keys[id]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "tuş yok: \(id)")
            XCTAssertEqual(key.label, label, "\(id) yanlış okunuyor")
        }
    }

    /// Harf etiketi shift'i **izliyor**.
    ///
    /// Tuşun üstünde `A` yazarken ekran okuyucunun `a` demesi, kullanıcıyı hangi
    /// harfin çıkacağı konusunda yanıltır. Bu test aynı zamanda öğe listesinin
    /// tembel kurulumunun **doğru zamanda** geçersizleştiğini sınıyor: liste
    /// shift değişiminde bayatlamıyorsa eski etiket okunurdu.
    func testLetterLabelFollowsShift() throws {
        let app = launchHarness()
        let kb = app.otherElements["harness.keyboard"]
        let a = kb.keys["key.a"]
        XCTAssertTrue(a.waitForExistence(timeout: 3))
        XCTAssertEqual(a.label, "a", "shift kapalıyken küçük harf okunmalı")

        kb.keys["key.shift"].tap()
        usleep(200_000)
        // Kimlik **değişmiyor**, etiket değişiyor: XCUITest sabitleri shift'e
        // göre kaymamalı.
        XCTAssertEqual(kb.keys["key.a"].label, "A",
                       "shift açıkken büyük harf okunmalı — öğe listesi bayat")
    }

    /// Düzlem değişince öğeler **yenileniyor**.
    ///
    /// `123`'e basınca bütün tuşlar değişiyor. Liste tembel kurulduğu için asıl
    /// risk geçersizleştirmeyi atlamak: eski harf öğeleri ayakta kalırsa
    /// kullanıcı harf sandığı yerde sembol yazar.
    func testPlaneSwitchReplacesTheElements() throws {
        let app = launchHarness()
        let kb = app.otherElements["harness.keyboard"]
        XCTAssertTrue(kb.keys["key.a"].waitForExistence(timeout: 3))

        kb.keys["key.numbers"].tap()
        usleep(300_000)
        // Harf düzlemi gitti: `a` artık yok, `123` yerine `ABC` var.
        XCTAssertFalse(kb.keys["key.a"].exists, "harf öğesi rakam düzleminde kaldı")
        // Nokta yuvası da gitti: rakam düzleminin kendi satırında zaten bir `.`
        // var ve ikincisi çizilmiyor. Öğe kalsaydı **görünmeyen** bir tuşa
        // basılabilirdi — panel arkasındaki tuşlarla aynı kusur.
        XCTAssertFalse(kb.keys["key.period"].exists,
                       "nokta yuvası rakam düzleminde kaldı")
        XCTAssertTrue(kb.keys["key.letters"].exists, "ABC tuşu yok")
        XCTAssertEqual(kb.keys["key.letters"].label, "harfler")

        kb.keys["key.letters"].tap()
        usleep(300_000)
        XCTAssertTrue(kb.keys["key.a"].waitForExistence(timeout: 3),
                      "harf düzlemine dönülünce öğeler geri gelmedi")
    }

    /// Her tuşun `keyboardKey` niteliği var.
    ///
    /// VoiceOver klavye tuşlarını bu nitelikle tanıyor; düğme sayılan bir tuş
    /// dokunarak yazma kipinde farklı davranır. XCUITest niteliği doğrudan
    /// okutmuyor ama `.keys` sorgusu tam da onunla eşleşiyor — yani sorgunun
    /// harfleri bulması niteliğin durduğunun kanıtı.
    func testKeysAreExposedAsKeyboardKeys() throws {
        let app = launchHarness()
        let kb = app.otherElements["harness.keyboard"]
        XCTAssertTrue(kb.keys["key.a"].waitForExistence(timeout: 3))
        // Türkçe düzenin tamamı: 29 harf. Eksik biri, dokunulamayan bir tuş.
        for ch in "abcçdefgğhıijklmnoöprsştuüvyz" {
            XCTAssertTrue(kb.keys["key.\(ch)"].exists, "tuş öğesi yok: \(ch)")
        }
    }
}
