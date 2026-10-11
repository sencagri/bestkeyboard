import XCTest
import Foundation
import KBLearning

final class TurkishApostropheHistoryAuditTests: XCTestCase {
    func testLegacyCurlyWordCountsMergeAndForgetAfterCaseFold() throws {
        let legacy = #"{"tokens":{"Ankara’ya":{"count":2,"seq":1,"surface":"Ankara’ya"},"ANKARA’YA":{"count":3,"seq":2,"surface":"ANKARA’YA"}},"pairs":{},"seq":2}"#
        var history = try JSONDecoder().decode(PersonalHistory.self, from: Data(legacy.utf8))
        XCTAssertEqual(history.tokens.count, 1)
        XCTAssertEqual(history.tokens["ankara’ya"]?.count, 5)
        XCTAssertEqual(history.tokens["ankara’ya"]?.surface, "ANKARA’YA")
        XCTAssertTrue(history.pairs.isEmpty) // Missing historical context cannot be invented.
        history.observe(text: "önce Ankara’ya gittim")
        history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.nextWords(after: "ANKARA’YA"), ["gittim"])
        XCTAssertEqual(history.nextWords(after: "önce"), ["Ankara’ya"])
        history.forget("ANKARA’YA")
        XCTAssertNil(history.tokens["ankara’ya"])
        XCTAssertTrue(history.nextWords(after: "Ankara’ya").isEmpty)
        XCTAssertTrue(history.nextWords(after: "önce").isEmpty)
        XCTAssertNotNil(history.tokens["gittim"])
    }

    func testCurlyWordClassifierDoesNotFoldTechnicalIdentities() throws {
        for token in ["’Ankara", "Ankara’", "Ankara’’ya", "123’ya", "O’Neil@example.com", "https://example.com/O’Neil", "/tmp/O’Neil"] {
            XCTAssertFalse(PersonalHistory.isWord(token), token)
        }
        var history = PersonalHistory()
        let technical = ["O’Neil@example.com", "o’neil@example.com", "https://example.com/O’Neil", "https://example.com/o’neil"]
        for token in technical { history.observe(token: token, previous: nil) }
        history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.tokens.count, 4)
        for token in technical { XCTAssertEqual(history.tokens[token]?.surface, token) }
        XCTAssertEqual(PersonalHistory.tokenize("“Ankara’ya”"), ["Ankara’ya"])
        XCTAssertEqual(PersonalHistory.tokenize("‘Ankara’ya’"), ["Ankara’ya"])
    }

    func testApostropheHistoryAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_APOSTROPHE_HISTORY_AUDIT"]
        var rows: [[String: String]] = []
        for (root, suffix) in [("Ankara", "ya"), ("İstanbul", "a"), ("İzmir", "e"),
                               ("Türkiye", "ye"), ("Ahmet", "e"), ("API", "ye")] {
            for apostrophe in ["'", "’"] {
                let token = root + apostrophe + suffix
                for quoted in [false, true] {
                    let text = "önce " + (quoted ? "“" : "") + token + (quoted ? "”" : "") + " gittim "
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for character in text {
                        before.append(character)
                        observation.changed(before: before, documentID: id)
                        if character.isWhitespace, let event = observation.completed(before: before, documentID: id) {
                            live.observe(event)
                        }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let incoming = history.nextWords(after: "önce")
                        let outgoing = history.nextWords(after: token)
                        let count = history.tokens.values.first { $0.surface == token }?.count ?? 0
                        XCTAssertTrue(PersonalHistory.isWord(token))
                        XCTAssertEqual(incoming, [token]); XCTAssertEqual(outgoing, ["gittim"]); XCTAssertEqual(count, 1)
                        rows.append(["token": token, "quoted": String(quoted), "mode": mode,
                            "is_word": String(PersonalHistory.isWord(token)), "surface_count": String(count),
                            "incoming_match": String(incoming == [token]), "outgoing_match": String(outgoing == ["gittim"]),
                            "incoming": incoming.joined(separator: " | "), "outgoing": outgoing.joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
