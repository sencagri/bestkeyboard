import XCTest
import EventKit

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

    /// Simülatörün "… içinde açılsın mı?" sorusu.
    private func openURL(_ s: String) {
        XCUIDevice.shared.system.open(URL(string: s)!)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = sb.buttons.matching(NSPredicate(format: "label IN {'Open', 'Aç'}")).firstMatch
        if open.waitForExistence(timeout: 4) { open.tap() }
    }

    func testReminderHandoff() throws {
        let app = XCUIApplication()
        app.launch()
        let due = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970)
        openURL("bestkeyboard://hatirlatici?title=Kad%C4%B1k%C3%B6y%27de%20Tolga%20ile%20bulu%C5%9Fma&due=\(due)&notes=Bilet%20Tolga%27da")
        let done = app.staticTexts["Hatırlatıcılar’a eklendi"]
        let ok = done.waitForExistence(timeout: 10)
        attach("26-uygulama-ekledi")
        XCTAssertTrue(ok, "hatırlatıcı eklenmedi")
        // "Hatırlatıcılar’da aç" Apple'ın kendi uygulamasını açmalı.
        app.buttons["Hatırlatıcılar’da aç"].tap()
        let rem = XCUIApplication(bundleIdentifier: "com.apple.reminders")
        XCTAssertTrue(rem.wait(for: .runningForeground, timeout: 8), "Hatırlatıcılar açılmadı")
        sleep(2)
        attach("26-hatirlaticilar")
    }

    func testShortcutRoundTrip() throws {
        let app = XCUIApplication()
        app.launch()
        // Başarılı dönüş: sonuç panoya.
        openURL("bestkeyboard://kestirme-sonuc?result=MERHABA%20D%C3%9CNYA")
        XCTAssertTrue(app.staticTexts["Sonuç panoya kondu"].waitForExistence(timeout: 8))
        attach("27-sonuc")
        app.buttons["Kapat"].tap()
        // Kestirmeler'e gerçek gidiş: olmayan bir kestirme — Kestirmeler hata ile geri döndürmeli.
        openURL("shortcuts://x-callback-url/run-shortcut?name=BestKeyboardYok&input=text&text=deneme&x-success=bestkeyboard://kestirme-sonuc&x-error=bestkeyboard://kestirme-sonuc?hata=1")
        sleep(6)
        attach("27-kestirmeler")
        let back = app.staticTexts["Kestirme çalışmadı"].waitForExistence(timeout: 10)
        attach("27-hata-donusu")
        XCTAssertTrue(back, "Kestirmeler hata dönüşü gelmedi")
    }

    /// Uygulamanın eklediği hatırlatıcı gerçekten Hatırlatıcılar'da mı —
    /// başlık, not, vade ve alarm (`testReminderHandoff`'tan sonra).
    func testReminderStored() async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw XCTSkip("Hatırlatıcılar izni yok") }
        let pred = store.predicateForReminders(in: nil)
        let all: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
        }
        let mine = all.filter { $0.title == "Kadıköy'de Tolga ile buluşma" }
        print("BULUNAN:", mine.map { "\($0.title ?? "") | not=\($0.notes ?? "-") | vade=\(String(describing: $0.dueDateComponents?.date)) | alarm=\($0.alarms?.count ?? 0)" })
        let r = try XCTUnwrap(mine.last)
        XCTAssertEqual(r.notes, "Bilet Tolga'da")
        XCTAssertNotNil(r.dueDateComponents?.hour)
        XCTAssertEqual(r.alarms?.count, 1)
    }

    /// Ana ekranda uygulama simgesi.
    func testHomeScreenIcon() {
        XCUIDevice.shared.press(.home)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sleep(1)
        let icon = sb.icons["BestKeyboard"]
        for _ in 0..<3 where !(icon.exists && icon.isHittable) { sb.swipeLeft(); sleep(1) }
        attach("simge-ana-ekran")
    }
}
