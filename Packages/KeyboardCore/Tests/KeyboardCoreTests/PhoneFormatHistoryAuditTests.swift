import XCTest
import Foundation
import KBLearning

final class PhoneFormatHistoryAuditTests: XCTestCase {
    func testGroupedPhoneRecall() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_PHONE_FORMAT_AUDIT"] else { throw XCTSkip("Set KB_PHONE_FORMAT_AUDIT") }
        let cases = ["+905321234567", "05321234567", "0532 123 45 67", "+90 532 123 45 67",
                     "+90 (532) 123 45 67", "0532-123-45-67", "0532.123.45.67", "(0532)1234567",
                     "0532\u{00a0}123\u{00a0}45\u{00a0}67", "+1 202 555 0123", "+12025550123",
                     "+44 20 7946 0123", "+442079460123"]
        var rows: [[String: String]] = []
        for input in cases {
            var h = PersonalHistory(); h.observe(text: input)
            let restored = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(h))
            let prefix = String(input.prefix(3))
            rows.append(["input": input, "tokens": PersonalHistory.tokenize(input).joined(separator: " | "),
                         "stored": restored.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                         "exact_stored": String(restored.tokens.values.contains { $0.surface == input }),
                         "prefix": prefix, "recall": restored.recall(prefix: prefix, limit: 10).joined(separator: " | "),
                         "next_after_first_group": restored.nextWords(after: PersonalHistory.tokenize(input).first ?? "").joined(separator: " | ")])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
