import XCTest
import Foundation
import KBLearning

final class InterruptedLiteralEmailCursorAuditTests: XCTestCase {
    func testInterruptedLiteralEmailCursorAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_INTERRUPTED_LITERAL_AUDIT"]
        var rows: [[String: String]] = []
        for local in ["\"First Last\"", "\"Çağrı Şen\""] {
            for domain in ["[192.0.2.1]", "[IPv6:2001:db8::1]"] {
                let address = local + "@" + domain
                var history = PersonalHistory(); history.observe(token: address, previous: nil)
                for offset in [1, 2, 6] {
                    for marker in ["_", "/", "@", "=", "#", "\\"] {
                        let before = "önce " + local + "@" + domain.prefix(offset)
                        let right = marker + domain.dropFirst(offset)
                        let after = right + " sonra"
                        let offers = history.completions(before: before, after: after, selected: nil)
                        let hit = offers.first { $0.surface == address && $0.source == .observed }
                        XCTAssertNil(hit, before + after)
                        let applied = hit.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after } ?? before + after
                        rows.append(["address": address, "offset": String(offset), "marker": marker,
                                     "before": before, "after": after, "offered": String(hit != nil),
                                     "right_token": hit?.rightToken ?? "", "applied": applied])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
