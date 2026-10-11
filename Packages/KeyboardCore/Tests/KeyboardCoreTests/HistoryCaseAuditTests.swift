import XCTest
import Foundation
import KBLearning

final class HistoryCaseAuditTests: XCTestCase {
    func testCaseNormalization() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_HISTORY_CASE_AUDIT"] else { throw XCTSkip("Set KB_HISTORY_CASE_AUDIT") }
        var rows: [[String: String]] = []
        for (surface, prefix) in [("https://INFO.example/page", "https://info."),
                                  ("https://INFO.example/page", "https://INFO."),
                                  ("https://info.example/page", "https://INFO.")] {
            var h = PersonalHistory(); h.observe(token: surface, previous: nil)
            rows.append(["scenario": "host_case", "surface": surface, "prefix": prefix,
                         "recall": h.recall(prefix: prefix).joined(separator: " | ")])
        }
        var paths = PersonalHistory()
        paths.observe(token: "https://example.com/Page", previous: nil)
        paths.observe(token: "https://example.com/page", previous: nil)
        rows.append(["scenario": "path_collision", "stored_count": String(paths.tokens.count),
                     "surfaces": paths.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                     "uppercase_prefix_recall": paths.recall(prefix: "https://example.com/P").joined(separator: " | ")])
        for (previous, query) in [("IŞIK", "ışık"), ("İSTANBUL", "istanbul")] {
            var h = PersonalHistory(); h.observe(token: "geldi", previous: previous)
            rows.append(["scenario": "turkish_word_control", "previous": previous, "query": query,
                         "next_words": h.nextWords(after: query).joined(separator: " | ")])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
