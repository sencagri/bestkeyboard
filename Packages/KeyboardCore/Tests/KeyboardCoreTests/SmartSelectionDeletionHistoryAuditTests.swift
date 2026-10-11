import XCTest
import Foundation
import KBLearning

final class SmartSelectionDeletionHistoryAuditTests: XCTestCase {
    func testSelectionWhitespaceDeletionDoesNotDuplicateHistory() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SMART_SELECTION_HISTORY_AUDIT"] else {
            throw XCTSkip("Opt-in selection whitespace history audit")
        }
        var rows: [[String: String]] = []
        for left in ["önce", "kalem", "merhaba"] {
            for selected in ["qrmenü", "kalem", "geliştiricilerden", "https://örnek.com/a", "dev@example.com", "192.0.2.1"] {
                for removal in ["leading_space", "trailing_space"] {
                    for seeded in [false, true] {
                        let id = UUID()
                        var observation = HistoryObservation(), history = PersonalHistory()
                        if seeded { history.observe(text: left + " " + selected + " sonra") }
                        var before = ""
                        observation.changed(before: before, documentID: id, after: "")
                        for ch in left + " " + selected + " sonra " {
                            before.append(ch)
                            observation.changed(before: before, documentID: id, after: "")
                            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: "") { history.observe(event) }
                        }
                        let baseline = history
                        observation.changed(before: left + " ", documentID: id, after: " sonra ", selected: selected)
                        before = left + (removal == "leading_space" ? "" : " ")
                        let after = removal == "leading_space" ? " sonra " : "sonra "
                        observation.changed(before: before, documentID: id, after: after)
                        for _ in 0..<3 {
                            if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        }
                        let unchanged = history == baseline
                        before += "x"
                        observation.changed(before: before, documentID: id, after: after)
                        before += " "
                        if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        var expected = baseline
                        expected.observe(token: removal == "leading_space" ? left + "x" : "x", previous: removal == "leading_space" ? nil : left)
                        let counts = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                        let pairs = history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                        let completed = history
                        for _ in 0..<5 {
                            if let event = observation.completed(before: before, documentID: id, after: after) { history.observe(event) }
                        }
                        let repeated = history == completed
                        let checks = ["deletion_no_learning": unchanged, "new_token_counts": counts,
                                      "new_token_pairs": pairs, "repeat_unchanged": repeated]
                        for (name, passed) in checks { XCTAssertTrue(passed, "\(left) \(selected) \(removal): \(name)") }
                        var row = checks.mapValues(String.init)
                        row["left"] = left; row["selected"] = selected; row["removal"] = removal; row["seeded"] = String(seeded)
                        rows.append(row)
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
