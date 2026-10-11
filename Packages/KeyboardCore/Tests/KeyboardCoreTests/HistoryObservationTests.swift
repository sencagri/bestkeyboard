import XCTest
import KBLearning

final class HistoryObservationTests: XCTestCase {
    func testUnknownOrTruncatedTechnicalStartIsNotLearnedAsWholeAddress() {
        var observation = HistoryObservation()
        let id = UUID()
        XCTAssertNil(observation.completed(before: "ample.com/api ", documentID: id))
        observation.changed(before: "", documentID: id)
        observation.changed(before: "https://example.com/api", documentID: id)
        XCTAssertEqual(observation.completed(before: "https://example.com/api ", documentID: id)?.token, "https://example.com/api")
        observation.changed(before: "", documentID: id)
        observation.changed(before: "https://example.com/api/verylong", documentID: id)
        observation.changed(before: "example.com/api/verylong", documentID: id)
        XCTAssertNil(observation.completed(before: "example.com/api/verylong ", documentID: id))
        XCTAssertEqual(observation.completed(before: "adres dev@example.com ", documentID: id)?.token, "dev@example.com")
    }
    func testTurkishSingleLetterPronounIsLearned() {
        var history = PersonalHistory()
        history.observe(text: "o geldi")
        XCTAssertNotNil(history.tokens["o"])
        XCTAssertNotNil(history.pairs["o"]?["geldi"])
        history.observe(text: "x")
        XCTAssertNil(history.tokens["x"])
    }
    func testDeletedAndRetypedOccurrenceCountsAgain() {
        var observation = HistoryObservation()
        let id = UUID()
        XCTAssertNotNil(observation.completed(before: "merhaba ", documentID: id))
        observation.changed(before: "", documentID: id)
        observation.changed(before: "merhab", documentID: id)
        XCTAssertNotNil(observation.completed(before: "merhaba ", documentID: id))
        XCTAssertNil(observation.completed(before: "merhaba  ", documentID: id))
    }
    func testRepeatedSeparatorsAreNotNewOccurrences() {
        var observation = HistoryObservation()
        let id = UUID()
        XCTAssertEqual(observation.completed(before: "selam dünya ", documentID: id)?.token, "dünya")
        XCTAssertNil(observation.completed(before: "selam dünya  ", documentID: id))
        XCTAssertNil(observation.completed(before: "selam dünya\n", documentID: id))
        XCTAssertEqual(observation.completed(before: "selam dünya  dünya ", documentID: id)?.token, "dünya")
    }

    func testNewDocumentCountsAndNewlineDoesNotCreateCrossSentencePair() {
        var observation = HistoryObservation()
        XCTAssertNotNil(observation.completed(before: "selam ", documentID: UUID()))
        let second = UUID()
        XCTAssertNotNil(observation.completed(before: "selam ", documentID: second))
        let result = observation.completed(before: "selam\ndünya ", documentID: second)
        XCTAssertEqual(result?.token, "dünya")
        XCTAssertNil(result?.previous)
    }
}
