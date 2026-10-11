import XCTest
import Foundation
import KBLearning

final class PhoneDigitOmissionAuditTests: XCTestCase {
    func testPhoneDigitOmissionAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_PHONE_DIGIT_OMISSION_AUDIT"] else { throw XCTSkip("Opt-in phone digit omission audit") }
        var rows: [[String: String]] = []
        for phone in ["+905321234567", "+90 532 123 45 67", "+90 (532) 123 45 67", "05321234567",
                      "0532 123 45 67", "(0532)1234567", "+90-532-123-45-67", "+90\u{00a0}532\u{00a0}123\u{00a0}45\u{00a0}67"] {
            var history = PersonalHistory(); history.observe(token: phone, previous: nil)
            XCTAssertEqual(TechnicalTokenKind.classify(phone), .phone)
            for position in 3..<phone.count where Array(phone)[position].isNumber {
                for prose in ["", " sonra", ", sonra", ". sonra", "; çağrı", " 🙂", " /api", " x123"] {
                    let before = "ara " + phone.prefix(position)
                    let after = String(phone.dropFirst(position + 1)) + prose
                    let offers = history.completions(before: before, after: after, selected: nil)
                    let hit = offers.first { $0.surface == phone && $0.source == .observed }
                    let applied = hit.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after }
                    rows.append(["phone": phone, "position": String(position), "prose": prose,
                                 "offered": String(hit != nil), "right_token": hit?.rightToken ?? "",
                                 "exact": String(applied == nil || applied == "ara " + phone + prose),
                                 "snapshot_valid": String(hit?.matches(before: before, after: after, selected: nil) ?? true),
                                 "applied": applied ?? ""])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
