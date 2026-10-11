import XCTest
import Foundation
import KBLearning
import KBRuntime

final class PhoneFormattingCompletionHistoryTests: XCTestCase {
    func testFormattingChangesDoNotLeavePartialPhoneHistory() throws {
        let samples = [("+905321234567", "+90 532 123 4"), ("+90 532 123 45 67", "+90532123"),
                       ("+90 (532) 123-45-67", "+90 532 123 4"),
                       ("+90\u{00a0}532\u{00a0}123\u{00a0}45\u{00a0}67", "+90 532 123 4")]
        var stages = 0
        for (value, prefix) in samples {
            for right: String? in [nil, ""] {
                for separator in [" ", "\n", "\u{00a0}"] {
                    for leading in ["", "önce "] {
                      for independent in [false, true] {
                        var before = "", history = PersonalHistory(), observation = HistoryObservation(), end = DocumentEndWitness()
                        let id = UUID()
                        if independent { history.observe(token: "+90 532 123", previous: nil) }
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
                            if let event = observation.completedTechnicalReplacement(witness, inserted: offer.replacementBeforeCursor,
                                resultingBefore: before, resultingAfter: right, documentID: id) { history.observe(event) }
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
        XCTAssertEqual(stages, 288)
    }
}
