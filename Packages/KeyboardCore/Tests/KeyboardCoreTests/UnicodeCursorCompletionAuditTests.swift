import XCTest
import Foundation
import KBLearning

final class UnicodeCursorCompletionAuditTests: XCTestCase {
    func testUnicodeCursorCompletionAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_UNICODE_CURSOR_AUDIT"]
        var rows: [[String: String]] = []
        for surface in ["çağrı@örnek.com", "\"Çağrı Şen\"@örnek.com", "\"First Last\"@mail.örnek.com",
                        "https://örnek.com/çağrı", "https://example.com/a%20b", "/Users/çağrı/proje",
                        "dev@o\u{0308}rnek.com", "https://örnek.com/👨‍👩‍👧‍👦"] {
            var history = PersonalHistory(); history.observe(token: surface, previous: nil)
            XCTAssertTrue(history.tokens.values.contains { $0.surface == surface }, surface)
            for position in 3..<surface.count {
                for omitted in [false, true] {
                    let prefix = String(surface.prefix(position))
                    let right = String(surface.dropFirst(position + (omitted ? 1 : 0)))
                    for prose in ["", " sonra", " çağrı", " 👨‍👩‍👧‍👦"] {
                        let before = "önce " + prefix, after = right + prose
                        let offers = history.completions(before: before, after: after, selected: nil)
                        let observed = offers.filter { $0.source == .observed && $0.surface == surface }
                        var exact = true, guards = true
                        for offer in observed {
                            let result = String(before.dropLast(offer.prefix.count)) + offer.replacementBeforeCursor + after
                            exact = exact && result == "önce " + surface + prose
                            guards = guards && offer.matches(before: before, after: after, selected: nil)
                                && !offer.matches(before: before + "x", after: after, selected: nil)
                                && !offer.matches(before: before, after: after + "x", selected: nil)
                                && !offer.matches(before: before, after: after, selected: "x")
                        }
                        XCTAssertTrue(exact, surface + " position " + String(position))
                        XCTAssertTrue(guards, surface)
                        XCTAssertFalse(!omitted && !observed.isEmpty, surface)
                        // Unicode tails are supported now. Every offered native
                        // cursor movement must use the exact retained UTF-16 span.
                        for offer in offers {
                            XCTAssertEqual(offer.cursorAdvanceUTF16Count,
                                (offer.rightToken + offer.closingWrapper).utf16.count, surface)
                        }
                        rows.append(["surface": surface, "position": String(position), "omitted": String(omitted),
                                     "prose": prose, "right_ascii": String(right.allSatisfy(\.isASCII)),
                                     "all_offers": String(offers.count), "target_offers": String(observed.count),
                                     "exact_reconstruction": String(exact), "snapshot_guards": String(guards),
                                     "redundant_complete_offer": String(!omitted && !observed.isEmpty)])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
