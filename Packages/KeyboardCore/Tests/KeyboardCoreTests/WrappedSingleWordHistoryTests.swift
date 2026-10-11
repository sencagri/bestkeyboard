import XCTest
import Foundation
import KBLearning

final class WrappedSingleWordHistoryTests: XCTestCase {
    func testWrappedCorrectionsRespectLineBoundaries() throws {
        var cases = 0
        for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}"), ("«", "»"),
                                   ("“", "”"), ("‘", "’"), ("'", "'"), ("\"", "\""),
                                   ("〈", "〉"), ("「", "」"), ("【", "】"), ("‹", "›")] {
            for leftGap in [" ", "\n", "\r\n"] {
                for rightGap in [" ", "\n", "\r\n"] {
                    for seeded in [false, true] {
                        for (old, replacement) in [("Kalen", "Kalem"), ("Guzel", "Güzel")] {
                            let before = "önce" + leftGap + opening, after = closing + rightGap + "sonra "
                            let original = before + old + after
                            XCTAssertEqual(PersonalHistory.tokenize(opening + old + closing), [old])
                            var observation = HistoryObservation(), history = PersonalHistory()
                            let id = UUID()
                            if seeded { history.observe(text: original) }
                            observation.changed(before: "", documentID: id)
                            var typed = ""
                            for ch in original {
                                typed.append(ch)
                                observation.changed(before: typed, documentID: id)
                                if ch.isWhitespace, let event = observation.completed(before: typed, documentID: id) { history.observe(event) }
                            }
                            let label = "\(opening)\(closing) left=\(leftGap.debugDescription) right=\(rightGap.debugDescription) seed=\(seeded) old=\(old)"
                            var initialExpected = PersonalHistory()
                            for _ in 0..<(seeded ? 2 : 1) { initialExpected.observe(text: original) }
                            XCTAssertEqual(history.tokens.mapValues(\.count), initialExpected.tokens.mapValues(\.count), "fixture " + label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, initialExpected.pairs.mapValues { $0.mapValues(\.count) }, "fixture " + label)
                            observation.changed(before: before, documentID: id, after: old + after)
                            guard let witness = observation.selectionReplacement(before: before, selected: old, after: after, documentID: id) else {
                                XCTFail("Missing prose selection witness: " + label); continue
                            }
                            for event in observation.completedSelection(witness, inserted: replacement, resultingBefore: before + replacement, resultingAfter: after, documentID: id) { history.observe(event) }
                            var expected = PersonalHistory()
                            if seeded { expected.observe(text: original) }
                            expected.observe(text: before + replacement + after)
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let accepted = history
                            for _ in 0..<3 {
                                if let event = observation.completed(before: before + replacement, documentID: id, after: after) { history.observe(event) }
                            }
                            XCTAssertEqual(history, accepted, label)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 432)
    }
}
