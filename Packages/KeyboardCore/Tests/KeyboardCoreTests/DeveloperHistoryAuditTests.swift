import XCTest
import Foundation
import KBLearning

final class DeveloperHistoryAuditTests: XCTestCase {
    func testDeveloperSurfaces() throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["KB_DEVELOPER_HISTORY_AUDIT"], let corpus = env["KB_SUFFIX_CORPUS"] else {
            throw XCTSkip("Set KB_DEVELOPER_HISTORY_AUDIT and KB_SUFFIX_CORPUS")
        }
        struct Item: Decodable { let input: String; let group: String }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: corpus)))
        var rows: [[String: String]] = []
        for item in items where !item.input.contains(" ") {
            var history = PersonalHistory()
            history.observe(text: item.input)
            let stored = history.tokens.values.map(\.surface).sorted()
            let prefix = String(item.input.prefix(max(2, item.input.count / 2)))
            rows.append(["input": item.input, "group": item.group,
                         "stored": stored.joined(separator: " | "),
                         "exact_preserved": String(stored.contains(item.input)),
                         "prefix": prefix, "recall": history.recall(prefix: prefix).joined(separator: " | ")])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
