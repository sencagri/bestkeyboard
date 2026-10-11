import XCTest
import Foundation
import KBLearning

final class TechnicalReplacementWitnessTests: XCTestCase {
    func testReplacementRejectsStaleResultsAndPreservesIndependentEvidence() throws {
        let samples = [("Dev@example.com", "Dev@exa"), ("\"First Last\"@example.com", "\"First Last\"@exa"),
                       ("\"Çağrı Şen\"@örnek.com", "\"Çağrı Şen\"@örn")]
        var cases = 0
        for (value, prefix) in samples {
            for after: String? in [nil, "", " sonra "] {
                for leading in ["", "önce ", "satır\nönce "] {
                    for seeded in [false, true] {
                        var observation = HistoryObservation(), history = PersonalHistory(), before = ""
                        let id = UUID()
                        if seeded { history.observe(text: "First Çağrı önce " + value) }
                        var expected = history
                        expected.observe(text: leading)
                        expected.observe(token: value, previous: PersonalHistory.tokenize(leading).last)
                        observation.changed(before: "", documentID: id, after: after)
                        for ch in leading + prefix {
                            before.append(ch)
                            observation.changed(before: before, documentID: id, after: after)
                            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        }
                        let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: after, replacing: prefix, documentID: id))
                        let finalBefore = leading + value
                        let original = history
                        for (inserted, result, right, document) in [(value, finalBefore, after, UUID()),
                            (value, finalBefore + "x", after, id), (value, finalBefore, "changed", id),
                            ("Other@example.com", leading + "Other@example.com", after, id)] {
                            let event = observation.completedTechnicalReplacement(witness, inserted: inserted,
                                resultingBefore: result, resultingAfter: right, documentID: document)
                            XCTAssertNil(event)
                            if let event { history.observe(event) }
                        }
                        XCTAssertEqual(history, original)
                        for _ in prefix {
                            observation.expectBackwardDeletion(before: before, after: after, documentID: id)
                            before.removeLast(); observation.changed(before: before, documentID: id, after: after)
                        }
                        before += value; observation.changed(before: before, documentID: id, after: after)
                        let event = try XCTUnwrap(observation.completedTechnicalReplacement(witness, inserted: value,
                            resultingBefore: before, resultingAfter: after, documentID: id))
                        history.observe(event)
                        let label = value + " " + leading + " seeded=\(seeded) after=\(String(describing: after))"
                        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                        XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                        let accepted = history
                        for _ in 0..<3 {
                            let duplicate = observation.completedTechnicalReplacement(witness, inserted: value,
                                resultingBefore: before, resultingAfter: after, documentID: id)
                            XCTAssertNil(duplicate)
                            if let duplicate { history.observe(duplicate) }
                        }
                        XCTAssertEqual(history, accepted)
                        before += " başka "
                        if let added = observation.completed(before: before, documentID: id, after: after) { history.observe(added) }
                        let later = history
                        XCTAssertNil(observation.completedTechnicalReplacement(witness, inserted: value,
                            resultingBefore: finalBefore, resultingAfter: after, documentID: id))
                        XCTAssertEqual(history, later)
                        XCTAssertEqual(history.tokens["başka"]?.count, 1)
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 54)
    }
}
