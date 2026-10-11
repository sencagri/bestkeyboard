import XCTest
import Foundation
import KBLearning

/// Opt-in diagnostic. Randomized dictionary traversal is observed, never asserted.
final class HistoryMergeOrderAuditTests: XCTestCase {
    func testImportOrdering() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_HISTORY_MERGE_ORDER_AUDIT"] else {
            throw XCTSkip("Set KB_HISTORY_MERGE_ORDER_AUDIT")
        }
        var source = PersonalHistory()
        for word in ["sabah", "öğle", "akşam", "gece"] { source.observe(text: "yarın " + word) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceData = try encoder.encode(source)
        let expected = source.nextWords(after: "yarın", limit: 4)
        var rows: [[String: String]] = []
        for attempt in 0..<30 {
            let decoded = try JSONDecoder().decode(PersonalHistory.self, from: sourceData)
            var merged = PersonalHistory(); merged.merge(decoded)
            rows.append(["scenario": "next_word_order", "attempt": String(attempt),
                         "source": expected.joined(separator: " | "),
                         "decoded": decoded.nextWords(after: "yarın", limit: 4).joined(separator: " | "),
                         "merged": merged.nextWords(after: "yarın", limit: 4).joined(separator: " | "),
                         "counts_preserved": String(merged.pairs["yarın"]?.values.allSatisfy { $0.count == 1 } == true)])
        }
        var large = PersonalHistory()
        for i in 0..<PersonalHistory.tokenCapacity {
            large.observe(token: String(format: "audit%04d@local.test", i), previous: nil)
        }
        let largeData = try encoder.encode(large)
        for attempt in 0..<10 {
            let decoded = try JSONDecoder().decode(PersonalHistory.self, from: largeData)
            var merged = PersonalHistory()
            merged.observe(token: "older@local.test", previous: nil)
            merged.observe(token: "older@local.test", previous: nil)
            merged.merge(decoded)
            let missing = Set(decoded.tokens.keys).subtracting(merged.tokens.keys).sorted()
            rows.append(["scenario": "capacity_eviction", "attempt": String(attempt),
                         "expected_oldest_import": "audit0000@local.test", "removed": missing.joined(separator: " | "),
                         "source_latest_recall": decoded.recall(prefix: "audit").joined(separator: " | "),
                         "merged_latest_recall": merged.recall(prefix: "audit").joined(separator: " | "),
                         "count": String(merged.tokens.count),
                         "frequent_old_token_preserved": String(merged.tokens["older@local.test"]?.count == 2)])
        }
        var repeated = PersonalHistory(); repeated.merge(source); repeated.merge(source)
        rows.append(["scenario": "repeat_merge_count_control", "before": "1",
                     "after": String(repeated.pairs["yarın"]?["gece"]?.count ?? 0)])
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        print("HISTORY MERGE ORDER AUDIT: \(rows.count) cases")
    }
}
