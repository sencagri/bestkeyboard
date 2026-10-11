import XCTest
import Foundation
import KBLearning

final class URLQueryLearningAuditTests: XCTestCase {
    func testExplicitQueryCompletionPreservesLearningIdentity() throws {
        let suffixes = ["?q=(a)", "?q=a,b", "?q=a;b", "?q=a:b", "?q=a!", "?q=a?",
                        "?q=a.", "?q='a'", "?q=%28a%29", "?q=a&b=c", "#section(1)", "#a.b"]
        let wrappers = [("", ""), ("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""),
                        ("'", "'"), ("“", "”"), ("«", "»"), ("`", "`")]
        var rows: [[String: String]] = []
        for suffix in suffixes {
            let value = "https://example.com/path" + suffix, prefix = "https://example.com/pa"
            for (open, close) in wrappers {
                for middle in [false, true] {
                    for leading in ["", "önce "] {
                        for tail in ["", " sonra "] {
                            var history = PersonalHistory(), observation = HistoryObservation()
                            history.observe(token: value, previous: nil)
                            history.observe(text: "bağımsız önce")
                            var expected = history
                            expected.observe(token: value, previous: PersonalHistory.tokenize(leading).last)
                            let right = middle ? String(value.dropFirst(prefix.count + 1)) : ""
                            let punctuation = !close.isEmpty && !tail.isEmpty ? "," : ""
                            let before = leading + open + prefix, after = right + close + punctuation + tail
                            let id = UUID()
                            observation.changed(before: before, documentID: id, after: after)
                            let offer = try XCTUnwrap(history.completions(before: before, after: after, selected: nil).first { $0.surface == value })
                            let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id))
                            let result = leading + open + offer.replacementBeforeCursor
                            let event = observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor, rightToken: offer.rightToken,
                                resultingBefore: result, resultingAfter: after, documentID: id)
                            let label = "\(value) wrapper=\(open)\(close) middle=\(middle) leading=\(leading) tail=\(tail)"
                            XCTAssertNotNil(event, label)
                            if let event { history.observe(event); XCTAssertEqual(event.token, value, label) }
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let completedBefore = result + after.prefix(offer.cursorAdvanceCount)
                            let remaining = String(after.dropFirst(offer.cursorAdvanceCount))
                            observation.changed(before: completedBefore, documentID: id, after: remaining)
                            for _ in 0..<3 {
                                if let event = observation.completed(before: completedBefore + " ", documentID: id, after: remaining) { history.observe(event) }
                            }
                            let continuation = observation.completed(before: completedBefore + " sonra ", documentID: id, after: remaining)
                            XCTAssertNotNil(continuation, label)
                            if let continuation { history.observe(continuation) }
                            expected.observe(token: "sonra", previous: value)
                            let exact = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                                && history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                            XCTAssertTrue(exact, label)
                            rows.append(["case": label, "immediate_identity": String(event?.token == value), "final_counts_exact": String(exact)])
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 864)
        if let path = ProcessInfo.processInfo.environment["KB_URL_QUERY_LEARNING_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
