import XCTest
import Foundation
import KBLearning

final class RecallChoiceAuditTests: XCTestCase {
    func testSharedPrefixChoices() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_RECALL_CHOICE_AUDIT"] else { throw XCTSkip("Set KB_RECALL_CHOICE_AUDIT") }
        var rows: [[String: String]] = []
        for (old, recent, third, common, specific) in [
            ("dev@old.example", "dev@new.example", "dev@third.example", "dev@", "dev@n"),
            ("192.168.1.10", "192.168.1.20", "192.168.1.30", "192.168.1", "192.168.1.2"),
            ("https://example.com/old", "https://example.com/new", "https://example.com/third", "https://example.com/", "https://example.com/n")
        ] {
            var h = PersonalHistory()
            for _ in 0..<20 { h.observe(text: old) }
            h.observe(text: third)
            h.observe(text: recent)
            for (stage, prefix) in [("common", common), ("specific_control", specific)] {
                rows.append(["stage": stage, "prefix": prefix,
                             "visible_default": h.recall(prefix: prefix).joined(separator: " | "),
                             "available_three": h.recall(prefix: prefix, limit: 3).joined(separator: " | "),
                             "desired": recent])
            }
            for _ in 0..<18 { h.observe(text: recent) }
            rows.append(["stage": "recent_used_19_times", "prefix": common,
                         "visible_default": h.recall(prefix: common).joined(separator: " | "), "desired": recent])
            h.observe(text: recent)
            rows.append(["stage": "equal_frequency_20", "prefix": common,
                         "visible_default": h.recall(prefix: common).joined(separator: " | "), "desired": recent])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
