import XCTest
import KBLearning

final class QuotedEmailCompletionAuditTests: XCTestCase {
    func testEveryQuotedEmailPrefixAgainstWholeTokenRecall() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_QUOTED_COMPLETION_AUDIT"] else {
            throw XCTSkip("Set KB_QUOTED_COMPLETION_AUDIT")
        }
        var rows: [[String: String]] = []
        for address in ["dev@example.com", "\"First.Last\"@example.com", "\"First Last\"@example.com",
                        "\"a b\"@example.com", "\"first@last\"@example.com", "\"First@Last\"@example.com", "\"First Last@Work\"@example.com"] {
            var history = PersonalHistory()
            history.observe(text: address)
            XCTAssertTrue(history.tokens.values.contains { $0.surface == address })
            history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
            for count in 2..<address.count {
                let prefix = String(address.prefix(count))
                let before = "mail " + prefix
                let offered = history.completions(before: before, after: "", selected: nil)
                let outcomes = offered.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor }
                rows.append([
                    "address": address, "prefix": prefix,
                    "whole_token_recall": String(history.recall(prefix: prefix, limit: 3).contains(address)),
                    "completion_count": String(offered.count),
                    "can_reach_full_address": String(outcomes.contains("mail " + address)),
                    "offered_surfaces": offered.map(\.surface).joined(separator: " | "),
                    "after_picks": outcomes.joined(separator: " | ")
                ])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
