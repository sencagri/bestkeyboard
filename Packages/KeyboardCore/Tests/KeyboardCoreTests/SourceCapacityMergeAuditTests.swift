import XCTest
import KBLearning

final class SourceCapacityMergeAuditTests: XCTestCase {
    func testAggregateCountsBeforeSourceCapacityPruning() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_SOURCE_CAPACITY_AUDIT"] else {
            throw XCTSkip("Set KB_SOURCE_CAPACITY_AUDIT")
        }
        let target = "https://example.com/target"
        var rows: [[String: String]] = []
        for distractorCount in [PersonalHistory.tokenCapacity - 1, PersonalHistory.tokenCapacity] {
            for interleaved in [false, true] {
                var targetHistory = PersonalHistory()
                for _ in 0..<2 { targetHistory.observe(token: target, previous: nil) }
                var distractors = PersonalHistory()
                for index in 0..<distractorCount {
                    for _ in 0..<3 {
                        distractors.observe(token: "https://example.com/item" + String(index), previous: nil)
                    }
                }
                var inbox = HistoryImportInbox(), archive = HistoryArchive()
                inbox.append(targetHistory, source: "Metin")
                inbox.append(interleaved ? distractors : targetHistory, source: "Telegram")
                inbox.append(interleaved ? targetHistory : distractors, source: "WhatsApp")
                try HistoryImportTransaction.consume(&archive, inbox: inbox,
                    writeArchive: { _ in }, writeInbox: { inbox = $0 })
                for mode in ["live", "reloaded", "after_unrelated_typing"] {
                    if mode == "reloaded" {
                        archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
                    } else if mode == "after_unrelated_typing" {
                        archive.observe(token: "merhaba", previous: nil)
                    }
                    let retainedSourceCount = archive.sourceHistories.values.reduce(0) {
                        $0 + ($1.tokens[target]?.count ?? 0)
                    }
                    XCTAssertEqual(retainedSourceCount, 4)
                    rows.append([
                        "distractors": String(distractorCount), "interleaved": String(interleaved), "mode": mode,
                        "source_target_count": String(retainedSourceCount),
                        "aggregate_target_count": String(archive.history.tokens[target]?.count ?? 0),
                        "aggregate_size": String(archive.history.tokens.count),
                        "target_offered": String(archive.history.completions(before: "https://example.com/tar", after: "", selected: nil).contains { $0.surface == target })
                    ])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
