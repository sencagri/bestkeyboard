import XCTest
import KBLearning

final class CursorReturnObservationTests: XCTestCase {
    func testFreshOccurrencesRetypedWordsAndOtherDocumentsStillCount() {
        var observation = HistoryObservation(), history = PersonalHistory()
        let id = UUID()
        observation.changed(before: "", documentID: id, after: "")
        for before in ["merhaba ", "merhaba merhaba "] {
            if let event = observation.completed(before: before, documentID: id, after: "") { history.observe(event) }
        }
        XCTAssertEqual(history.tokens["merhaba"]?.count, 2)
        observation.changed(before: "", documentID: id, after: "merhaba merhaba ")
        observation.changed(before: "merhaba merhaba ", documentID: id, after: "")
        XCTAssertNil(observation.completed(before: "merhaba merhaba  ", documentID: id, after: ""))
        // Deleting an occurrence, then writing it anew is new evidence.
        observation.changed(before: "merhaba m", documentID: id, after: "")
        if let event = observation.completed(before: "merhaba merhaba ", documentID: id, after: "") { history.observe(event) }
        XCTAssertEqual(history.tokens["merhaba"]?.count, 3)
        let other = UUID()
        observation.changed(before: "", documentID: other, after: "")
        if let event = observation.completed(before: "merhaba ", documentID: other, after: "") { history.observe(event) }
        XCTAssertEqual(history.tokens["merhaba"]?.count, 4)
    }

    func testCursorReturnKeepsProvisionalPhoneReconciliation() {
        var observation = HistoryObservation(), history = PersonalHistory(), text = ""
        let id = UUID()
        observation.changed(before: "", documentID: id, after: "")
        for part in ["+90 532 123 45 ", "67 "] {
            for character in part {
                text.append(character)
                observation.changed(before: text, documentID: id, after: "")
                if character.isWhitespace, let event = observation.completed(before: text, documentID: id, after: "") { history.observe(event) }
            }
            observation.changed(before: "", documentID: id, after: text)
            observation.changed(before: text, documentID: id, after: "")
            XCTAssertNil(observation.completed(before: text, documentID: id, after: ""))
        }
        var expected = PersonalHistory(); expected.observe(text: text)
        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count))
    }
}
