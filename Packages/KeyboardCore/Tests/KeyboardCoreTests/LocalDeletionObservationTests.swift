import XCTest
import KBLearning

final class LocalDeletionObservationTests: XCTestCase {
    private let address = "dev@example.com"

    func testUnwitnessedPrefixDeletionStillRevokesKnownStart() {
        var observation = HistoryObservation(); let id = UUID()
        observation.changed(before: "", documentID: id)
        observation.changed(before: address + "x", documentID: id)
        observation.changed(before: address, documentID: id)
        XCTAssertNil(observation.completed(before: address + " ", documentID: id))
    }

    func testOnlyExactDeletionAndRightContextCanPreserveKnownStart() {
        for right in [Optional(""), Optional("changed"), nil] {
            var observation = HistoryObservation(); let id = UUID()
            observation.changed(before: "", documentID: id)
            observation.changed(before: address + "x", documentID: id)
            observation.expectBackwardDeletion(before: address + "x", after: "", documentID: id)
            observation.changed(before: address, documentID: id, after: right)
            let event = observation.completed(before: address + " ", documentID: id, after: right)
            XCTAssertEqual(event?.token, right == "" ? address : nil)
        }
    }

    func testBatchedDeletesAndUnchangedCallbacksConfirmOnlyExpectedFinalSnapshot() {
        var observation = HistoryObservation(); let id = UUID()
        let initial = address + "xy"
        observation.changed(before: "", documentID: id)
        observation.changed(before: initial, documentID: id)
        observation.expectBackwardDeletion(before: initial, after: "", documentID: id)
        observation.changed(before: initial, documentID: id, after: "")
        observation.expectBackwardDeletion(before: initial, after: "", documentID: id)
        observation.changed(before: address, documentID: id, after: "")
        XCTAssertEqual(observation.completed(before: address + " ", documentID: id, after: "")?.token, address)
    }

    func testStaleCancelledAndCrossDocumentWitnessesDoNotAuthorizeLearning() {
        for mode in ["cancel", "different_document", "wrong_result"] {
            var observation = HistoryObservation(); let id = UUID()
            observation.changed(before: "", documentID: id)
            let initial = address + (mode == "wrong_result" ? "xy" : "x")
            observation.changed(before: initial, documentID: id)
            observation.expectBackwardDeletion(before: initial, after: "", documentID: id)
            if mode == "cancel" { observation.cancelExpectedDeletion() }
            let nextID = mode == "different_document" ? UUID() : id
            // Cancel/document-change cases would otherwise exactly match.
            // Only the wrong-result case removes two characters for one command.
            observation.changed(before: address, documentID: nextID, after: "")
            XCTAssertNil(observation.completed(before: address + " ", documentID: nextID, after: ""), mode)
        }
    }

    func testObservedUnknownStartCannotBecomeKnownThroughADelete() {
        var observation = HistoryObservation(); let id = UUID()
        observation.changed(before: address + "x", documentID: id)
        observation.expectBackwardDeletion(before: address + "x", after: "", documentID: id)
        observation.changed(before: address, documentID: id, after: "")
        XCTAssertNil(observation.completed(before: address + " ", documentID: id, after: ""))
    }
}
