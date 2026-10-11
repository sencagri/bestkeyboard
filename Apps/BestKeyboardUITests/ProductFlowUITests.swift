import XCTest
import UIKit
import AVFoundation

/// Uygulama ekranlarında gerçek kullanıcı akışları; yalnız görünümü değil,
/// ayarların korunmasını ve deneme alanlarının sonucunu da doğrular.
final class ProductFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @discardableResult
    private func open(_ route: String, textSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-bkScreen", route,
                               "-UIPreferredContentSizeCategoryName", textSize]
        if route == "dikte" { app.launchArguments += ["-dikteDemo", "Yarın akşam buluşalım."] }
        app.launch()
        XCTAssertTrue(page(in: app).waitForExistence(timeout: 10))
        return app
    }

    private func page(in app: XCUIApplication) -> XCUIElement {
        let screen = app.scrollViews["screen.scroll"].firstMatch
        return screen.exists ? screen : app.scrollViews.firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 24, fullyVisible: Bool = false) {
        for _ in 0..<limit {
            if !fullyVisible && element.isHittable { return }
            let scroll = page(in: app)
            let top = max(scroll.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let keyboard = app.keyboards.firstMatch
            let footer = app.buttons["maker.primary"]
            let bottom = min(scroll.frame.maxY,
                             keyboard.exists ? keyboard.frame.minY : app.windows.firstMatch.frame.maxY,
                             footer.exists ? footer.frame.minY : app.windows.firstMatch.frame.maxY)
            if element.isHittable && element.frame.minY >= top + 4 && element.frame.maxY <= bottom - 4 { return }
            let height = max(44, bottom - top)
            let above = element.exists && (fullyVisible ? element.frame.minY < top + 4 : element.frame.midY <= top)
            // Kenardan kaydır: GIF kesicinin sürükleme hareketini tetikleme.
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            let x = scroll.frame.minX + scroll.frame.width * 0.97
            origin.withOffset(CGVector(dx: x, dy: top + height * (above ? 0.45 : 0.85)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: top + height * (above ? 0.85 : 0.45))))
        }
        shot("unreachable-control")
        XCTFail("Denetime \(fullyVisible ? "tam görünür" : "dokunulabilir") olarak ulaşılamadı: \(element)")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFullAccessClipboardTextRoundtrip() throws {
        let sample = "Pano denemesi: Türkçe ığüşöç 123"
        UIPasteboard.general.string = sample
        let app = XCUIApplication()
        app.launchArguments = ["-nativeKeyboardFixture"]
        app.launch()
        app.buttons["native.fixture"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowPaste = springboard.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 5) { allowPaste.tap() }
        app.textViews["native.editor"].tap()
        app.textViews["native.editor"].typeText(" ")
        _ = app.buttons["key.emoji"].waitForExistence(timeout: 5)
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.emoji"]))
        app.buttons["key.emoji"].tap()
        app.buttons["Pano geçmişi"].tap()
        // İzni test değiştirmez; önceden onaylanmış test cihazında çalışır.
        let needsAccess = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Pano geçmişi için Ayarlar")).firstMatch
        try XCTSkipIf(needsAccess.exists, "Requires Full Access configured before the test")
        let clip = app.cells.matching(NSPredicate(format: "label == %@", "Metin: " + sample)).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        shot("clipboard-full-access-captured")
        clip.tap()
        XCTAssertTrue((app.textViews["native.editor"].value as? String ?? "").contains(sample))
        shot("clipboard-full-access-inserted")
        XCTAssertFalse(app.staticTexts["Pano geçmişi"].exists)
    }

    func testLayoutResetPreservesSoundChoice() {
        var app = open("ses")
        let mechanical = app.buttons["Mekanik"].firstMatch
        reveal(mechanical, in: app)
        mechanical.tap()
        XCTAssertTrue(mechanical.isSelected)
        app.terminate()
        app = open("duzen")
        let reset = app.buttons["Varsayılana dön"]
        reveal(reset, in: app)
        reset.tap()
        app.terminate()
        app = open("ses")
        reveal(app.buttons["Mekanik"].firstMatch, in: app)
        shot("layout-reset-preserves-sound")
        XCTAssertTrue(app.buttons["Mekanik"].firstMatch.isSelected,
                      "Düzen sıfırlaması kullanıcının ses seçimini silmemeli")
    }

    func testDeleteResetPreservesNumberRow() {
        var app = open("duzen")
        let numbers = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Sayı satırı")).firstMatch
        reveal(numbers, in: app)
        if numbers.value as? String == "1" { numbers.tap() }
        XCTAssertEqual(numbers.value as? String, "0")
        app.terminate()
        app = open("silme")
        let reset = app.buttons["Varsayılana dön"]
        reveal(reset, in: app)
        reset.tap()
        app.terminate()
        app = open("duzen")
        let reloadedNumbers = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Sayı satırı")).firstMatch
        reveal(reloadedNumbers, in: app)
        shot("delete-reset-preserves-layout")
        XCTAssertEqual(reloadedNumbers.value as? String, "0",
                       "Silme ayarlarını sıfırlamak sayı satırını değiştirmemeli")
    }

    func testShortcutCannotAddEmptyInput() {
        let app = open("kisayol")
        let add = app.buttons["+ Ekle"]
        reveal(add, in: app)
        shot("shortcut-empty-form")
        XCTAssertFalse(add.isEnabled, "Boş form etkin bir Ekle düğmesi göstermemeli")
    }

    func testShortcutPreviewReplacesText() {
        let app = open("kisayol")
        let field = app.textFields["lol, tr, :D…"]
        reveal(field, in: app)
        let suggestion = app.buttons["😂"].firstMatch
        reveal(suggestion, in: app)
        suggestion.tap()
        shot("shortcut-preview-result")
        XCTAssertEqual(field.value as? String, "😂", "Dene alanı gerçekten çıktıyı göstermeli")
    }

    func testThemeColorPaletteFitsScreen() {
        let app = open("tema")
        let solid = app.buttons["Renk"]
        reveal(solid, in: app)
        solid.tap()
        shot("theme-solid-initial")
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(app.textFields["Tema adı"].frame.minX, screen.minX + 16,
                                    "Palet bütün ekranı genişletip kenarları kırpmamalı")
        let last = app.buttons["#0B2545"].firstMatch
        let scroll = page(in: app)
        for _ in 0..<8 where !last.isHittable {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
        XCTAssertTrue(last.isHittable)
        shot("theme-color-palette")
        XCTAssertGreaterThanOrEqual(last.frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(last.frame.maxX, screen.maxX - 16,
                                 "Son renk ekranın sağ kenarının dışına taşmamalı")
        last.tap()
        XCTAssertTrue(last.isSelected)
    }

    @MainActor private func makeVideoFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                          kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<36 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 240,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(UIColor.systemTeal.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: frame * 5, y: 80, width: 60, height: 60))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    @MainActor func testGifEditsInvalidateSavedOutput() async throws {
        let url = try await makeVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.launchArguments = ["-bkScreen", "gif", "-gifSelfTest", url.path]
        app.launch()
        let ready = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hazır ✓")).firstMatch
        page(in: app).swipeUp()
        reveal(ready, in: app)
        shot("gif-created")
        XCTAssertFalse(ready.isEnabled, "Hazır düğmesi aynı GIF'i tekrar kaydetmemeli")
        let speed = app.buttons["2×"]
        page(in: app).swipeDown()
        reveal(speed, in: app)
        speed.tap()
        let make = app.buttons["GIF oluştur"]
        XCTAssertTrue(make.waitForExistence(timeout: 5), "Hız değişince eski çıktı paylaşılmamalı")
        reveal(make, in: app)
        shot("gif-speed-changed")
        XCTAssertTrue(make.isEnabled)
    }

    func testStickerSavedState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        let app = XCUIApplication()
        app.launchArguments = ["-bkScreen", "cikartma", "-stickerSelfTest", url.path, "-stickerLoadOnly"]
        app.launch()
        let save = app.buttons["Kaydet"]
        reveal(save, in: app)
        save.tap()
        let saved = app.buttons["Kaydedildi ✓"]
        reveal(saved, in: app)
        shot("sticker-created")
        XCTAssertFalse(saved.isEnabled, "Kaydedildi düğmesi kopya çıkartma oluşturmamalı")
    }

    func testShortcutCreateEditDelete() {
        let token = "ui" + UUID().uuidString.prefix(6).lowercased()
        var app = open("kisayol")
        app.textFields["ör. kedi"].tap()
        app.textFields["ör. kedi"].typeText(token)
        app.textFields["emoji ya da metin"].tap()
        app.textFields["emoji ya da metin"].typeText("merhaba")
        let add = app.buttons["+ Ekle"]
        reveal(add, in: app)
        XCTAssertTrue(add.isEnabled)
        add.tap()
        app.terminate()
        app = open("kisayol")
        let row = app.buttons["\(token), merhaba, düzenle"].firstMatch
        reveal(row, in: app)
        row.tap()
        let alert = app.alerts["Kısayolu düzenle"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let trigger = alert.textFields["yazınca"]
        trigger.tap()
        trigger.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: token.count))
        trigger.typeText("   ")
        shot("shortcut-invalid-edit")
        XCTAssertFalse(alert.buttons["Kaydet"].isEnabled)
        alert.buttons["Vazgeç"].tap()
        app.buttons["\(token) kısayolunu sil"].firstMatch.tap()
        XCTAssertFalse(row.exists)
    }

    func testDictationKeySelectionPersistsAtAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = ["-bkScreen", "dikte", "-dikteDemo", "deneme", "-dikteKeys",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        let name = "Cevap öner"
        let toggle = app.switches[name].firstMatch
        func showToggle() {
            for _ in 0..<20 {
                if toggle.isHittable { return }
                let above = toggle.exists && toggle.frame.midY < 120
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: above ? 0.4 : 0.75))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: above ? 0.75 : 0.4))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Dikte seçimine ulaşılamadı: \(name)")
        }
        showToggle()
        toggle.tap()
        showToggle()
        XCTAssertEqual(toggle.value as? String, "0")
        shot("dictation-key-disabled")
        app.terminate()
        app.launch()
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        showToggle()
        XCTAssertEqual(toggle.value as? String, "0", "Dikte seçimi yeniden açılınca korunmalı")
        toggle.tap()
        showToggle()
        XCTAssertEqual(toggle.value as? String, "1")
        shot("dictation-key-restored")
        app.buttons["Bitti"].tap()
    }

    func testDictationAtAccessibilitySize() {
        verifyDictation(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testDictationAtDefaultSize() {
        verifyDictation(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyDictation(textSize: String) {
        let app = open("dikte", textSize: textSize)
        shot("dictation-top")
        let edit = app.buttons["Tuşları düzenle"]
        XCTAssertTrue(app.buttons["Kapat"].isHittable)
        if textSize != "UICTContentSizeCategoryL" { reveal(edit, in: app, fullyVisible: true) }
        XCTAssertTrue(edit.isHittable)
        shot("dictation-actions")
        let send = app.buttons["Bitti — klavyeye gönder"]
        if textSize != "UICTContentSizeCategoryL" { reveal(send, in: app, fullyVisible: true) }
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(app.buttons["Kapat"].isHittable)
        XCTAssertTrue(app.buttons["Dinlemeye başla"].isHittable)
        shot("dictation-send")
        if textSize != "UICTContentSizeCategoryL" { reveal(edit, in: app, fullyVisible: true) }
        edit.tap()
        XCTAssertTrue(app.buttons["Bitti"].waitForExistence(timeout: 5))
        shot("dictation-keys")
        app.buttons["Bitti"].tap()
    }

    func testLayoutBottomAtLargestSize() {
        verifyLayoutBottom(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testLayoutBottomAtDefaultSize() {
        verifyLayoutBottom(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyLayoutBottom(textSize: String) {
        let app = open("duzen", textSize: textSize)
        shot("layout-top")
        let bottom = app.sliders["Alt satır yüksekliği"]
        reveal(bottom, in: app, fullyVisible: true)
        shot("layout-bottom-slider")
        let reset = app.buttons["Varsayılana dön"]
        reveal(reset, in: app, fullyVisible: true)
        XCTAssertTrue(reset.isHittable)
        shot("layout-bottom-reset")
    }

    func testDeleteDemoAtLargestSize() {
        verifyDeleteDemo(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testDeleteDemoAtDefaultSize() {
        verifyDeleteDemo(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyDeleteDemo(textSize: String) {
        let app = open("silme", textSize: textSize)
        page(in: app).swipeUp()
        shot("delete-demo-phase-one")
        Thread.sleep(forTimeInterval: 2)
        shot("delete-demo-phase-two")
        let slider = app.sliders["Silmeye başlamadan bekle"]
        reveal(slider, in: app, fullyVisible: true)
        shot("delete-slider-largest")
        let initialY = slider.frame.minY
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertEqual(slider.frame.minY, initialY, accuracy: 1,
                           "Silme animasyonu kaydırıcının konumunu değiştirmemeli")
        }
    }

    func testSoundControlsAtLargestSize() {
        verifySoundControls(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testSoundControlsAtDefaultSize() {
        verifySoundControls(textSize: "UICTContentSizeCategoryL")
    }

    private func verifySoundControls(textSize: String) {
        let app = open("ses", textSize: textSize)
        shot("sound-largest-top")
        let haptic = app.staticTexts["Basışta titreşim"]
        reveal(haptic, in: app, fullyVisible: true)
        page(in: app).swipeUp()
        let titles = ["Hafif", "Orta", "Güçlü"]
        let original = titles.first { app.buttons[$0].isSelected }
        XCTAssertNotNil(original)
        let middle = app.buttons["Orta"]
        reveal(middle, in: app, fullyVisible: true)
        middle.tap()
        XCTAssertTrue(middle.isSelected)
        if let original {
            reveal(app.buttons[original], in: app, fullyVisible: true)
            app.buttons[original].tap()
            XCTAssertTrue(app.buttons[original].isSelected)
        }
        reveal(app.buttons["Güçlü"], in: app, fullyVisible: true)
        shot("sound-largest-haptics")
    }

    func testLogDetailsAtLargestSize() {
        verifyLogDetails(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testLogDetailsAtDefaultSize() {
        verifyLogDetails(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyLogDetails(textSize: String) {
        let app = open("yzgunluk", textSize: textSize)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Henüz kayıt yok.")).firstMatch.exists)
        app.terminate()
        app.launchArguments += ["-aiLogDemo"]
        app.launch()
        XCTAssertTrue(page(in: app).waitForExistence(timeout: 10))
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Takvim · Klavye")).firstMatch
        reveal(entry, in: app)
        shot("log-populated-row")
        entry.tap()
        let source = app.staticTexts["Kaynak"].firstMatch
        reveal(source, in: app, fullyVisible: true)
        shot("log-populated-detail")
        let clear = app.buttons["Günlüğü temizle"]
        reveal(clear, in: app, fullyVisible: true)
        clear.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Henüz kayıt yok.")).firstMatch.exists)
    }

    func testLogFiltersAtAccessibilitySize() {
        verifyLogFilters(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testLogFiltersAtDefaultSize() {
        verifyLogFilters(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyLogFilters(textSize: String) {
        let app = open("yzgunluk", textSize: textSize)
        shot("log-filters")
        for title in ["Sorunlar", "Başarılı", "Hepsi"] {
            let filter = app.buttons[title]
            reveal(filter, in: app, fullyVisible: true)
            filter.tap()
            XCTAssertTrue(filter.isSelected)
            XCTAssertGreaterThanOrEqual(filter.frame.height, 44)
        }
        shot("log-filters-selected")
    }

    func testReminderAtAccessibilitySize() {
        verifyReminder(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testReminderAtDefaultSize() {
        verifyReminder(textSize: "UICTContentSizeCategoryL")
    }

    func testReminderItemEditingAtAccessibilitySize() {
        verifyReminder(textSize: "UICTContentSizeCategoryAccessibilityXXXL", editItem: true)
    }

    func testReminderItemEditingAtDefaultSize() {
        verifyReminder(textSize: "UICTContentSizeCategoryL", editItem: true)
    }

    func testReminderFirstItemRemoval() {
        verifyReminder(textSize: "UICTContentSizeCategoryL", editItem: true, removeFirst: true)
    }

    private func verifyReminder(textSize: String, editItem: Bool = false, removeFirst: Bool = false) {
        let app = open("ogrenme", textSize: textSize)
        var url = URLComponents(string: "bestkeyboard://hatirlatici")!
        url.queryItems = [URLQueryItem(name: "title", value: "Akşam otogardan annemi al"),
                         URLQueryItem(name: "due", value: String(Date().addingTimeInterval(86400).timeIntervalSince1970)),
                         URLQueryItem(name: "edit", value: "1")]
        app.open(url.url!)
        XCTAssertTrue(app.navigationBars["Hatırlatıcı"].waitForExistence(timeout: 5))
        shot("reminder-top")
        let list = app.buttons["Liste"]
        reveal(list, in: app, fullyVisible: true)
        list.tap()
        let defaultList = app.buttons["Varsayılan liste"].firstMatch
        XCTAssertTrue(defaultList.waitForExistence(timeout: 5))
        defaultList.tap()
        let item = app.textFields["Madde"].firstMatch
        reveal(item, in: app, fullyVisible: true)
        shot("reminder-title")
        let timed = app.switches["Zamanı var"].firstMatch
        reveal(timed, in: app, fullyVisible: true)
        timed.tap()
        XCTAssertEqual(timed.value as? String, "0")
        timed.tap()
        XCTAssertEqual(timed.value as? String, "1")
        reveal(app.buttons["Madde ekle"], in: app, fullyVisible: true)
        shot("reminder-items")
        XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
        if editItem {
            app.buttons["Madde ekle"].tap()
            XCTAssertEqual(app.textFields.matching(identifier: "Madde").count, 2)
            let added = app.textFields.matching(identifier: "Madde").element(boundBy: 1)
            reveal(added, in: app, fullyVisible: true)
            added.tap()
            added.typeText("Deneme")
            let keyboard = app.otherElements["inputView"].firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            shot("reminder-added-keyboard")
            XCTAssertEqual(added.value as? String, "Deneme")
            XCTAssertLessThanOrEqual(added.frame.maxY, keyboard.frame.minY)
            let dismiss = app.buttons["maker.dismissKeyboard"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            dismiss.tap()
            let remove = app.buttons.matching(identifier: "Maddeyi sil").element(boundBy: removeFirst ? 0 : 1)
            reveal(remove, in: app, fullyVisible: true)
            remove.tap()
            XCTAssertEqual(app.textFields.matching(identifier: "Madde").count, 1)
            shot("reminder-added-removed")
            XCTAssertEqual(app.textFields["Madde"].value as? String, removeFirst ? "Deneme" : "Akşam otogardan annemi al")
            if removeFirst {
                let remainingTime = app.switches["Zamanı var"].firstMatch
                reveal(remainingTime, in: app, fullyVisible: true)
                XCTAssertEqual(remainingTime.value as? String, "0")
                remainingTime.tap()
                XCTAssertEqual(remainingTime.value as? String, "1")
                XCTAssertEqual(app.textFields["Madde"].value as? String, "Deneme")
                shot("reminder-first-removed-survivor")
            }
            let remainingRemove = app.buttons["Maddeyi sil"]
            reveal(remainingRemove, in: app, fullyVisible: true)
            remainingRemove.tap()
            XCTAssertEqual(app.textFields.matching(identifier: "Madde").count, 0)
            XCTAssertFalse(app.buttons["maker.primary"].isEnabled)
            shot("reminder-empty-after-removal")
        }
    }

    func testEventLocationAtAccessibilitySize() {
        verifyEventLocation(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testEventTitleAtAccessibilitySize() {
        let app = open("yzetkinlik", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let title = app.textFields["Başlık"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" ve akşam yemeği")
        XCTAssertTrue((title.value as? String ?? "").contains("akşam yemeği"))
        XCTAssertTrue(app.otherElements["inputView"].firstMatch.waitForExistence(timeout: 5))
        shot("event-title-keyboard")
        XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
    }

    func testEventLocationAtDefaultSize() {
        verifyEventLocation(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyEventLocation(textSize: String) {
        let app = open("yzetkinlik", textSize: textSize)
        let location = app.textFields["Yer"].firstMatch
        reveal(location, in: app, fullyVisible: true)
        location.tap()
        location.typeText(" Deneme")
        let keyboard = app.otherElements["inputView"].firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        shot("event-location-keyboard")
        XCTAssertTrue((location.value as? String ?? "").contains("Deneme"))
        XCTAssertTrue(location.isHittable)
        XCTAssertLessThanOrEqual(location.frame.maxY, keyboard.frame.minY)
        XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
    }

    func testContactPhoneRemovalAtAccessibilitySize() {
        verifyContactPhoneRemoval(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testContactPhoneRemovalAtDefaultSize() {
        verifyContactPhoneRemoval(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyContactPhoneRemoval(textSize: String) {
        let app = open("yzkisi", textSize: textSize)
        let original = app.textFields["cep"].value as? String
        let add = app.buttons["Telefon ekle"]
        reveal(add, in: app, fullyVisible: true)
        add.tap()
        XCTAssertEqual(app.textFields.matching(identifier: "cep").count, 2)
        let added = app.textFields.matching(identifier: "cep").element(boundBy: 1)
        reveal(added, in: app, fullyVisible: true)
        added.tap()
        added.typeText("12345")
        XCTAssertEqual(added.value as? String, "12345")
        shot("contact-phone-added")
        app.buttons["maker.dismissKeyboard"].tap()
        let remove = app.buttons.matching(identifier: "cep sil").element(boundBy: 1)
        reveal(remove, in: app, fullyVisible: true)
        remove.tap()
        XCTAssertEqual(app.textFields.matching(identifier: "cep").count, 1)
        XCTAssertEqual(app.textFields["cep"].value as? String, original)
        shot("contact-phone-removed")
    }

    func testContactEditingAtAccessibilitySize() {
        verifyContactEditing(textSize: "UICTContentSizeCategoryAccessibilityXXXL", field: "Soyad", sample: " Deneme")
    }

    func testContactEditingAtDefaultSize() {
        verifyContactEditing(textSize: "UICTContentSizeCategoryL", field: "Soyad", sample: " Deneme")
    }

    func testContactPhoneAtAccessibilitySize() {
        verifyContactEditing(textSize: "UICTContentSizeCategoryAccessibilityXXXL", field: "cep", sample: "1")
    }

    private func verifyContactEditing(textSize: String, field: String, sample: String) {
        let app = open("yzkisi", textSize: textSize)
        let name = app.textFields[field]
        reveal(name, in: app, fullyVisible: true)
        name.tap()
        name.typeText(sample)
        XCTAssertTrue((name.value as? String ?? "").contains(sample.trimmingCharacters(in: .whitespaces)))
        let keyboard = app.otherElements["inputView"].firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        shot("contact-edit-keyboard")
        XCTAssertTrue(name.isHittable)
        XCTAssertLessThanOrEqual(name.frame.maxY, keyboard.frame.minY)
        let save = app.buttons["Kişilere ekle"]
        if textSize != "UICTContentSizeCategoryL" {
            XCTAssertFalse(save.exists)
        } else {
            XCTAssertLessThanOrEqual(name.frame.maxY, save.frame.minY)
        }
        XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
        let dismiss = app.buttons["maker.dismissKeyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        shot("contact-edit-dismissed")
    }

    func testMakerSheetsAtAccessibilitySize() {
        verifyMakerSheets(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testMakerSheetsAtDefaultSize() {
        verifyMakerSheets(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyMakerSheets(textSize: String) {
        for route in ["yzetkinlik", "yzkisi"] {
            let app = open(route, textSize: textSize)
            shot(route + "-large-top")
            if route == "yzetkinlik" {
                let allDay = app.switches["Tüm gün"].firstMatch
                XCTAssertTrue(allDay.isHittable)
                allDay.tap()
                XCTAssertEqual(allDay.value as? String, "1")
                shot("event-all-day")
                allDay.tap()
                XCTAssertEqual(allDay.value as? String, "0")
            }
            page(in: app).swipeUp()
            shot(route + "-large-middle")
            page(in: app).swipeUp()
            shot(route + "-large-bottom")
            XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
            app.terminate()
        }
    }

    func testDictionarySearchAtAccessibilitySize() {
        verifyDictionarySearch(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testDictionarySearchAtDefaultSize() {
        verifyDictionarySearch(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyDictionarySearch(textSize: String) {
        let app = open("ogrenme", textSize: textSize)
        let title = app.staticTexts["İçe aktarılanlar"]
        reveal(title, in: app, fullyVisible: true)
        title.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        shot("dictionary-empty-large")
        search.tap()
        search.typeText("uigorseldeneme")
        XCTAssertTrue(app.staticTexts["Kelime bulunamadı"].exists)
        XCTAssertFalse(app.staticTexts["0 kayıt"].exists)
        shot("dictionary-search-keyboard-large")
    }

    func testLearningAtAccessibilitySize() {
        verifyLearning(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testLearningAtDefaultSize() {
        verifyLearning(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyLearning(textSize: String) {
        let app = open("ogrenme", textSize: textSize)
        shot("learning-large-top")
        let imported = app.staticTexts["İçe aktarılanlar"]
        reveal(imported, in: app, fullyVisible: true)
        shot("learning-large-dictionaries")
        for name in ["WhatsApp sohbeti", "Telegram sohbeti"] {
            reveal(app.staticTexts[name], in: app, fullyVisible: true)
            page(in: app).swipeUp(velocity: .slow)
            shot("learning-import-" + name)
        }
        reveal(app.staticTexts["Metin yapıştır"], in: app, fullyVisible: true)
        shot("learning-large-import")
        app.staticTexts["Metin yapıştır"].tap()
        XCTAssertTrue(app.buttons["Öğren"].waitForExistence(timeout: 5))
        shot("learning-large-paste")
        app.buttons["Vazgeç"].tap()
    }

    func testPasteEditorAtLargestSize() {
        verifyPasteEditor(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testPasteEditorAtDefaultSize() {
        verifyPasteEditor(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyPasteEditor(textSize: String) {
        let app = open("ogrenme", textSize: textSize)
        let paste = app.staticTexts["Metin yapıştır"]
        reveal(paste, in: app, fullyVisible: true)
        paste.tap()
        let learn = app.buttons["Öğren"]
        XCTAssertTrue(learn.waitForExistence(timeout: 5))
        shot("paste-editor-empty")
        XCTAssertFalse(learn.isEnabled)
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("   ")
        XCTAssertFalse(learn.isEnabled)
        editor.typeText("Deneme metni")
        XCTAssertTrue(learn.isEnabled)
        XCTAssertTrue(app.buttons["Vazgeç"].isHittable)
        XCTAssertTrue(learn.isHittable)
        shot("paste-editor-keyboard")
        app.buttons["Vazgeç"].tap()
    }

    func testIntegrationStatusesAtAccessibilitySize() {
        verifyIntegrationStatuses(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testIntegrationStatusesAtDefaultSize() {
        verifyIntegrationStatuses(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyIntegrationStatuses(textSize: String) {
        let app = open("yzbaglanti", textSize: textSize)
        reveal(app.staticTexts["Things"], in: app, fullyVisible: true)
        shot("integrations-things-large")
        reveal(app.staticTexts["TickTick"], in: app, fullyVisible: true)
        page(in: app).swipeUp()
        shot("integrations-ticktick-large")
    }

    func testIntegrationSaveAvailability() {
        let app = open("yzbaglanti")
        let field = app.secureTextFields["API token’ını yapıştır"]
        let save = app.buttons["Kaydet"]
        XCTAssertFalse(save.isEnabled)
        field.tap()
        field.typeText("ui-deneme")
        XCTAssertTrue(save.isEnabled)
        shot("integration-save-enabled")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        XCTAssertFalse(save.isEnabled)
        shot("integration-save-empty")
    }

    func testAIListAtAccessibilitySize() {
        verifyAIList(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testAIListAtExtraLargeSize() {
        verifyAIList(textSize: "UICTContentSizeCategoryXXXL")
    }

    func testAIListAtDefaultSize() {
        verifyAIList(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyAIList(textSize: String) {
        let app = open("yz", textSize: textSize)
        shot("ai-list-large-top")
        reveal(app.buttons["Bağla"], in: app, fullyVisible: true)
        shot("ai-list-connect")
        reveal(app.buttons["Varsayılanlara dön"], in: app, fullyVisible: true)
        shot("ai-list-header")
        let save = app.buttons["Kaydet"].firstMatch
        reveal(save, in: app, fullyVisible: true)
        XCTAssertFalse(save.isEnabled)
        shot("ai-list-large-integration")
    }

    func testSetupAtAccessibilitySize() {
        let size = "UICTContentSizeCategoryAccessibilityXXXL"
        let app = open("kurulum", textSize: size)
        shot("setup-large-top")
        reveal(app.buttons["Ayarları aç"], in: app, fullyVisible: true)
        shot("setup-large-bottom")
    }

    func testProviderAtAccessibilitySize() {
        verifyProvider(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testProviderAtDefaultSize() {
        verifyProvider(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyProvider(textSize: String) {
        let app = open("yzbagla", textSize: textSize)
        shot("provider-large-top")
        app.buttons["ai.provider"].firstMatch.tap()
        shot("provider-large-menu")
        app.buttons["OpenRouter"].firstMatch.tap()
        let connect = app.buttons["OpenRouter ile bağla"]
        reveal(connect, in: app, fullyVisible: true)
        XCTAssertFalse(connect.isEnabled)
        shot("provider-large-connect")
    }

    func testEditorScreenInventory() {
        for route in ["kurulum", "studyo", "yz", "yztus", "dikte", "yzbaglanti", "gelistirici"] {
            let app = open(route)
            shot(route + "-top")
            page(in: app).swipeUp()
            shot(route + "-lower")
            app.terminate()
        }
        let app = open("yzbagla")
        shot("service-provider-full-name")
        app.buttons["ai.provider"].firstMatch.tap()
        shot("service-provider-options")
        app.buttons["OpenRouter"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["OpenRouter anahtarı"].exists)
        XCTAssertFalse(app.buttons["OpenRouter ile bağla"].isEnabled)
        shot("service-provider-selected")
    }

    func testThemeSaveEditDelete() {
        var app = open("tema")
        let name = app.textFields["Tema adı"]
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11) + "UI Deneme")
        app.buttons["Kaydet"].tap()
        app.terminate()
        app = open("temalar")
        let edit = app.buttons["UI Deneme temasını düzenle"]
        reveal(edit, in: app)
        shot("theme-saved")
        edit.tap()
        XCTAssertEqual(app.textFields["Tema adı"].value as? String, "UI Deneme")
        let remove = app.buttons["Bu temayı sil"]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertFalse(app.buttons["UI Deneme temasını düzenle"].exists)
    }

    func testThemeControlsAtAccessibilitySize() {
        verifyThemeControls(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    func testThemeControlsAtDefaultSize() {
        verifyThemeControls(textSize: "UICTContentSizeCategoryL")
    }

    private func verifyThemeControls(textSize: String) {
        let app = open("tema", textSize: textSize)
        let photo = app.buttons["Fotoğraf seç"]
        reveal(photo, in: app, fullyVisible: true)
        shot("theme-accessibility-photo")
        let light = app.buttons["Açık"].firstMatch
        reveal(light, in: app, fullyVisible: true)
        shot("theme-accessibility-text-color")
        light.tap()
        XCTAssertTrue(light.isSelected)
        let rounded = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Yuvarlak")).firstMatch
        reveal(rounded, in: app, fullyVisible: true)
        shot("theme-accessibility-font")
        rounded.tap()
        XCTAssertTrue(rounded.isSelected)
    }

    func testThemePreviewReturnsAfterTyping() {
        verifyThemePreviewReturns(textSize: "UICTContentSizeCategoryL")
    }

    func testThemePreviewReturnsAtAccessibilitySize() {
        verifyThemePreviewReturns(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func verifyThemePreviewReturns(textSize: String) {
        let app = open("tema", textSize: textSize)
        let initialTop = page(in: app).frame.minY
        let name = app.textFields["Tema adı"]
        name.tap()
        name.typeText(" deneme")
        XCTAssertTrue(app.buttons["key.dismiss"].waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.page(in: app).frame.minY < initialTop - 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        shot("theme-preview-focused")
        XCTAssertTrue(app.buttons["key.dismiss"].isHittable)
        app.buttons["key.dismiss"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.page(in: app).frame.minY >= initialTop - 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        shot("theme-preview-restored")
        let solid = app.buttons["Renk"]
        reveal(solid, in: app); solid.tap()
        let swatch = app.buttons["#0B2545"].firstMatch
        reveal(swatch, in: app); swatch.tap()
        XCTAssertTrue(swatch.isSelected)
        shot("theme-preview-color-after-dismiss")
    }

    func testLongThemeName() {
        let title = "Uzun isimli kişisel gün batımı ve deniz teması"
        var app = open("tema")
        let field = app.textFields["Tema adı"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11) + title)
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.keys["key.q"].isHittable)
        shot("theme-long-name-editor")
        app.buttons["Kaydet"].tap()
        app.terminate()
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            app = open("temalar", textSize: size)
            let edit = app.buttons[title + " temasını düzenle"]
            reveal(edit, in: app)
            shot("theme-long-name-" + size)
            XCTAssertTrue(edit.isHittable)
            XCTAssertLessThanOrEqual(edit.frame.maxX, app.windows.firstMatch.frame.maxX)
            app.terminate()
        }
        app = open("temalar")
        let edit = app.buttons[title + " temasını düzenle"]
        reveal(edit, in: app); edit.tap()
        XCTAssertEqual(app.textFields["Tema adı"].value as? String, title)
        let remove = app.buttons["Bu temayı sil"]
        reveal(remove, in: app); remove.tap()
        XCTAssertFalse(edit.exists)
    }

    func testAIActionPlaceholdersAtAccessibilitySize() {
        let app = open("yztus", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.buttons["Kaydet"].isEnabled)
        let placeholder = app.buttons["{metin}"]
        reveal(placeholder, in: app, fullyVisible: true)
        shot("ai-placeholder-large")
        placeholder.tap()
        let prompt = app.textFields.element(boundBy: 1)
        XCTAssertTrue((prompt.value as? String ?? "").contains("{metin}"))
        XCTAssertTrue(app.buttons["Kaydet"].isEnabled)
        let reminder = app.buttons["Hatırlatıcı"]
        for _ in 0..<10 where !reminder.exists { page(in: app).swipeDown() }
        reveal(reminder, in: app, fullyVisible: true)
        reminder.tap()
        let reset = app.buttons["Varsayılan isteme dön"]
        reveal(reset, in: app, fullyVisible: true)
        shot("ai-structured-prompt-large")
        reset.tap()
        XCTAssertTrue(app.buttons["Kaydet"].isEnabled)
    }

    func testAIShortcutTargetAtAccessibilitySize() {
        let app = open("yztus", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let preview = app.buttons["Modele giden istem"]
        reveal(preview, in: app, fullyVisible: true)
        preview.tap()
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kestirme,")).firstMatch
        reveal(target, in: app, fullyVisible: true)
        shot("ai-shortcut-target-large")
        target.tap()
        let name = app.textFields["ör. Hatırlatıcıya ekle"]
        reveal(name, in: app, fullyVisible: true)
        shot("ai-shortcut-name-empty")
        XCTAssertFalse(app.buttons["Kaydet"].isEnabled)
        name.tap(); name.typeText("   ")
        XCTAssertFalse(app.buttons["Kaydet"].isEnabled)
        name.typeText("UI deneme kestirmesi")
        XCTAssertTrue(app.buttons["Kaydet"].isEnabled)
    }

    func testAIActionCreateDelete() {
        let app = open("yz")
        let add = app.buttons["+ Yeni tuş"]
        reveal(add, in: app)
        add.tap()
        XCTAssertFalse(app.buttons["Kaydet"].isEnabled)
        let name = app.textFields["ör. Çevir"]
        name.tap(); name.typeText("uiaudit")
        XCTAssertEqual(name.value as? String, "uiaudit")
        let reminder = app.buttons["Hatırlatıcı"]
        reveal(reminder, in: app)
        reminder.tap()
        XCTAssertTrue(reminder.isSelected)
        XCTAssertTrue(app.buttons["Kaydet"].isEnabled)
        app.buttons["Kaydet"].tap()
        let remove = app.buttons["uiaudit tuşunu sil"]
        page(in: app).swipeDown()
        reveal(remove, in: app)
        shot("ai-action-created")
        remove.tap()
        XCTAssertFalse(remove.exists)
    }

    func testEditorsAtAccessibilitySize() {
        for route in ["kurulum", "studyo", "yztus", "yzbagla", "kisayol"] {
            let app = open(route, textSize: "UICTContentSizeCategoryAccessibilityXXXL")
            shot(route + "-accessibility-top")
            page(in: app).swipeUp()
            shot(route + "-accessibility-lower")
            app.terminate()
        }
    }

    func testMediaEditorsAtAccessibilitySize() {
        for route in ["gif", "cikartma"] {
            let app = open(route, textSize: "UICTContentSizeCategoryAccessibilityXXXL")
            shot(route + "-media-accessibility-top")
            for index in 1...3 {
                page(in: app).swipeUp()
                shot(route + "-media-accessibility-\(index)")
            }
            app.terminate()
        }
    }

    func testCategoryCreationAndSelection() {
        let app = open("studyo")
        let addCategory = app.buttons["+ Kategori"]
        reveal(addCategory, in: app); addCategory.tap()
        let alert = app.alerts["Yeni kategori"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertFalse(alert.buttons["Ekle"].isEnabled)
        let name = "Deneme" + UUID().uuidString.prefix(4).lowercased()
        let field = alert.textFields.firstMatch
        field.tap(); field.typeText(name)
        XCTAssertTrue(alert.buttons["Ekle"].isEnabled)
        alert.buttons["Ekle"].tap()
        let category = app.buttons[name]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(category.isSelected)
        shot("category-created-selected")
        app.buttons["Tümü"].tap()
        XCTAssertFalse(category.isSelected)
        category.tap()
        XCTAssertTrue(category.isSelected)
        app.terminate()
        let reopened = open("studyo")
        reveal(reopened.buttons[name], in: reopened)
        XCTAssertTrue(reopened.buttons[name].exists)
        shot("category-persisted")
    }

    @MainActor func testLoadedGifAtAccessibilitySize() async throws {
        let url = try await makeVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.launchArguments = ["-bkScreen", "gif", "-gifSelfTest", url.path,
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hazır ✓")).firstMatch.waitForExistence(timeout: 15))
        shot("gif-loaded-accessibility-top")
        for index in 1...4 {
            page(in: app).swipeUp()
            shot("gif-loaded-accessibility-\(index)")
        }
    }

    func testAIKeyboardCardAfterDeviceRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-nativeKeyboardFixture"]
        app.launch()
        app.buttons["native.fixture"].tap()
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["Yapay zeka tuşları"]))
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["Yapay zeka tuşları"].tap()
        let close = app.buttons["Kartı kapat"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        // Ana uygulama Info.plist ile dikeye kilitli; gerçek yatay klavye
        // başka bir uygulamada ayrıca denetlenmeli.
        shot("ai-card-after-device-rotation")
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.minY, app.windows.firstMatch.frame.minY)
        close.tap()
        XCTAssertTrue(app.keys["key.q"].isHittable)
    }

    func testSafariLandscapeAIKeyboard() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let host = XCUIApplication()
        host.launch()
        host.terminate()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        func waitForLandscape(_ landscape: Bool) {
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = safari.windows.firstMatch.frame
                return landscape ? frame.width > frame.height : frame.height > frame.width
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        }
        safari.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let address = safari.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        let ai = safari.buttons["Yapay zeka tuşları"]
        XCTAssertTrue(safari.switchToBestKeyboard(until: ai))
        waitForLandscape(true)
        shot("safari-landscape-keyboard")
        XCTAssertGreaterThan(safari.keys["key.q"].frame.minY,
                             safari.windows.firstMatch.frame.height * 0.3)
        XCTAssertLessThan(safari.keys["key.q"].frame.height, 45)
        ai.tap()
        let close = safari.buttons["Kartı kapat"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        shot("safari-landscape-ai")
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.minY, safari.windows.firstMatch.frame.minY)
        let content = safari.scrollViews["ai.card.content"]
        content.swipeUp()
        shot("safari-landscape-ai-scrolled")
        XCUIDevice.shared.orientation = .portrait
        waitForLandscape(false)
        // Safari yön değişiminde giriş görünümünü yeniden oluşturabilir.
        // Kart kapandıysa yeniden aç; mevcut ama ekran dışındaki kartı gizleme.
        if !close.exists { ai.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)], timeout: 5), .completed)
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.minY, safari.windows.firstMatch.frame.minY)
        XCTAssertGreaterThan(close.frame.minY, safari.windows.firstMatch.frame.height * 0.1)
        shot("safari-ai-rotated-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(true)
        if !close.exists { ai.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)], timeout: 5), .completed)
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.minY, safari.windows.firstMatch.frame.minY)
        shot("safari-ai-rotated-landscape")
        close.tap()
        XCTAssertTrue(safari.keys["key.q"].isHittable)
        safari.keys["key.q"].tap()
        shot("safari-landscape-typed")
        let activeAddress = safari.textFields.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "SearchFieldItemView?isActive=true")).firstMatch
        XCTAssertTrue((activeAddress.value as? String)?.lowercased().contains("q") == true)
    }

    func testQuickRecordingRoundTrip() {
        var app = open("gelistirici")
        let quick = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hızlı kayıt")).firstMatch
        reveal(quick, in: app); quick.tap()
        XCTAssertFalse(app.buttons["Kaydı başlat"].isEnabled)
        let field = app.editableField
        field.tap(); field.typeText("merhaba")
        let start = app.buttons["Kaydı başlat"]
        if !start.isHittable { app.collectionViews.firstMatch.swipeUp() }
        start.tap()
        XCTAssertTrue(app.keys["key.m"].waitForExistence(timeout: 10))
        for letter in "merhaba" { app.keys["key.\(letter)"].tap() }
        app.keys["key.space"].tap()
        shot("recording-typed")
        app.buttons["Kaydet"].tap()
        XCTAssertTrue(app.buttons["Bitir"].waitForExistence(timeout: 5))
        app.buttons["Bitir"].tap()
        XCTAssertTrue(app.navigationBars["Hızlı kayıt"].waitForExistence(timeout: 5))
        app.terminate()
        app = open("gelistirici")
        let sessions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kayıt oturumları")).firstMatch
        reveal(sessions, in: app); sessions.tap()
        XCTAssertTrue(app.staticTexts["merhaba"].firstMatch.waitForExistence(timeout: 5))
        shot("recording-saved")
    }

    func testPresetThemePanels() {
        let app = XCUIApplication()
        app.launchArguments = ["-nativeKeyboardFixture"]
        app.launch()
        app.buttons["native.fixture"].tap()
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.settings"]))
        for name in ["Manzara", "Gece"] {
            app.buttons["key.settings"].tap()
            let choice = app.buttons["Tema: " + name]
            XCTAssertTrue(choice.isHittable)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            shot("theme-\(name)-settings")
            app.buttons["Bitti"].tap()
            app.keys["key.m"].tap()
            shot("theme-\(name)-keyboard")
            app.buttons["Yapay zeka tuşları"].tap()
            XCTAssertTrue(app.buttons["Kartı kapat"].isHittable)
            shot("theme-\(name)-ai")
            app.buttons["Kartı kapat"].tap()
            app.buttons["key.emoji"].tap()
            shot("theme-\(name)-emoji")
            app.buttons["harflere dön"].tap()
            app.buttons["key.settings"].tap()
            XCTAssertTrue(app.buttons["Tema: " + name].isSelected)
            app.buttons["Tema: Sistem"].tap()
            app.buttons["Bitti"].tap()
        }
    }

    func testAdvancedKeyboardSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-nativeKeyboardFixture"]
        app.launch()
        app.buttons["native.fixture"].tap()
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.settings"]))
        app.buttons["key.settings"].tap()
        let content = app.scrollViews["keyboard.settings.content"]
        let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gelişmiş ayarlar")).firstMatch
        for _ in 0..<5 {
            if advanced.isHittable { break }
            content.swipeUp()
        }
        advanced.tap()
        for index in 0..<8 {
            content.swipeUp()
            shot("advanced-settings-\(index)")
            XCTAssertTrue(app.buttons["Bitti"].isHittable)
            if app.buttons["Varsayılana dön"].isHittable { break }
        }
        XCTAssertTrue(app.buttons["Varsayılana dön"].isHittable)
        app.buttons["Bitti"].tap()
        XCTAssertTrue(app.keys["key.q"].isHittable)
    }

    func testLandscapeClipboardStoredText() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let host = XCUIApplication()
        host.launch(); host.terminate()
        let app = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        app.terminate(); app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(" ")
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.emoji"]))
        app.buttons["key.emoji"].tap()
        app.buttons["Pano geçmişi"].tap()
        let sample = "Pano denemesi: Türkçe ığüşöç 123"
        let clip = app.cells.matching(NSPredicate(format: "label == %@", "Metin: " + sample)).firstMatch
        try XCTSkipUnless(clip.exists, "Run synthetic clipboard roundtrip on this test simulator first")
        shot("landscape-clipboard-populated")
        XCTAssertTrue(clip.isHittable)
        XCTAssertTrue(app.buttons["Temizle"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["Temizle"].frame.height, 44)
        let close = app.buttons["harflere dön"]
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        clip.tap()
        let activeAddress = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "SearchFieldItemView?isActive=true")).firstMatch
        XCTAssertTrue((activeAddress.value as? String ?? "").contains(sample))
        shot("landscape-clipboard-text-inserted")
    }

    func testLandscapeUtilityPanels() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let host = XCUIApplication()
        host.launch(); host.terminate()
        let app = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        app.terminate(); app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(" ")
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.emoji"]))
        app.buttons["key.emoji"].tap()
        app.buttons["Suratlar ve insanlar"].tap()
        let smile = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "😀")).firstMatch
        XCTAssertTrue(smile.waitForExistence(timeout: 5))
        smile.tap()
        shot("landscape-emoji")
        app.buttons["Pano geçmişi"].tap()
        shot("landscape-clipboard")
        XCTAssertTrue(app.buttons["harflere dön"].isHittable)
        app.buttons["harflere dön"].tap()
        app.buttons["key.emoji"].tap()
        app.buttons["GIF ve çıkartmalar"].tap()
        shot("landscape-media")
        app.buttons["Çıkartma"].tap()
        shot("landscape-sticker")
        app.buttons["harflere dön"].tap()
        app.buttons["key.settings"].tap()
        if host.wait(for: .runningForeground, timeout: 3) {
            XCTAssertTrue(host.staticTexts["Klavye düzeni"].waitForExistence(timeout: 5))
            shot("settings-full-access-opens-host")
            return
        }
        XCTAssertTrue(app.buttons["Bitti"].waitForExistence(timeout: 5))
        shot("landscape-settings-top")
        let done = app.buttons["Bitti"]
        app.scrollViews["keyboard.settings.content"].swipeUp()
        shot("landscape-settings-scrolled")
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.keys["key.q"].isHittable)
    }

    func testNativeEmojiClipboardMediaAndSettings() {
        UIPasteboard.general.string = "UI deneme panosu"
        let app = XCUIApplication()
        app.launchArguments = ["-nativeKeyboardFixture"]
        app.launch()
        app.buttons["native.fixture"].tap()
        XCTAssertTrue(app.switchToBestKeyboard(until: app.buttons["key.emoji"]))
        app.buttons["key.emoji"].tap()
        app.buttons["Suratlar ve insanlar"].tap()
        let smile = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "😀")).firstMatch
        XCTAssertTrue(smile.waitForExistence(timeout: 5))
        smile.tap()
        XCTAssertTrue((app.textViews["native.editor"].value as? String ?? "").contains("😀"))
        shot("native-emoji")
        app.buttons["Pano geçmişi"].tap()
        XCTAssertTrue(app.staticTexts["Pano geçmişi"].exists)
        shot("native-clipboard")
        app.buttons["harflere dön"].tap()
        app.buttons["key.emoji"].tap()
        app.buttons["GIF ve çıkartmalar"].tap()
        shot("native-gif")
        app.buttons["Çıkartma"].tap()
        shot("native-sticker")
        app.buttons["harflere dön"].tap()
        app.buttons["key.settings"].tap()
        shot("native-settings")
        if app.buttons["Bitti"].exists { app.buttons["Bitti"].tap() }
    }
}
