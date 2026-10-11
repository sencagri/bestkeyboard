import XCTest
import Foundation
import KBLearning

final class PartialSelectionBoundaryAuditTests: XCTestCase {
    func testPartialConfirmationDoesNotSuppressNewBoundary() throws {
        let output = ProcessInfo.processInfo.environment["KB_PARTIAL_SELECTION_BOUNDARY_AUDIT"]
        var rows: [[String: String]] = []
        for (left, right) in [("merhaba", "dünya"), ("su", "iç"), ("iyi", "ki"),
                              ("qrmenü", "den"), ("teknik", "ler"), ("geliştirici", "lerden"),
                              ("kalem", ".com"), ("kitap", "'tan"), ("kod", "_value"), ("dosya", "/yolu")] {
            for leading in ["", "önce "] {
                for separator in [" ", "\n"] {
                    for confirmed in [false, true] {
                        var observation = HistoryObservation(), history = PersonalHistory()
                        let id = UUID(), original = leading + left + right + " "
                        observation.changed(before: "", documentID: id, after: "")
                        var typed = ""
                        for ch in original {
                            typed.append(ch)
                            observation.changed(before: typed, documentID: id, after: "")
                            if ch.isWhitespace, let event = observation.completed(before: typed, documentID: id, after: "") { history.observe(event) }
                        }
                        let countBefore = history.tokens[left]?.count ?? 0
                        if confirmed {
                            observation.changed(before: leading, documentID: id, after: right + " ", selected: left)
                        } else {
                            observation.changed(before: leading + left, documentID: id, after: right + " ")
                        }
                        let confirmation = observation.completed(before: leading + left, documentID: id, after: right + " ")
                        if let confirmation { history.observe(confirmation) }
                        let event = observation.completed(before: leading + left + separator, documentID: id, after: right + " ")
                        if let event { history.observe(event) }
                        XCTAssertNil(confirmation, left + right)
                        XCTAssertEqual(history.tokens[left]?.count, countBefore + 1, left + right)
                        rows.append(["left": left, "right": right, "leading": leading, "separator": separator,
                                     "confirmed": String(confirmed), "confirmation_no_event": String(confirmation == nil),
                                     "new_left_once": String(history.tokens[left]?.count == countBefore + 1), "event": event?.token ?? "nil"])
                    }
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try e.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
