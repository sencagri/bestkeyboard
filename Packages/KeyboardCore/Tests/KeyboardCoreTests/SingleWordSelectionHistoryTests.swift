import XCTest
import Foundation
import KBLearning

final class SingleWordSelectionHistoryTests: XCTestCase {
    func testSingleWordSelectionReconcilesOwnedCountsAndPairs() throws {
        for (old, replacement) in [("Kalen", "Kalem"), ("Guzel", "Güzel"), ("Qrmenü", "Qrmenü")] {
            for suffix in ["", ",", ".", "!", "?", ";", ":", "…"] {
                for padded in [false, true] {
                    for seeded in [false, true] {
                        var observation = HistoryObservation(), history = PersonalHistory()
                        let id = UUID()
                        let original = "önce " + old + " sonra" + suffix
                        if seeded { history.observe(text: original) }
                        observation.changed(before: "", documentID: id)
                        for before in ["önce ", "önce " + old + " ", original + " "] {
                            if let event = observation.completed(before: before, documentID: id) { history.observe(event) }
                        }
                        let before = padded ? "önce" : "önce "
                        let selected = padded ? " " + old + " " : old
                        let after = (padded ? "sonra" : " sonra") + suffix + " "
                        observation.changed(before: before, documentID: id, after: selected + after)
                        let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: selected, after: after, documentID: id))
                        let inserted = padded ? " " + replacement + " " : replacement
                        for event in observation.completedSelection(witness, inserted: inserted,
                            resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                        var expected = PersonalHistory()
                        if seeded { expected.observe(text: original) }
                        expected.observe(text: "önce " + replacement + " sonra" + suffix)
                        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), "\(old) \(suffix) padded=\(padded) seeded=\(seeded)")
                        XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) })
                        let accepted = history
                        for _ in 0..<5 {
                            for event in observation.completedSelection(witness, inserted: inserted,
                                resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                            if let event = observation.completed(before: before + inserted, documentID: id, after: after) { history.observe(event) }
                        }
                        XCTAssertEqual(history, accepted, "Repeated callbacks must not add observations")
                    }
                }
            }
        }
    }
}
