import XCTest
import Foundation
import KBLearning

final class TechnicalComponentRecallAuditTests: XCTestCase {
    func testComponentReuseCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_COMPONENT_RECALL_AUDIT"] else { throw XCTSkip("Set KB_COMPONENT_RECALL_AUDIT") }
        var rows: [[String: String]] = []
        for (stored, same, different, desired) in [
            ("alice@example.com", "alice@exa", "bob@exa", "bob@example.com"),
            ("https://example.com/api", "https://exa", "example.c", "example.com"),
            ("https://example.com/api", "https://example.com/a", "http://example.com/a", "http://example.com/api"),
            ("10.0.0.1:8080", "10.0.0.1:80", "10.0.0.2:80", "10.0.0.2:8080")
        ] {
            var h = PersonalHistory(); h.observe(text: stored)
            for (kind, prefix) in [("exact_prefix_control", same), ("component_reuse_request", different)] {
                rows.append(["stored": stored, "kind": kind, "prefix": prefix,
                             "recall": h.recall(prefix: prefix, limit: 3).joined(separator: " | "),
                             "proposed_completion": kind == "exact_prefix_control" ? stored : desired])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
