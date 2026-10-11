import XCTest
import Foundation
import KBLearning

final class UnicodeTechnicalRightTailTests: XCTestCase {
    func testStoredUnicodeAddressesCompleteAcrossRightTail() throws {
        let samples = [("https://example.com/path", "https://example.com"),
                       ("https://örnek.com/şube", "https://"),
                       ("https://example.com/ışık", "https://example.com"),
                       ("https://example.com/s\u{0327}ube", "https://example.com"),
                       ("https://example.com/👩🏽‍💻/belge", "https://example.com"),
                       ("dev@xörnek.com", "dev@"),
                       ("\"Çağrı Şen\"@xörnek.com", "\"Çağrı Şen\"@")]
        var rows: [[String: String]] = []
        for (value, prefix) in samples {
            var history = PersonalHistory(); history.observe(token: value, previous: nil)
            for (open, close) in [("", ""), ("(", ")"), ("\"", "\"")] {
                for leading in ["", "önce "] {
                    for tail in ["", " sonra "] {
                        let right = String(value.dropFirst(prefix.count + 1))
                        let before = leading + open + prefix, after = right + close + tail
                        let offer = history.completions(before: before, after: after, selected: nil).first { $0.surface == value }
                        let expected = leading + open + value + close + tail
                        let result = offer.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after }
                        let label = "\(value) wrapper=\(open)\(close) leading=\(leading) tail=\(tail)"
                        XCTAssertNotNil(offer, label)
                        if let offer {
                            XCTAssertEqual(result, expected, label)
                            XCTAssertEqual(offer.rightToken, right, label)
                            XCTAssertEqual(offer.cursorAdvanceCount, (right + close).count, label)
                            XCTAssertEqual(offer.cursorAdvanceUTF16Count, (right + close).utf16.count, label)
                        }
                        rows.append(["case": label, "offered": String(offer != nil), "correct": String(result == expected),
                                     "right_graphemes": String(right.count), "right_utf16": String(right.utf16.count)])
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 84)
        if let path = ProcessInfo.processInfo.environment["KB_UNICODE_TECHNICAL_TAIL_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
