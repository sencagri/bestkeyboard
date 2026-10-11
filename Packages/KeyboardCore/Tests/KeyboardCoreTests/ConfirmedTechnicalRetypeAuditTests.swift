import XCTest
import Foundation
import KBLearning

final class ConfirmedTechnicalRetypeAuditTests: XCTestCase {
    func testConfirmedTechnicalValuesCanBeLearnedAgainAfterDeletion() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_CONFIRMED_TECH_RETYPE_AUDIT"] else { throw XCTSkip("Opt-in confirmed technical retype") }
        var rows: [[String: String]] = []
        for value in ["0532 123 45 67", "+90 532 123 45 67", "\"Çağrı Şen\"@örnek.com", "\"First Last\"@[IPv6:2001:db8::1]",
                      "dev@example.com", "https://örnek.com/çağrı", "192.0.2.1", "tcp/ip"] {
            for leading in ["", "önce "] {
                for after in ["", " sonra "] {
                    let id = UUID()
                    var observation = HistoryObservation(), history = PersonalHistory(), before = ""
                    observation.changed(before: before, documentID: id, after: after)
                    func type(_ text: String) {
                        for ch in text {
                            before.append(ch)
                            observation.changed(before: before, documentID: id, after: after)
                            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        }
                    }
                    type(leading + value + " ")
                    var expected = history
                    for cycle in 1...3 {
                        observation.changed(before: leading, documentID: id, after: after, selected: value + " ")
                        if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        let confirmationCounts = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                        for _ in value + " " {
                            observation.expectBackwardDeletion(before: before, after: after, documentID: id)
                            before.removeLast()
                            observation.changed(before: before, documentID: id, after: after)
                        }
                        let prefixExact = before == leading
                        type(value + " ")
                        expected.observe(token: value, previous: PersonalHistory.tokenize(leading).last)
                        let counts = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                        let pairs = history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                        let snapshot = history
                        for _ in 0..<3 {
                            if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        }
                        rows.append(["value": value, "leading": leading, "after": after, "cycle": String(cycle),
                                     "confirmation_counts": String(confirmationCounts), "prefix_exact": String(prefixExact),
                                     "counts_exact": String(counts), "pairs_exact": String(pairs),
                                     "repeat_unchanged": String(history == snapshot), "text_exact": String(before == leading + value + " ")])
                    }
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
