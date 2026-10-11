import XCTest
import Foundation
import KBRuntime

final class TechnicalCapitalizationAuditTests: XCTestCase {
    func testTechnicalPunctuationControls() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_TECH_CAP_AUDIT"] else { throw XCTSkip("Set KB_TECH_CAP_AUDIT") }
        var rows: [[String: String]] = []
        let technical = ["dev@", "dev@example.", "https:", "https://", "https://example.",
                         "index.", "foo.", "192.", "fe80:", "fe80::", "v1.", "3.",
                         "user_", "api/", "test-", "value!"]
        for context in technical {
            let actual = ShiftPolicy.shouldCapitalize(context: context, type: .sentences)
            XCTAssertFalse(actual, context)
            rows.append(["context": context, "group": "technical_no_space", "capitalize": String(actual)])
        }
        for context in ["Merhaba. ", "Tamam! ", "Nasılsın? ", "bitti\n"] {
            let actual = ShiftPolicy.shouldCapitalize(context: context, type: .sentences)
            XCTAssertTrue(actual, context)
            rows.append(["context": context, "group": "sentence_control", "capitalize": String(actual)])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
