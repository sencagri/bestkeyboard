import XCTest
import KBLearning

final class PhoneCompletionBoundaryAuditTests: XCTestCase {
    func testCompletedPhoneSeparatorsRemainOutsideCompletionRange() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_PHONE_BOUNDARY_AUDIT"] else {
            throw XCTSkip("Set KB_PHONE_BOUNDARY_AUDIT")
        }
        var rows: [[String: String]] = []
        for phone in ["+905321234567", "+90 (532) 123 45 67", "05321234567", "0532 123 45 67", "dev@example.com"] {
            var history = PersonalHistory()
            history.observe(token: phone, previous: nil)
            for ending in ["", " ", "  ", ".", ". ", ", ", "\n"] {
                let before = "ara " + phone + ending
                let offers = history.completions(before: before, after: "", selected: nil)
                let first = offers.first
                // Same verified-prefix replacement used by the controller;
                // no actual host text is touched by this diagnostic.
                let applied = first.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor } ?? before
                rows.append([
                    "stored": phone, "ending": ending, "before": before,
                    "offer_count": String(offers.count), "prefix_to_replace": first?.prefix ?? "",
                    "first_offer": first?.surface ?? "", "after_pick": applied,
                    "terminal_preserved": String(ending.isEmpty || applied.hasSuffix(ending)),
                    "offer_matches_snapshot": String(first?.matches(before: before, after: "", selected: nil) ?? false)
                ])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
