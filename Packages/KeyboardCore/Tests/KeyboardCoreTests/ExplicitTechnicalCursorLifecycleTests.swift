import XCTest
import Foundation
import KBLearning

final class ExplicitTechnicalCursorLifecycleTests: XCTestCase {
    func testCursorReturnRetypeAndDocumentReset() throws {
        var rows: [[String: String]] = []
        for (value, prefix) in [("https://example.com/Page", "https://example.com/Pa"),
                                ("Dev@example.com", "Dev@exa"),
                                ("\"First Last\"@example.com", "\"First Last\"@exa"),
                                ("+90 (532) 123 45 67", "+90 (532) 12"),
                                ("2001:db8::1234", "2001:db8::12")] {
            for leading in ["", "önce "] {
                for tail in ["", " sonra "] {
                    for position in [0, 1, 8] {
                        var history = PersonalHistory(), observation = HistoryObservation()
                        history.observe(token: value, previous: nil)
                        let id = UUID(), before = leading + prefix
                        observation.changed(before: before, documentID: id, after: tail)
                        let offer = try XCTUnwrap(history.completions(before: before, after: tail, selected: nil).first { $0.surface == value })
                        let witness = try XCTUnwrap(observation.technicalReplacement(before: before, after: tail, replacing: offer.prefix, documentID: id))
                        let finalBefore = leading + offer.surface
                        let event = try XCTUnwrap(observation.completedTechnicalReplacement(witness, inserted: offer.surface, resultingBefore: finalBefore, resultingAfter: tail, documentID: id))
                        history.observe(event)
                        let accepted = history
                        let document = finalBefore + tail
                        let cursorBefore = String(document.prefix(position)), cursorAfter = String(document.dropFirst(position))
                        observation.changed(before: cursorBefore, documentID: id, after: cursorAfter)
                        observation.changed(before: finalBefore, documentID: id, after: tail)
                        for _ in 0..<3 {
                            if let event = observation.completed(before: finalBefore + " ", documentID: id, after: tail) { history.observe(event) }
                        }
                        let stable = history == accepted
                        let label = "\(value) leading=\(leading) tail=\(tail) cursor=\(position)"
                        XCTAssertTrue(stable, label)
                        // A real deletion invalidates the receipt; retyping at a known
                        // empty start is a new occurrence, not another cursor callback.
                        observation.changed(before: "", documentID: id, after: "")
                        if let event = observation.completed(before: value + " ", documentID: id, after: "") { history.observe(event) }
                        var expected = accepted; expected.observe(token: value, previous: nil)
                        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                        observation.reset()
                        let other = UUID()
                        observation.changed(before: "", documentID: other, after: "")
                        if let event = observation.completed(before: value + " ", documentID: other, after: "") { history.observe(event) }
                        expected.observe(token: value, previous: nil)
                        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                        rows.append(["case": label, "cursor_return_stable": String(stable)])
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 60)
        if let path = ProcessInfo.processInfo.environment["KB_EXPLICIT_CURSOR_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
