import XCTest
import Foundation
import KBLearning

final class WrappedCompletionHistoryTests: XCTestCase {
    func testWrapperCompletionLearnsOnlyTheAddressAndPreservesHistory() throws {
        var cases = 0
        for (value, prefix) in [("https://example.com/Page", "https://example.com/Pa"),
                                ("https://example.com/f(x)", "https://example.com/f("),
                                ("Dev@example.com", "Dev@exa"), ("\"First Last\"@example.com", "\"First Last\"@exa")] {
            for (open, close) in [("(", ")"), ("\"", "\""), ("'", "'"), ("“", "”"), ("«", "»"), ("[", "]"), ("{", "}"), ("`", "`")] {
                for middle in [false, true] {
                    for leading in ["", "önce "] {
                        for tail in ["", " sonra "] {
                            for seeded in [false, true] {
                                var history = PersonalHistory(), observation = HistoryObservation()
                                history.observe(token: value, previous: nil)
                                if seeded { history.observe(text: "First Last") }
                                var expected = history; expected.observe(text: leading + value)
                                var before = "", after = (middle ? String(value.dropFirst(prefix.count + 1)) : "") + close + tail
                                let id = UUID()
                                observation.changed(before: before, documentID: id, after: after)
                                for ch in leading + open + prefix {
                                    before.append(ch); observation.changed(before: before, documentID: id, after: after)
                                    if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                                }
                                let label = "\(open)\(value)\(close) middle=\(middle) leading=\(leading) tail=\(tail) seeded=\(seeded)"
                                cases += 1
                                guard let offer = history.completions(before: before, after: after, selected: nil).first(where: { $0.surface == value }) else { XCTFail("Missing offer: " + label); continue }
                                let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id))
                                for _ in offer.prefix {
                                    observation.expectBackwardDeletion(before: before, after: after, documentID: id)
                                    before.removeLast(); observation.changed(before: before, documentID: id, after: after)
                                }
                                before += offer.replacementBeforeCursor; observation.changed(before: before, documentID: id, after: after)
                                let event = observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor,
                                    rightToken: offer.rightToken, resultingBefore: before, resultingAfter: after, documentID: id)
                                XCTAssertNotNil(event, label)
                                if let event { history.observe(event) }
                                XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                                XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                                let accepted = history
                                XCTAssertNil(observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor,
                                    rightToken: offer.rightToken, resultingBefore: before, resultingAfter: after, documentID: id))
                                before += after.prefix(offer.cursorAdvanceCount); after = String(after.dropFirst(offer.cursorAdvanceCount))
                                observation.changed(before: before, documentID: id, after: after)
                                XCTAssertEqual(before + after, leading + open + value + close + tail, label)
                                before += " "
                                for _ in 0..<3 {
                                    if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                                }
                                XCTAssertEqual(history, accepted, label)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 512)
    }
    func testNestedWrappersAndUnsafeAdjacentCode() throws {
        for value in ["https://example.com/f(x)", "\"First Last\"@example.com"] {
            var history = PersonalHistory(); history.observe(token: value, previous: nil)
            let prefix = String(value.dropLast(2))
            for (open, close) in [("([", "])") , ("(\"", "\")"), ("[{`", "`}]")] {
                for punctuation in ["", ",", ";"] {
                    let before = "before " + open + prefix, after = close + punctuation + " next"
                    let offer = try XCTUnwrap(history.completions(before: before, after: after, selected: nil).first { $0.surface == value })
                    XCTAssertEqual(String(before.dropLast(offer.prefix.count)) + offer.replacementBeforeCursor + after,
                        "before " + open + value + close + punctuation + " next")
                    XCTAssertEqual(offer.cursorAdvanceCount, (close + punctuation).count)
                }
            }
            for (before, after) in [("path/\"" + prefix, "\""), ("id_\"" + prefix, "\""),
                                    ("(" + prefix, ")attached"), ("[" + prefix, "]code"), ("{" + prefix, "}tail")] {
                XCTAssertFalse(history.completions(before: before, after: after, selected: nil).contains { $0.surface == value })
            }
        }
    }

    func testAmbiguousWrapperSearchHasABoundedBudget() {
        var history = PersonalHistory(); history.observe(token: "https://example.com/Page", previous: nil)
        for count in [16, 32, 64, 96] {
            let before = String(repeating: "( ", count: count) + "https://example.com/Pa"
            XCTAssertTrue(history.completions(before: before, after: String(repeating: ")", count: 8), selected: nil).isEmpty)
        }
    }

}
