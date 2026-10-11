import XCTest
import Foundation
import KBLearning

final class WrappedAddressLearningAuditTests: XCTestCase {
    func testAddressQuoteNormalizationPreservesInnerAndUnbalancedSyntax() {
        for token in ["\"First Last\"@example.com", "\"a\\\" b\"@example.com", "O'Neil@example.com",
                      "https://example.com/O'Reilly", "https://example.com/?q='value'",
                      "https://example.com/%22Value%22", "\"https://example.com", "https://example.com/\"",
                      "'https://example.com", "https://example.com/'", "'git=>value'", "/tmp/'name'"] {
            XCTAssertEqual(PersonalHistory.tokenize(token), [token], token)
        }
        for fragment in ["'", "‘", "’", "“", "”", "''", "’,"] {
            XCTAssertEqual(PersonalHistory.tokenize(fragment), [], fragment)
        }
    }

    func testStandaloneClosingQuotesDoNotRelearnPreviousWord() {
        for suffix in ["' ", "’ ", "” ", "’, "] {
            var observation = HistoryObservation(), history = PersonalHistory()
            let id = UUID()
            observation.changed(before: "", documentID: id)
            if let event = observation.completed(before: "önce merhaba ", documentID: id) { history.observe(event) }
            let event = observation.completed(before: "önce merhaba " + suffix, documentID: id)
            XCTAssertNil(event, suffix)
            if let event { history.observe(event) }
            XCTAssertEqual(history.tokens["merhaba"]?.count, 1)
            XCTAssertEqual(history.pairs["önce"]?["merhaba"]?.count, 1)
        }
    }

    func testExplicitWrapperSuffixPreservesAddressInterior() {
        for address in ["https://example.com/f(x)", "https://example.com/a,b;c", "https://example.com/search?q=a,b;",
                        "https://example.com/O'Reilly", "Dev@example.com"] {
            for wrapper in ["(\(address)),", "\"\(address)\";", "«\(address)».!?", "(“\(address)”);", "'\(address)'…"] {
                XCTAssertEqual(PersonalHistory.tokenize(wrapper), [address], wrapper)
            }
            XCTAssertEqual(PersonalHistory.tokenize(address), [address])
        }
        for unbalanced in ["(https://example.com/path,", "\"https://example.com/path;", "https://example.com/path,", "https://example.com/query?q=a;", "https://example.com/f(x)"] {
            XCTAssertEqual(PersonalHistory.tokenize(unbalanced), [unbalanced], unbalanced)
        }
    }

    func testWrappedAddressLearningAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_WRAPPED_ADDRESS_AUDIT"]
        var rows: [[String: String]] = []
        let samples = [("https://example.com/Docs", "https://example.com/D"),
                       ("https://example.com/search?q=O'Reilly", "https://example.com/search?q=O"),
                       ("Dev@example.com", "Dev@exa"),
                       ("\"First Last\"@example.com", "\"First Last\"@exa")]
        for (surface, prefix) in samples {
            for (left, right) in [("", ""), ("\"", "\""), ("'", "'"), ("“", "”"), ("«", "»"), ("(", ")")] {
                for suffix in ["", ",", ".", ";"] where !left.isEmpty || suffix.isEmpty {
                    let text = "adres " + left + surface + right + suffix + " sonra "
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for character in text {
                        before.append(character)
                        observation.changed(before: before, documentID: id)
                        if character.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let count = history.tokens.values.first { $0.surface == surface }?.count ?? 0
                        let offers = history.completions(before: prefix, after: "", selected: nil)
                        let exact = offers.contains { $0.surface == surface && $0.source == .observed }
                        XCTAssertEqual(count, 1, text + mode)
                        XCTAssertTrue(exact, text + mode)
                        rows.append(["surface": surface, "prefix": prefix, "left": left, "right": right, "mode": mode, "suffix": suffix,
                            "exact_count": String(count), "exact_observed_completion": String(exact),
                            "stored": history.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                            "offers": offers.map(\.surface).joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
