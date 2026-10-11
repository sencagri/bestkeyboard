import XCTest
import Foundation
import KBLearning

final class PreexistingTechnicalWitnessSafetyTests: XCTestCase {
    func testRejectedPartialResultsDoNotConsumeValidCompletion() throws {
        var rows: [[String: String]] = []
        for (value, prefix) in [("https://EXAMPLE.com/Page", "https://example.com/Pa"),
                                ("Dev@EXAMPLE.com", "Dev@exa"),
                                ("\"First Last\"@example.com", "\"First Last\"@exa"),
                                ("+90 (532) 123 45 67", "+90 (532) 12"),
                                ("2001:db8::1234", "2001:db8::12")] {
            for leading in ["", "önce "] {
                for tail in ["", " sonra "] {
                    for middle in [false, true] {
                        for seeded in [false, true] {
                            var history = PersonalHistory(), observation = HistoryObservation()
                            history.observe(token: value, previous: nil)
                            if seeded { history.observe(text: "First Last önce " + value) }
                            let before = leading + prefix
                            let after = (middle ? String(value.dropFirst(prefix.count + 1)) : "") + tail
                            let id = UUID()
                            observation.changed(before: before, documentID: id, after: after)
                            let offer = try XCTUnwrap(history.completions(before: before, after: after, selected: nil).first { $0.surface == value })
                            let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id))
                            let inserted = offer.replacementBeforeCursor, result = leading + inserted
                            let original = history
                            let label = "\(value) leading=\(leading) tail=\(tail) middle=\(middle) seeded=\(seeded)"
                            var rejected = 0
                            for (badBefore, badAfter, badID) in [(String(result.dropFirst(1)), Optional(after), id),
                                (result, nil, id), (result, Optional(after + "changed"), id), (result, Optional(after), UUID())] {
                                let event = observation.completedTechnicalReplacement(witness, inserted: inserted, rightToken: offer.rightToken,
                                    resultingBefore: badBefore, resultingAfter: badAfter, documentID: badID)
                                XCTAssertNil(event, label)
                                if let event { history.observe(event) } else { rejected += 1 }
                                XCTAssertNotNil(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id), label)
                            }
                            XCTAssertEqual(history, original, label)
                            let event = try XCTUnwrap(observation.completedTechnicalReplacement(witness, inserted: inserted, rightToken: offer.rightToken,
                                resultingBefore: result, resultingAfter: after, documentID: id))
                            history.observe(event)
                            var expected = original; expected.observe(token: value, previous: PersonalHistory.tokenize(leading).last)
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let accepted = history
                            for _ in 0..<3 {
                                let duplicate = observation.completedTechnicalReplacement(witness, inserted: inserted, rightToken: offer.rightToken,
                                    resultingBefore: result, resultingAfter: after, documentID: id)
                                XCTAssertNil(duplicate, label)
                                if let duplicate { history.observe(duplicate) }
                            }
                            XCTAssertEqual(history, accepted, label)
                            rows.append(["case": label, "rejected_results": String(rejected), "valid_after_rejections": "true"])
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 80)
        if let path = ProcessInfo.processInfo.environment["KB_PREEXISTING_WITNESS_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
