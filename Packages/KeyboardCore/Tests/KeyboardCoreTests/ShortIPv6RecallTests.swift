import XCTest
import Foundation
import KBLearning

final class ShortIPv6RecallTests: XCTestCase {
    func testShortIPv6SurvivesLearningReloadRecallAndForget() throws {
        for address in ["::", "::1", "::a", "A::", "1::"] {
            for prefix in ["", "önce ", "önce\n"] {
                for suffix in ["", ",", "!"] {
                    let text = prefix + address + suffix + " "
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for ch in text {
                        before.append(ch)
                        observation.changed(before: before, documentID: id)
                        if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, original) in [("bulk", bulk), ("live", live)] {
                        var history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(original))
                        let label = address + " " + mode + " " + prefix.debugDescription + suffix
                        XCTAssertEqual(history.tokens[address]?.count, 1, label)
                        if address.count > 2 {
                            let start = String(address.prefix(2))
                            XCTAssertTrue(history.completions(before: start, after: "", selected: nil).contains { $0.surface == address }, label)
                        }
                        history.forget(address)
                        XCTAssertNil(history.tokens[address], label)
                        XCTAssertFalse(history.recall(prefix: String(address.prefix(2)), limit: 10).contains(address), label)
                    }
                }
            }
        }
        for fragment in [":", "...", "--", "?!", "12", "a:"] {
            XCTAssertFalse(PersonalHistory.isRecallable(fragment), fragment)
        }
    }
}
