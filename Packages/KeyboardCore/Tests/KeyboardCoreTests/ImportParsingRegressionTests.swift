import XCTest
import KBLearning

final class ImportParsingRegressionTests: XCTestCase {
    func testSystemRecordsDoNotBecomeUserTextAndCodeSurvives() {
        let messages = ChatExportParser.whatsApp("""
        [10.10.2026 12:00:00] Ali: <div>hello</div>
        [10.10.2026 12:01:00] Mesajlar uçtan uca şifrelidir.
        system continuation
        [10.10.2026 12:02:00] Ali: omitted parametresini kontrol et
        [10.10.2026 12:03:00] Ali: <Medya dahil edilmedi>
        [10.10.2026 12:04:00] Ali: bunu dahil edilmedi sanmıştım
        """)
        XCTAssertEqual(messages.map(\.text), ["<div>hello</div>", "omitted parametresini kontrol et", "bunu dahil edilmedi sanmıştım"])
    }

    func testTelegramServiceEventIsNotUserSpeech() {
        let data = Data(#"{"messages":[{"type":"service","from":"Ali","text":"created a group"},{"type":"message","from":"Ali","text":"selam"}]}"#.utf8)
        XCTAssertEqual(ChatExportParser.telegram(data).map(\.text), ["selam"])
    }

    func testMergeOrderSurvivesDictionarySerialization() throws {
        var imported = PersonalHistory()
        imported.observe(text: "önce sonra\nönce belki\nönce sonra\nabc@example.com def@example.com")
        let roundtrip = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(imported))
        var a = PersonalHistory(), b = PersonalHistory()
        a.merge(imported); b.merge(roundtrip)
        XCTAssertEqual(a, b)
    }
}

extension ImportParsingRegressionTests {
    func testTechnicalSurfaceCaseIsNotTurkishFolded() throws {
        var h = PersonalHistory()
        for value in ["https://example.com/Info", "https://example.com/info", "Info@example.com", "info@example.com"] {
            h.observe(token: value, previous: nil)
        }
        XCTAssertEqual(h.tokens.count, 4)
        XCTAssertEqual(h.recall(prefix: "https://example.com/I"), ["https://example.com/Info"])
        XCTAssertEqual(h.recall(prefix: "Info@"), ["Info@example.com"])
        let restored = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(restored, h)
    }
}

extension ImportParsingRegressionTests {
    func testTechnicalPunctuationRemainsLiteral() {
        for surface in [".env", "../config/Info", "./src/index.tsx", "https://example.com/a?b=1&c=2", "\"local.part\"@example.com"] {
            XCTAssertEqual(PersonalHistory.tokenize(surface), [surface])
        }
        XCTAssertEqual(PersonalHistory.tokenize("akşam, 192.168.1.1."), ["akşam", "192.168.1.1"])
        XCTAssertEqual(PersonalHistory.tokenize("(dev@example.com)"), ["dev@example.com"])
        let quoted = "\"First Last\"@example.com"
        XCTAssertEqual(PersonalHistory.tokenize("mail " + quoted + " bitti"), ["mail", quoted, "bitti"])
        XCTAssertEqual(TechnicalTokenKind.classify(quoted), .email)
        XCTAssertEqual(TechnicalTokenKind.classify("\"First@Last\"@example.com"), .email)
    }
}

extension ImportParsingRegressionTests {
    func testSameNamedTelegramSendersRemainDistinguishable() {
        let data = Data(#"{"messages":[{"from":"Ali","from_id":"user1","text":"benim"},{"from":"Ali","from_id":"user2","text":"onun"}]}"#.utf8)
        let messages = ChatExportParser.telegram(data)
        XCTAssertEqual(Set(messages.map(\.sender)).count, 2)
        XCTAssertEqual(messages.filter { $0.sender == "Ali (user1)" }.map(\.text), ["benim"])
    }
}
