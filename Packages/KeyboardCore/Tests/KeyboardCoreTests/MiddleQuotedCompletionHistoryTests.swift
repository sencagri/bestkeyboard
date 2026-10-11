import XCTest
import Foundation
import KBLearning

final class MiddleQuotedCompletionHistoryTests: XCTestCase {
    func testMiddleQuotedCompletionRetiresOnlyProvisionalWords() throws {
        var cases = 0
        for value in ["\"First Last\"@example.com", "\"First Middle Last\"@other.net", "\"One Two\"@EXAMPLE.com"] {
            let firstSpace = value.distance(from: value.startIndex, to: value.firstIndex(of: " ")!) + 1
            let domain = value.distance(from: value.startIndex, to: value.firstIndex(of: "@")!) + 1
            for cut in [firstSpace, domain + 1, domain + 3] {
                let prefix = String(value.prefix(cut)), rightToken = String(value.dropFirst(cut + 1))
                for leading in ["", "önce "] {
                    for tail in ["", " sonra "] {
                        for seeded in [false, true] {
                            var history = PersonalHistory(), observation = HistoryObservation(), before = "", after = rightToken + tail
                            let id = UUID()
                            history.observe(text: value)
                            if seeded { history.observe(text: "önce First One sonra") }
                            var expected = history; expected.observe(text: leading + value)
                            observation.changed(before: before, documentID: id, after: after)
                            for ch in leading + prefix {
                                before.append(ch); observation.changed(before: before, documentID: id, after: after)
                                if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                            }
                            let offer = try XCTUnwrap(history.completions(before: before, after: after, selected: nil).first { $0.surface == value })
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
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 72)
    }
}
