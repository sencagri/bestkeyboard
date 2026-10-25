import XCTest
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime

final class ConversationInterruptionTests: XCTestCase {
    func testMixedDuplicateUndoInsideCompleteMessages() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let messages = [
            "canım seni çoook özledim akşam buluşalım",
            "mühendislik ekibi veritabanı bağlantısını yeniden başlattı",
            "ula uşağum gardaş geliyom çay içek",
            "sayın yetkili\nbaşvurumun değerlendirilmesini rica ederim\nsaygılarımla",
            "otobüsteyim randevumuz için geliyorum",
            "çocuklarımızı okuldan alıp alışverişe gidelim"
        ]
        for message in messages {
            for offset in [-0.18, 0.0, 0.18] {
                func run(interrupt: Bool, neighbor: Bool = false) throws -> (String, [String: Int]) {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    func letter(_ ch: Character) throws {
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(
                            x: key.center.x + offset * key.width,
                            y: key.center.y + offset * key.height)), into: doc)
                    }
                    var word: [Character] = []
                    func flush() throws {
                        for (i, ch) in word.enumerated() {
                            try letter(ch)
                            if interrupt && i == word.count / 2 {
                                let origin = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                                let adjacent = layout.keys.filter { $0.char != ch }.min {
                                    $0.center.squaredDistance(to: origin.center) < $1.center.squaredDistance(to: origin.center)
                                }!
                                try letter(neighbor ? adjacent.char : ch)
                                c.space(into: doc)
                                c.newline(into: doc)
                                c.backspaceTap(into: doc)
                                c.backspaceTap(into: doc)
                                c.backspaceTap(into: doc)
                            }
                        }
                        word.removeAll()
                    }
                    for ch in message {
                        if ch.isWhitespace {
                            try flush()
                            if ch == "\n" { c.newline(into: doc) }
                            else { c.space(into: doc) }
                        } else { word.append(ch) }
                    }
                    try flush()
                    c.space(into: doc)
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) })
                }
                let clean = try run(interrupt: false)
                let edited = try run(interrupt: true)
                XCTAssertEqual(clean.0, message + " ", "Clean message, offset=\(offset)")
                XCTAssertEqual(edited.0, clean.0, "Interrupted message=\(message), offset=\(offset)")
                XCTAssertEqual(edited.1, clean.1, "Cancelled fragments must not add learning, offset=\(offset)")
                let neighbor = try run(interrupt: true, neighbor: true)
                XCTAssertEqual(neighbor.0, clean.0, "Neighbor insertion, message=\(message), offset=\(offset)")
                XCTAssertEqual(neighbor.1, clean.1, "Cancelled neighbor fragments must not add learning, offset=\(offset)")
            }
        }
    }

    func testPunctuatedMessagesWithCancelledExtraKeys() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let messages = [
            "canım, seni çoook özledim! akşam buluşalım mı?",
            "mühendislik ekibi: veritabanı bağlantısını yeniden başlattı. sonuç: başarılı!",
            "ula uşağum, gardaş geliyom! çay içek mi?",
            "sayın yetkili,\nbaşvurumun değerlendirilmesini rica ederim.\nsaygılarımla.",
            "otobüsteyim; randevumuz için geliyorum. bekler misin?",
            "çocuklarımızı okuldan alıp alışverişe gidelim. ekmek, süt, yumurta.",
            "Canım, İstanbul'a geliyorum. Akşam buluşalım!",
            "Ankara’ya yarın gidiyorum. İzmir’e cuma döneceğim.",
            "Sayın Ahmet Bey,\nbaşvurumun değerlendirilmesini rica ederim.",
            "API bağlantısı kuruldu. SQL sorgusu tamamlandı.",
            "Türkiye'nin mühendislik ekibi hazır.",
            "Işıl, İpek ve Çağrı bugün okuldan geliyor."
        ]
        let structuredMessages = [
            "Canım, saat 18.30'da buluşalım 🙂 seni bekliyorum.",
            "Toplantı 24.10.2026 tarihinde, saat 09.45'te başlayacak.",
            "Toplam 2.500,75 TL. Sipariş numarası: 20261024.",
            "API v2.1 hazır. Sunucu: 192.168.1.10, port: 8080.",
            "Bugün 3 ekmek, 2 süt ve 6 yumurta alalım. 👍",
            "Akşam ailece buluşalım 👨‍👩‍👧‍👦 yarın yola çıkıyoruz 🇹🇷"
        ]
        for message in messages + structuredMessages {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ accidentalBoundary: String?) throws -> (String, [String: Int]) {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    func letter(_ ch: Character) throws {
                        let lower: Character = ch == "I" ? "ı" : ch == "İ" ? "i" : Character(String(ch).lowercased())
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: lower))]
                        let touch = TouchSample(down: .init(
                            x: key.center.x + offset * key.width,
                            y: key.center.y + offset * key.height))
                        if ch.isUppercase {
                            c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc)
                        } else { c.insertLetter(ch, touch: touch, into: doc) }
                    }
                    func boundary(_ ch: Character) {
                        if ch == " " { c.space(into: doc) }
                        else if ch == "\n" { c.newline(into: doc) }
                        else { c.insertSymbol(ch, into: doc) }
                    }
                    var word: [Character] = []
                    func flush() throws {
                        for (i, ch) in word.enumerated() {
                            try letter(ch)
                            if i == word.count / 2, let accidentalBoundary {
                                let lower: Character = ch == "I" ? "ı" : ch == "İ" ? "i" : Character(String(ch).lowercased())
                                let origin = layout.keys[try XCTUnwrap(layout.keyIndex(for: lower))]
                                let adjacent = layout.keys.filter { $0.char != lower }.min {
                                    $0.center.squaredDistance(to: origin.center) < $1.center.squaredDistance(to: origin.center)
                                }!
                                try letter(adjacent.char)
                                for separator in accidentalBoundary { boundary(separator) }
                                for _ in 0...accidentalBoundary.count { c.backspaceTap(into: doc) }
                            }
                        }
                        word.removeAll()
                    }
                    for ch in message {
                        if ch.isLetter { word.append(ch) }
                        else { try flush(); boundary(ch) }
                    }
                    try flush()
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) })
                }
                let clean = try run(nil)
                XCTAssertEqual(clean.0, message, "Clean punctuation, offset=\(offset)")
                let boundaries = [". \n", ", \n", "  \n"] +
                    (structuredMessages.contains(message) ? ["🙂 \n", "👨‍👩‍👧‍👦 \n"] : [])
                for boundary in boundaries {
                    let edited = try run(boundary)
                    let label = "message=\(message), boundary=\(boundary.debugDescription), offset=\(offset)"
                    XCTAssertEqual(edited.0, clean.0, label)
                    XCTAssertEqual(edited.1, clean.1, "Cancelled fragments changed learning: " + label)
                }
            }
        }
    }


    func testAccidentallyDeletedLettersRetypedAcrossRepeatedMessages() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let words = ["sevgilim", "çoook", "buluşalım", "mühendislik", "veritabanı",
                     "bağlantısını", "uşağum", "geliyom", "başvurumun",
                     "değerlendirilmesini", "otobüsteyim", "çocuklarımızı"]
        for word in words {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ mode: Int) throws -> (String, [String: Int]) {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    func letter(_ ch: Character) throws {
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(
                            x: key.center.x + offset * key.width,
                            y: key.center.y + offset * key.height)), into: doc)
                    }
                    let chars = Array(word)
                    for _ in 0..<3 {
                        for (i, ch) in chars.enumerated() {
                            try letter(ch)
                            if mode > 0 && i == chars.count / 2 {
                                if mode == 2 || mode == 4 {
                                    c.space(into: doc)
                                    c.newline(into: doc)
                                    c.backspaceTap(into: doc)
                                    if mode == 4 { c.backspaceRepeat(into: doc) }
                                    else { c.backspaceTap(into: doc) }
                                }
                                for _ in 0..<2 {
                                    if mode >= 3 { c.backspaceRepeat(into: doc) }
                                    else { c.backspaceTap(into: doc) }
                                }
                                try letter(chars[i - 1])
                                try letter(ch)
                            }
                        }
                        c.space(into: doc)
                        c.newline(into: doc)
                    }
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) })
                }
                let clean = try run(0)
                XCTAssertEqual(clean.0, String(repeating: word + " \n", count: 3))
                for mode in [1, 2, 3, 4] {
                    let edited = try run(mode)
                    let label = "word=\(word), offset=\(offset), mode=\(mode)"
                    XCTAssertEqual(edited.0, clean.0, label)
                    XCTAssertEqual(edited.1, clean.1, "Retyping must not multiply learning: " + label)
                }
            }
        }
    }

}
