import XCTest
import Foundation
import KBLearning

final class SuccessiveSingleWordHistoryTests: XCTestCase {
    func testSuccessiveCorrectionsAndRestorationsPreserveOwnedHistory() throws {
        let originals = ["Kalen", "Guzel", "Qrmenü"]
        let replacements = ["Kalem", "Güzel", "Qrmenüler"]
        let orders = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
        var stages = 0
        for order in orders {
            for suffix in ["", ".", ",", "…"] {
                for seeded in [false, true] {
                    for padded in [false, true] {
                        let id = UUID()
                        var observation = HistoryObservation(), history = PersonalHistory()
                        let original = originals.joined(separator: " ") + suffix
                        if seeded { history.observe(text: original) }
                        observation.changed(before: "", documentID: id)
                        for end in 1...originals.count {
                            let prefix = originals.prefix(end).joined(separator: " ") + (end == originals.count ? suffix : "") + " "
                            if let event = observation.completed(before: prefix, documentID: id) { history.observe(event) }
                        }
                        var words = originals
                        for restore in [false, true] {
                            for index in order {
                                var before = words.prefix(index).joined(separator: " ") + (index > 0 ? " " : "")
                                var selected = words[index]
                                var after = (index + 1 < words.count ? " " + words.suffix(from: index + 1).joined(separator: " ") : "") + suffix + " "
                                var inserted = restore ? originals[index] : replacements[index]
                                if padded {
                                    if before.last == " " { before.removeLast(); selected = " " + selected; inserted = " " + inserted }
                                    if after.first == " " { after.removeFirst(); selected += " "; inserted += " " }
                                }
                                observation.changed(before: before, documentID: id, after: selected + after)
                                let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: selected, after: after, documentID: id))
                                for event in observation.completedSelection(witness, inserted: inserted, resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                                words[index] = restore ? originals[index] : replacements[index]
                                var expected = PersonalHistory()
                                if seeded { expected.observe(text: original) }
                                expected.observe(text: words.joined(separator: " ") + suffix)
                                let context = "order=\(order), suffix=\(suffix), seeded=\(seeded), padded=\(padded), restore=\(restore), index=\(index)"
                                XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), context)
                                XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, context)
                                let accepted = history
                                for _ in 0..<3 {
                                    for event in observation.completedSelection(witness, inserted: inserted, resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                                    if let event = observation.completed(before: before + inserted, documentID: id, after: after) { history.observe(event) }
                                }
                                XCTAssertEqual(history, accepted, context)
                                stages += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(stages, 576)
    }
}
