import XCTest
import KBLearning

final class ObservationRollbackTests: XCTestCase {
    private func events(_ text: String) -> [HistoryObservation.Event] {
        var observer = HistoryObservation(), before = "", result: [HistoryObservation.Event] = []
        let id = UUID(); observer.changed(before: "", documentID: id)
        for ch in text {
            before.append(ch); observer.changed(before: before, documentID: id)
            if ch.isWhitespace, let event = observer.completed(before: before, documentID: id) { result.append(event) }
        }
        return result
    }

    func testRepeatedMailboxWordsRestoreExactPriorTokenAndPairMetadata() throws {
        var history = PersonalHistory(); history.observe(text: "mail first\nmail sonra")
        let token = history.tokens["first"], pair = history.pairs["mail"]?["first"]
        for event in events("mail \"First First Last\"@example.com ") { history.observe(event) }
        XCTAssertEqual(history.tokens["first"], token)
        XCTAssertEqual(history.pairs["mail"]?["first"], pair)
        XCTAssertNil(history.pairs["first"]?["first"])
        XCTAssertEqual(history.nextWords(after: "mail"), ["sonra", "first"])
        let reloaded = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(reloaded, history, "Transient rollback receipts are not learned/persisted history")
    }

    func testGroupedPhoneRestoresOldDisplayAndRecency() throws {
        var history = PersonalHistory()
        history.observe(text: "+90532123\n+90 532 999")
        let old = history.tokens["+90532123"]
        for event in events("+90 532 123 45 67 ") { history.observe(event) }
        XCTAssertEqual(history.tokens["+90532123"], old)
        XCTAssertEqual(history.completions(before: "+90 532", after: "", selected: nil).prefix(2).map(\.surface),
                       ["+90 532 123 45 67", "+90 532 999"])
    }

    func testInterveningLegitimateObservationKeepsNewerMetadata() {
        var history = PersonalHistory(); history.observe(text: "mail first")
        var legitimate: PersonalHistory.Stat?
        for event in events("mail \"First Last\"@example.com ") {
            history.observe(event)
            if event.token == "First" {
                history.observe(token: "FİRST", previous: "mail")
                legitimate = history.tokens["first"]
            }
        }
        XCTAssertEqual(history.tokens["first"]?.count, 2)
        XCTAssertEqual(history.tokens["first"]?.surface, "FİRST")
        XCTAssertEqual(history.tokens["first"]?.seq, legitimate?.seq)
        XCTAssertEqual(history.pairs["mail"]?["first"]?.count, 2)
        XCTAssertEqual(history.pairs["mail"]?["first"]?.surface, "FİRST")
    }

    func testForgetThenRelearnCannotBeUndoneByOldOccurrence() {
        var history = PersonalHistory(); history.observe(text: "mail first")
        for event in events("mail \"First Last\"@example.com ") {
            history.observe(event)
            if event.token == "First" {
                history.forget("first")
                history.observe(token: "first", previous: "mail")
            }
        }
        XCTAssertEqual(history.tokens["first"]?.count, 1)
        XCTAssertEqual(history.pairs["mail"]?["first"]?.count, 1)
    }

    func testEvictedThenRelearnedTokenSurvivesButProvisionalPairIsRemoved() {
        var history = PersonalHistory()
        for event in events("mail \"First Last\"@example.com ") {
            history.observe(event)
            if event.token == "First" {
                for i in 0..<PersonalHistory.tokenCapacity {
                    for _ in 0..<3 { history.observe(token: "https://example.com/\(i)", previous: nil) }
                }
                XCTAssertNil(history.tokens["first"])
                history.forget("https://example.com/0")
                for _ in 0..<4 { history.observe(token: "first", previous: nil) }
            }
        }
        XCTAssertEqual(history.tokens["first"]?.count, 4)
        XCTAssertNil(history.pairs["mail"]?["first"])
    }
}
