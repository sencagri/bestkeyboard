import XCTest
import Foundation
import KBLearning
import KBRuntime

final class CaseFoldedCompletionHistoryTests: XCTestCase {
    func testCaseInsensitiveComponentsReconcileImmediately() throws {
        let samples = [("Dev@EXAMPLE.com", "Dev@exa"), ("Dev@example.com", "Dev@EXA"),
                       ("https://EXAMPLE.com/Page", "https://example.com/P"),
                       ("HTTPS://example.com/Page", "https://example.com/P"),
                       ("\"First Last\"@EXAMPLE.com", "\"First Last\"@exa"),
                       ("\"First Last\"@example.com", "\"First Last\"@EXA")]
        var stages = 0
        for (value, prefix) in samples {
            for right: String? in [nil, ""] {
                for separator in [" ", "\n", "\u{00a0}"] {
                    for leading in ["", "önce "] {
                      for independent in [false, true] {
                        var before = "", history = PersonalHistory(), observation = HistoryObservation(), end = DocumentEndWitness()
                        let id = UUID()
                        if independent { history.observe(text: "First Last") }
                        func context() -> SuggestionContext { .init(documentID: id, before: before, selected: nil, after: right) }
                        XCTAssertTrue(end.observe(context(), hasText: false))
                        observation.changed(before: before, documentID: id, after: right)
                        func changed(_ mutate: () -> Void) {
                            let prior = context(), known = end.observe(context(), hasText: !before.isEmpty)
                            mutate()
                            end.didEdit(from: prior, to: context(), wasAtEnd: known)
                            observation.changed(before: before, documentID: id, after: right)
                        }
                        func observeBoundary() {
                            if let event = observation.completed(before: before, documentID: id, after: right) { history.observe(event) }
                        }
                        func type(_ text: String) {
                            for ch in text { changed { before.append(ch) }; if ch.isWhitespace { observeBoundary() } }
                        }
                        func erase(_ count: Int) {
                            for _ in 0..<count {
                                observation.expectBackwardDeletion(before: before, after: right, documentID: id)
                                changed { before.removeLast() }
                            }
                        }
                        type(leading + value + separator)
                        var expected = history
                        for cycle in 1...3 {
                            type(prefix)
                            let known = end.observe(context(), hasText: true)
                            XCTAssertTrue(known)
                            let normalizedRight = right ?? (known ? "" : nil)
                            let offer = try XCTUnwrap(history.completions(before: before, after: normalizedRight, selected: nil).first { $0.surface == value })
                            XCTAssertTrue(offer.matches(before: before, after: normalizedRight, selected: nil))
                            let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: right, replacing: offer.prefix, documentID: id))
                            erase(offer.prefix.count)
                            changed { before += offer.replacementBeforeCursor }
                            let event = observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor,
                                resultingBefore: before, resultingAfter: right, documentID: id)
                            XCTAssertNotNil(event, "Missing immediate event: \(value) prefix=\(prefix)")
                            if let event { history.observe(event) }
                            var immediate = expected; immediate.observe(token: value, previous: nil)
                            XCTAssertEqual(history.tokens.mapValues(\.count), immediate.tokens.mapValues(\.count), "Immediate counts: \(value)")
                            type(separator)
                            expected.observe(token: value, previous: nil)
                            let label = "\(value) right=\(String(describing: right)) separator=\(separator.debugDescription) leading=\(leading) cycle=\(cycle)"
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let accepted = history
                            for _ in 0..<3 { observeBoundary() }
                            erase(separator.count); type(separator)
                            XCTAssertEqual(history, accepted, "Separator reopen: " + label)
                            erase((value + separator).count)
                            type(value + separator)
                            expected.observe(token: value, previous: nil)
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), "Retype: " + label)
                            stages += 1
                        }
                      }
                    }
                }
            }
        }
        XCTAssertEqual(stages, 432)
    }
    func testSensitiveMailboxAndPathChangesRemainRejected() throws {
        for (prefix, invalid, valid) in [
            ("Dev@exa", "dev@example.com", "Dev@EXAMPLE.com"),
            ("https://example.com/Pa", "https://example.com/page", "HTTPS://EXAMPLE.com/Page"),
            ("https://User@example.com/P", "https://user@example.com/Page", "HTTPS://User@EXAMPLE.com/Page")
        ] {
            var observation = HistoryObservation()
            let id = UUID()
            observation.changed(before: "", documentID: id, after: "")
            observation.changed(before: prefix, documentID: id, after: "")
            let witness = try XCTUnwrap(observation.technicalReplacement(before: prefix, after: "", replacing: prefix, documentID: id))
            XCTAssertNil(observation.completedTechnicalReplacement(witness, inserted: invalid,
                resultingBefore: invalid, resultingAfter: "", documentID: id))
            XCTAssertNotNil(observation.completedTechnicalReplacement(witness, inserted: valid,
                resultingBefore: valid, resultingAfter: "", documentID: id))
        }
    }

}
