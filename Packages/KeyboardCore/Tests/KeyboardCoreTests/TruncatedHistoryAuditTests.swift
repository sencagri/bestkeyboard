import XCTest
import Foundation
import KBLearning

final class TruncatedHistoryAuditTests: XCTestCase {
    func testPartialHostContextLearning() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_TRUNCATED_HISTORY_AUDIT"] else { throw XCTSkip("Set KB_TRUNCATED_HISTORY_AUDIT") }
        let cases = ["https://example.com/" + String(repeating: "segment/", count: 9) + "file.json",
                     String(repeating: "user", count: 16) + "@example.com",
                     String(repeating: "namespace_", count: 8) + "value_id"]
        var rows: [[String: String]] = []
        for full in cases {
            for window in [0, 32, 48] {
                let all = full + " "
                let visible = window == 0 ? all : String(all.suffix(window))
                // Mirrors TypingHistory.observe's completed-token extraction.
                let tokens = PersonalHistory.tokenize(visible)
                var h = PersonalHistory()
                if let last = tokens.last {
                    h.observe(token: last, previous: tokens.count >= 2 ? tokens[tokens.count - 2] : nil)
                }
                let partial = tokens.last ?? ""
                rows.append(["full": full, "window": String(window), "visible": visible,
                             "stored": h.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                             "full_length": String(full.count),
                             "recall": h.recall(prefix: String(partial.prefix(4))).joined(separator: " | ")])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
