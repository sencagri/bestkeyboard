import XCTest
import Foundation
import KBLearning

final class MiddlePhoneCompletionHistoryTests: XCTestCase {
    func testFormattedPhoneCompletionsPreserveHistoryAndRightTail() throws {
        var cases = 0
        for value in ["+905321234567", "+90 532 123 45 67", "0532 123 45 67", "(0532) 123 45 67",
                      "+90 (532) 123-45-67", "+90\u{00a0}532\u{00a0}123\u{00a0}45\u{00a0}67"] {
            let characters = Array(value)
            for cut in 3..<(characters.count - 1) where characters[cut].isNumber && characters.prefix(cut).filter(\.isNumber).count >= 3 {
                let prefix = String(value.prefix(cut)), rightToken = String(value.dropFirst(cut + 1))
                for leading in ["", "önce "] {
                    for tail in ["", " sonra "] {
                        for seeded in [false, true] {
                            var history = PersonalHistory(), observation = HistoryObservation(), before = "", after = rightToken + tail
                            let id = UUID()
                            history.observe(text: value)
                            if seeded { history.observe(text: "önce 0532 sonra") }
                            var expected = history; expected.observe(text: leading + value)
                            observation.changed(before: before, documentID: id, after: after)
                            for ch in leading + prefix {
                                before.append(ch); observation.changed(before: before, documentID: id, after: after)
                                if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                            }
                            cases += 1
                            guard let offer = history.completions(before: before, after: after, selected: nil).first(where: { $0.surface == value }) else {
                                XCTFail("Missing formatted phone offer: \(value) cut=\(cut)"); continue
                            }
                            XCTAssertEqual(offer.rightToken, rightToken)
                            let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: offer.prefix, documentID: id))
                            for _ in offer.prefix {
                                observation.expectBackwardDeletion(before: before, after: after, documentID: id)
                                before.removeLast(); observation.changed(before: before, documentID: id, after: after)
                            }
                            before += offer.replacementBeforeCursor
                            observation.changed(before: before, documentID: id, after: after)
                            // Reconcile the complete value before the UI advances over the existing right token.
                            if let event = observation.completedTechnicalReplacement(witness,
                                inserted: offer.replacementBeforeCursor, rightToken: offer.rightToken, resultingBefore: before, resultingAfter: after, documentID: id) { history.observe(event) }
                            before += offer.rightToken; after = String(after.dropFirst(offer.rightToken.count))
                            observation.changed(before: before, documentID: id, after: after)
                            before += " "
                            if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                            let label = "\(value) cut=\(cut) leading=\(leading) tail=\(tail) seed=\(seeded)"
                            XCTAssertEqual(before + after, leading + value + " " + tail, label)
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let accepted = history
                            for _ in 0..<3 {
                                if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                            }
                            XCTAssertEqual(history, accepted, label)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 368)
        print("MIDDLE PHONE HISTORY: \(cases) traces")
    }
}
