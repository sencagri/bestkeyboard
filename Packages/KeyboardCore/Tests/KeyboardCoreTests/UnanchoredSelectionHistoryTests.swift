import XCTest
import Foundation
import KBLearning

final class UnanchoredSelectionHistoryTests: XCTestCase {
    func testLimitedContextCorrectionsPreserveUnownedHistory() throws {
        var cases = 0
        for (old, correction) in [("Kalen", "Kalem"), ("Guzel", "Güzel"), ("Qrmenü", "Qrmenü")] {
            for mode in ["fresh", "document_switch", "truncated"] {
                for prefix in ["önce ", "👩‍💻 önce ", "satır\nönce ", "https://example.com önce "] {
                    for rawAfter: String? in [" sonra ", ". sonra ", nil] {
                        for padded in [false, true] {
                            var observation = HistoryObservation(), history = PersonalHistory()
                            var id = UUID()
                            history.observe(text: "önce " + old + " sonra")
                            if mode != "fresh" {
                                observation.changed(before: "", documentID: id)
                                var context = ""
                                for ch in "gizli " + prefix + old + (rawAfter ?? " ") {
                                    context.append(ch)
                                    if ch.isWhitespace, let event = observation.completed(before: context, documentID: id) { history.observe(event) }
                                }
                                if mode == "document_switch" { id = UUID() }
                            }
                            var expected = history
                            if old != correction { expected.observe(token: correction, previous: "önce") }
                            var before = prefix, selected = old, after = rawAfter, inserted = correction
                            if padded {
                                before.removeLast(); selected = " " + selected; inserted = " " + inserted
                                if after?.first == " " { after!.removeFirst(); selected += " "; inserted += " " }
                            }
                            observation.changed(before: before, documentID: id, after: selected + (after ?? ""))
                            let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: selected, after: after, documentID: id))
                            for event in observation.completedSelection(witness, inserted: inserted, resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                            let label = "\(mode) \(old) \(prefix) after=\(String(describing: rawAfter)) padded=\(padded)"
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                            let accepted = history
                            for _ in 0..<3 {
                                for event in observation.completedSelection(witness, inserted: inserted, resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                            }
                            XCTAssertEqual(history, accepted, label)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 216)
    }
}
