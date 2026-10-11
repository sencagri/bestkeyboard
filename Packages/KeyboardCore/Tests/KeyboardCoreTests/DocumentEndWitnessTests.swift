import XCTest
import Foundation
import KBRuntime

final class DocumentEndWitnessTests: XCTestCase {
    func testOwnedEndSurvivesTypingButUnknownContextsDoNotGainTrust() {
        let id = UUID()
        func snapshot(_ before: String?, _ after: String? = nil, _ selected: String? = nil, _ documentID: UUID? = nil) -> SuggestionContext {
            .init(documentID: documentID ?? id, before: before, selected: selected, after: after)
        }
        for emptyBefore: String? in [nil, ""] {
            var witness = DocumentEndWitness()
            var previous = snapshot(emptyBefore)
            XCTAssertTrue(witness.observe(previous, hasText: false))
            for text in ["2", "2001:", "2001:db8::", "2001:db8:: \n", "2001:db8:: \n2001:db8:"] {
                let next = snapshot(text)
                let known = witness.observe(previous, hasText: previous.before?.isEmpty == false)
                witness.didEdit(from: previous, to: next, wasAtEnd: known)
                XCTAssertTrue(witness.observe(next, hasText: true))
                XCTAssertTrue(witness.observe(next, hasText: true))
                previous = next
            }
            XCTAssertFalse(witness.observe(snapshot("2001:", "db8::"), hasText: true))
            XCTAssertFalse(witness.observe(previous, hasText: true))
        }
        for unknown in [snapshot("2001:"), snapshot(nil), snapshot("", nil, "word"), snapshot("2001:", "db8::")] {
            var witness = DocumentEndWitness()
            XCTAssertFalse(witness.observe(unknown, hasText: true))
            witness.didEdit(from: unknown, to: snapshot("2001:a"), wasAtEnd: false)
            XCTAssertFalse(witness.observe(snapshot("2001:a"), hasText: true))
        }
    }

    func testMovesSelectionsFieldChangesAndTruncationRevokeWitness() {
        let id = UUID(), original = SuggestionContext(documentID: UUID(), before: "address", selected: nil, after: "")
        for altered in [SuggestionContext(documentID: id, before: "address", selected: nil, after: nil),
                        SuggestionContext(documentID: original.documentID, before: "dress", selected: nil, after: nil),
                        SuggestionContext(documentID: original.documentID, before: "address", selected: "x", after: nil),
                        SuggestionContext(documentID: original.documentID, before: "address", selected: nil, after: "tail")] {
            var witness = DocumentEndWitness()
            XCTAssertTrue(witness.observe(original, hasText: true))
            XCTAssertFalse(witness.observe(altered, hasText: true))
        }
        var witness = DocumentEndWitness()
        XCTAssertTrue(witness.observe(original, hasText: true))
        witness.invalidate()
        XCTAssertFalse(witness.observe(.init(documentID: original.documentID, before: "address", selected: nil, after: nil), hasText: true))
    }
}
