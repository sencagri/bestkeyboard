import XCTest
import Foundation
import KBLearning

final class EmailHistoryAuditTests: XCTestCase {
    func testEmailSemantics() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_EMAIL_HISTORY_AUDIT"] else { throw XCTSkip("Set KB_EMAIL_HISTORY_AUDIT") }
        var rows: [[String: String]] = []
        for (first, second, prefix) in [
            ("Smith@example.com", "smith@example.com", "Smith@"),
            ("dev@INFO.example", "dev@info.example", "dev@info"),
            ("dev@EXAMPLE.com", "dev@example.com", "dev@ex"),
            ("dev+one@example.com", "dev+two@example.com", "dev+o")
        ] {
            var h = PersonalHistory(); h.observe(text: first)
            let initialRecall = h.recall(prefix: prefix, limit: 10)
            h.observe(text: second)
            rows.append(["scenario": "pair", "first": first, "second": second,
                         "prefix": prefix, "initial_recall": initialRecall.joined(separator: " | "),
                         "stored": h.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                         "stored_count": String(h.tokens.count),
                         "recall": h.recall(prefix: prefix, limit: 10).joined(separator: " | ")])
        }
        for address in ["\"a b\"@example.com", "\"a..b\"@example.com", "\"a@b\"@example.com",
                        "dev+test@example.com", "a.b@example.com", "dev@[192.0.2.1]", "dev@[IPv6:2001:db8::1]"] {
            var h = PersonalHistory(); h.observe(text: address)
            rows.append(["scenario": "surface", "input": address,
                         "stored": h.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                         "exact_preserved": String(h.tokens.values.contains { $0.surface == address })])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
