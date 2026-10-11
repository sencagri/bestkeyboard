import XCTest
import KBLearning

final class StructuredMiddleCursorAuditTests: XCTestCase {
    func testEveryCursorPositionInAlreadyCompleteStructuredTokens() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_STRUCTURED_CURSOR_AUDIT"] else {
            throw XCTSkip("Set KB_STRUCTURED_CURSOR_AUDIT")
        }
        var rows: [[String: String]] = []
        for surface in ["+905321234567", "+90 532 123 45 67", "+90 (532) 123 45 67",
                        "0532 123 45 67", "dev@example.com", "https://example.com/api",
                        "/usr/local/bin", "\"First Last\"@example.com"] {
            var history = PersonalHistory()
            history.observe(token: surface, previous: nil)
            for position in 2..<surface.count {
                let before = "önce " + surface.prefix(position)
                let after = String(surface.dropFirst(position)) + " sonra"
                let offers = history.completions(before: before, after: after, selected: nil)
                for offer in offers {
                    let applied = String(before.dropLast(offer.prefix.count)) + offer.replacementBeforeCursor + after
                    rows.append([
                        "surface": surface, "position": String(position), "before": before, "after": after,
                        "prefix": offer.prefix, "right_token": offer.rightToken,
                        "offered": offer.surface, "after_pick": applied,
                        "changed_complete_document": String(applied != "önce " + surface + " sonra"),
                        "snapshot_matches": String(offer.matches(before: before, after: after, selected: nil))
                    ])
                }
                if offers.isEmpty {
                    rows.append(["surface": surface, "position": String(position), "no_offer": "true",
                                 "changed_complete_document": "false"])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
