import XCTest
import Foundation
import KBLearning

final class HistoryURLPunctuationAuditTests: XCTestCase {
    func testURLTokenEdges() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_HISTORY_URL_EDGE_AUDIT"] else { throw XCTSkip("Set KB_HISTORY_URL_EDGE_AUDIT") }
        let urls = ["https://example.com/a(b)", "https://example.com/search?q=wow!",
                    "https://example.com/v1.", "https://example.com/a;b;",
                    "https://example.com/a(b)c", "https://example.com/v1/",
                    "https://example.com/a%29", "https://example.com/search?q=wow%21"]
        var rows: [[String: String]] = []
        for url in urls {
            for wrapper in ["none", "parentheses", "sentence_period"] {
                let text = wrapper == "parentheses" ? "(" + url + ")" : url + (wrapper == "sentence_period" ? "." : "")
                var history = PersonalHistory(); history.observe(text: text)
                let stored = history.tokens.values.map(\.surface).sorted()
                rows.append(["url": url, "wrapper": wrapper, "input": text,
                    "stored": stored.joined(separator: " | "), "exact_preserved": String(stored.contains(url)),
                    "recall": history.recall(prefix: "https://example.com/").joined(separator: " | ")])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
