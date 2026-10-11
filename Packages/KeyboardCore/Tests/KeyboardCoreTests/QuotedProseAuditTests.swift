import XCTest
import Foundation
import KBLearning

final class QuotedProseAuditTests: XCTestCase {
    func testQuoteNormalizationKeepsTechnicalAndInternalApostrophes() {
        for token in ["Ankara'ya", "O'Reilly", "rock'n'roll", "git's", "e-posta", "TCP/IP", "./file's", "../path", ".env", "user'name@example.com", "https://example.com?q='value'", "/tmp/'name'", "‘git=>value’"] {
            XCTAssertEqual(PersonalHistory.tokenize(token), [token], token)
        }
        for text in ["“merhaba”,", "'merhaba'!", "‘merhaba’;", "“(merhaba)”", "('merhaba')", "“Ankara'ya”"] {
            XCTAssertEqual(PersonalHistory.tokenize(text), [text.contains("Ankara") ? "Ankara'ya" : "merhaba"], text)
        }
    }

    func testQuotedProseAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_QUOTED_PROSE_AUDIT"]
        func live(_ text: String) -> PersonalHistory {
            var history = PersonalHistory(), observation = HistoryObservation(), before = ""
            let id = UUID()
            observation.changed(before: "", documentID: id)
            for character in text {
                before.append(character)
                observation.changed(before: before, documentID: id)
                if character.isWhitespace, let event = observation.completed(before: before, documentID: id) {
                    history.observe(event)
                }
            }
            return history
        }
        var rows: [[String: String]] = []
        let wrappers = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»"), ("(", ")")]
        for (left, right) in wrappers {
            for phrase in ["merhaba", "merhaba dünya", "Ankara'ya gittim"] {
                for prefix in ["", "önce "] {
                    let text = prefix + left + phrase + right + " sonra "
                    // Oracle deliberately excludes prose delimiters. Internal
                    // Turkish apostrophes remain part of the expected words.
                    var expected = PersonalHistory()
                    expected.observe(text: prefix + phrase + " sonra ")
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    for (mode, actual) in [("bulk", bulk), ("live", live(text))] {
                        XCTAssertEqual(actual.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), text + mode)
                        XCTAssertEqual(actual.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, text + mode)
                        rows.append(["left": left, "right": right, "phrase": phrase, "prefix": prefix, "mode": mode,
                            "tokens_match": String(actual.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)),
                            "pairs_match": String(actual.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }),
                            "actual_surfaces": actual.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                            "expected_surfaces": expected.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                            "actual_next": actual.nextWords(after: "merhaba").joined(separator: " | "),
                            "expected_next": expected.nextWords(after: "merhaba").joined(separator: " | ")])
                    }
                }
            }
        }
        // These quoted or apostrophe-bearing technical identities must remain
        // exact rather than be treated as prose wrappers.
        for surface in ["\"First Last\"@example.com", "\"o o\"@example.com", "o'connor@example.com",
                        "https://example.com/o'connor", "Ankara'ya", "e-posta"] {
            for history in [live(surface + " "), { var h = PersonalHistory(); h.observe(text: surface); return h }()] {
                XCTAssertTrue(history.tokens.values.contains { $0.surface == surface }, surface)
                XCTAssertEqual(history.tokens.count, 1, surface)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
