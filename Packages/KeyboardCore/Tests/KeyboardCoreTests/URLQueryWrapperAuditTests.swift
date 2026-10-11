import XCTest
import Foundation
import KBLearning

final class URLQueryWrapperAuditTests: XCTestCase {
    func testQueryAndFragmentPunctuationRemainExact() throws {
        let suffixes = ["?q=(a)", "?q=a,b", "?q=a;b", "?q=a:b", "?q=a!", "?q=a?",
                        "?q=a.", "?q='a'", "?q=%28a%29", "?q=a&b=c", "#section(1)", "#a.b"]
        let wrappers = [("", ""), ("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""),
                        ("'", "'"), ("“", "”"), ("«", "»"), ("`", "`")]
        var rows: [[String: String]] = []
        for suffix in suffixes {
            let value = "https://example.com/path" + suffix
            var history = PersonalHistory(); history.observe(token: value, previous: nil)
            XCTAssertEqual(TechnicalTokenKind.classify(value), .url)
            for prefix in ["https://example.com/pa", String(value.dropLast(2))] {
                for (open, close) in wrappers {
                    for middle in [false, true] {
                        for leading in ["", "önce "] {
                            for tail in ["", " sonra "] {
                                let right = middle ? String(value.dropFirst(prefix.count + 1)) : ""
                                let punctuation = !close.isEmpty && !tail.isEmpty ? "," : ""
                                let before = leading + open + prefix, after = right + close + punctuation + tail
                                let offer = history.completions(before: before, after: after, selected: nil).first { $0.surface == value }
                                let expected = leading + open + value + close + punctuation + tail
                                let result = offer.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after }
                                let label = "\(value) prefix=\(prefix) wrapper=\(open)\(close) middle=\(middle) leading=\(leading) tail=\(tail)"
                                XCTAssertNotNil(offer, label)
                                if let offer {
                                    XCTAssertEqual(result, expected, label)
                                    XCTAssertEqual(offer.literalSurface, prefix + right, label)
                                    XCTAssertEqual(offer.cursorAdvanceCount, (right + close + punctuation).count, label)
                                    XCTAssertTrue(offer.matches(before: before, after: after, selected: nil), label)
                                }
                                rows.append(["case": label, "offered": String(offer != nil), "correct": String(result == expected), "result": result ?? "", "expected": expected])
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 1728)
        if let path = ProcessInfo.processInfo.environment["KB_URL_QUERY_WRAPPER_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
    }
}
