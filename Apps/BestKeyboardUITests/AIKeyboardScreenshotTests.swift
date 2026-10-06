import XCTest
import EventKit
import Contacts

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
        // Klavyenin gönderdiği plan: üç ayrı madde (tasarım 26 · videodaki alışveriş mesajı).
        let due = Date().addingTimeInterval(86_400).timeIntervalSinceReferenceDate
        let plan = #"{"list":"Alışveriş","items":[{"title":"8 yumurta"},{"title":"5 kedi maması"},{"title":"4 süt","due":\#(due)}]}"#
        let b64 = Data(plan.utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        openURL("bestkeyboard://hatirlatici?plan=\(b64)")
        let done = app.staticTexts["3 madde eklendi"]
        let ok = done.waitForExistence(timeout: 10)
        attach("26-uygulama-ekledi")
        XCTAssertTrue(ok, "maddeler eklenmedi")
        // "Hatırlatıcılar’da aç" Apple'ın kendi uygulamasını açmalı.
        app.buttons["Hatırlatıcılar’da aç"].tap()
        let rem = XCUIApplication(bundleIdentifier: "com.apple.reminders")
        XCTAssertTrue(rem.wait(for: .runningForeground, timeout: 8), "Hatırlatıcılar açılmadı")
        sleep(2)
        attach("26-hatirlaticilar")
    }

    /// Maddeler Hatırlatıcılar'da **ayrı ayrı** mı (`testReminderHandoff`'tan sonra).
    func testReminderStored() async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw XCTSkip("Hatırlatıcılar izni yok") }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let all: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
        }
        let titles = Set(all.compactMap(\.title))
        print("BULUNAN:", titles.sorted())
        for t in ["8 yumurta", "5 kedi maması", "4 süt"] { XCTAssertTrue(titles.contains(t), "\(t) yok") }
        // "Alışveriş" listesi yoktu: uygulama açmış ve maddeler onun içinde olmalı.
        print("LİSTELER:", all.filter { $0.title == "8 yumurta" }.map(\.calendar.title))
        XCTAssertTrue(all.contains { $0.title == "8 yumurta" && $0.calendar.title == "Alışveriş" },
                      "Alışveriş listesi açılmamış ya da maddeler içine eklenmemiş")
        let sut = try XCTUnwrap(all.last { $0.title == "4 süt" })
        XCTAssertNotNil(sut.dueDateComponents?.hour)
        XCTAssertEqual(sut.alarms?.count, 1)
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

    /// Ana ekranda uygulama simgesi.
    func testHomeScreenIcon() {
        XCUIDevice.shared.press(.home)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sleep(1)
        let icon = sb.icons["BestKeyboard"]
        for _ in 0..<3 where !(icon.exists && icon.isHittable) { sb.swipeLeft(); sleep(1) }
        attach("simge-ana-ekran")
    }

    /// Eklenince bildirim çıkıyor, dokununca Hatırlatıcılar o maddeyle açılıyor.
    func testReminderNotification() throws {
        let app = XCUIApplication()
        app.launch()
        let plan = #"{"items":[{"title":"Kedi maması al"}]}"#
        let b64 = Data(plan.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        openURL("bestkeyboard://hatirlatici?plan=\(b64)")
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = sb.buttons.matching(NSPredicate(format: "label IN {'Allow', 'İzin Ver'}")).firstMatch
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let banner = sb.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hatırlatıcı eklendi'")).firstMatch
        let shown = banner.waitForExistence(timeout: 8)
        attach("bildirim")
        XCTAssertTrue(shown, "bildirim çıkmadı")
        banner.tap()
        let rem = XCUIApplication(bundleIdentifier: "com.apple.reminders")
        XCTAssertTrue(rem.wait(for: .runningForeground, timeout: 8), "Hatırlatıcılar açılmadı")
        sleep(2)
        attach("bildirim-dokununca")
    }

    /// Mesajlar'da BestKeyboard çekmecesi (iMessage eklentisi) stüdyo öğelerini gösteriyor mu.
    func testMessagesStickerDrawer() throws {
        let msgs = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        msgs.launch()
        sleep(2)
        attach("msg-1-acilis")
        // Simülatörde hazır sohbetler var: ilkini aç.
        let chat = msgs.cells.firstMatch
        guard chat.waitForExistence(timeout: 5) else { throw XCTSkip("sohbet yok") }
        chat.tap()
        sleep(2)
        attach("msg-2-yeni")
        // "+" sol altta; etiketi sürüme göre değişiyor, konumdan dokunuluyor.
        msgs.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.943)).tap()
        sleep(2)
        attach("msg-3-arti")
        let more = msgs.descendants(matching: .any).matching(NSPredicate(format: "label IN {'More', 'Daha Fazla'}")).firstMatch
        if more.exists { more.tap(); sleep(2) }
        attach("msg-4-menu")
        let ours = msgs.buttons.matching(NSPredicate(format: "label CONTAINS 'BestKeyboard'")).firstMatch
        let any = msgs.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'BestKeyboard'")).firstMatch
        XCTAssertTrue(ours.waitForExistence(timeout: 3) || any.exists, "BestKeyboard + menüsünde yok")
        if ours.exists { ours.tap() } else { any.tap() }
        sleep(3)
        attach("msg-5-cekmece")
        // Çekmecede stüdyo öğeleri çıkartma olarak listeleniyor.
        XCTAssertGreaterThan(msgs.descendants(matching: .any).matching(NSPredicate(format: "label IN {'GIF', 'Çıkartma'}")).count, 0,
                             "çekmecede çıkartma yok")
    }

    /// Takvim etkinliği ve kişi gerçekten yazılıyor mu (uygulamadaki makers).
    func testEventAndContactMakers() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-makerSelfTest"]
        app.launch()
        sleep(5)
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw XCTSkip("Takvim izni yok") }
        let pred = store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(9 * 86_400), calendars: nil)
        let ev = store.events(matching: pred).last { $0.title == "Annemi otogardan al" }
        XCTAssertNotNil(ev, "etkinlik yok")
        XCTAssertEqual(ev?.location, "Kadıköy otogarı")
        XCTAssertEqual(ev.map { Calendar.current.component(.hour, from: $0.startDate) }, 19)
        XCTAssertEqual(ev.map { Calendar.current.component(.weekday, from: $0.startDate) }, 7)
        XCTAssertEqual(ev?.alarms?.count, 1)
        let cs = CNContactStore()
        guard try await cs.requestAccess(for: .contacts) else { throw XCTSkip("Kişiler izni yok") }
        let found = try cs.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "Ahmet Deneme"),
                                           keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor])
        XCTAssertFalse(found.isEmpty, "kişi yok")
        XCTAssertEqual(found.last?.phoneNumbers.first?.value.stringValue, "0532 000 00 00")
    }
}
