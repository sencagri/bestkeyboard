import XCTest
import Foundation
import KBLearning

final class InterruptedPhoneCursorAuditTests: XCTestCase {
    func testInterruptedPhoneCursorAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_INTERRUPTED_PHONE_AUDIT"]
        var rows: [[String: String]] = []
        for phone in ["+905321234567", "+90 532 123 45 67", "05321234567", "0532 123 45 67"] {
            var history = PersonalHistory(); history.observe(token: phone, previous: nil)
            for offset in [4, 6, 8] {
                for marker in ["_", "/", "@", "=", "#", "x"] {
                    let before = "ara " + phone.prefix(offset)
                    let after = marker + phone.dropFirst(offset) + " sonra"
                    let hit = history.completions(before: before, after: after, selected: nil).first { $0.surface == phone && $0.source == .observed }
                    XCTAssertNil(hit, before + after)
                    let applied = hit.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after } ?? before + after
                    rows.append(["phone": phone, "offset": String(offset), "marker": marker, "before": before, "after": after,
                                 "offered": String(hit != nil), "right_token": hit?.rightToken ?? "", "applied": applied])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }

    func testAttachedFragmentAfterValidDigitsAndSeparatedProse() {
        var history = PersonalHistory(); history.observe(token: "+905321234567", previous: nil)
        for right in ["32x1234567", "32_1234567", "32/1234567", "32ç1234567"] {
            XCTAssertTrue(history.completions(before: "+905", after: right, selected: nil).isEmpty, right)
        }
        for after in [" sonra", ", sonra", "; sonra", " sonra_123"] {
            let hit = history.completions(before: "+905", after: after, selected: nil).first
            XCTAssertEqual(hit?.surface, "+905321234567")
            XCTAssertEqual(hit?.rightToken, "")
        }
    }
}
