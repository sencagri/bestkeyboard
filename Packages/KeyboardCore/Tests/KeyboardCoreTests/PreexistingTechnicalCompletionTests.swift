import XCTest
import Foundation
import KBLearning

final class PreexistingTechnicalCompletionTests: XCTestCase {
    func testExplicitCompletionLearnsWithoutObservedDocumentStart() throws {
        var rows: [[String: String]] = []
        for (value, prefix) in [("https://example.com/Page", "https://example.com/Pa"),
                                ("Dev@example.com", "Dev@exa"),
                                ("\"First Last\"@example.com", "\"First Last\"@exa"),
                                ("+90 (532) 123 45 67", "+90 (532) 12"),
                                ("2001:db8::1234", "2001:db8::12")] {
            for leading in ["", "önce "] {
                for tail in ["", " sonra "] {
                    for middle in [false, true] {
                        for seeded in [false, true] {
                            var history = PersonalHistory(), observation = HistoryObservation()
                            history.observe(token: value, previous: nil)
                            if seeded { history.observe(text: "First Last önce") }
                            var expected = history
                            expected.observe(token: value, previous: PersonalHistory.tokenize(leading).last)
                            var before = leading + prefix
                            var after = (middle ? String(value.dropFirst(prefix.count + 1)) : "") + tail
                            let id = UUID()
                            // Attach to an existing host field; never observe an empty document.
                            observation.changed(before: before, documentID: id, after: after)
                            let offer = try XCTUnwrap(history.completions(before: before, after: after, selected: nil).first { $0.surface == value })
                            let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id))
                            for _ in offer.prefix {
                                observation.expectBackwardDeletion(before: before, after: after, documentID: id)
                                before.removeLast(); observation.changed(before: before, documentID: id, after: after)
                            }
                            before += offer.replacementBeforeCursor
                            observation.changed(before: before, documentID: id, after: after)
                            let event = observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor, rightToken: offer.rightToken,
                                resultingBefore: before, resultingAfter: after, documentID: id)
                            let label = "\(value) leading=\(leading) tail=\(tail) middle=\(middle) seeded=\(seeded)"
                            XCTAssertNotNil(event, label)
                            if let event { history.observe(event) }
                            let correct = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                                && history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                            XCTAssertTrue(correct, label)
                            XCTAssertNil(observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor, rightToken: offer.rightToken,
                                resultingBefore: before, resultingAfter: after, documentID: id))
                            before += after.prefix(offer.cursorAdvanceCount); after = String(after.dropFirst(offer.cursorAdvanceCount))
                            observation.changed(before: before, documentID: id, after: after)
                            before += " "
                            for _ in 0..<3 {
                                if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                            }
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            rows.append(["case": label, "immediate_event": String(event != nil), "correct_counts": String(correct)])
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 80)
        if let path = ProcessInfo.processInfo.environment["KB_PREEXISTING_COMPLETION_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
