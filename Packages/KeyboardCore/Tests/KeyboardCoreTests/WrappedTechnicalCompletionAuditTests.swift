import XCTest
import Foundation
import KBLearning

final class WrappedTechnicalCompletionAuditTests: XCTestCase {
    func testPairedWrapperCompletionCoverageAndTextPreservation() throws {
        let output = ProcessInfo.processInfo.environment["KB_WRAPPED_COMPLETION_AUDIT"]
        let samples = [("https://example.com/Page", "https://example.com/Pa"),
                       ("https://example.com/f(x)", "https://example.com/f("),
                       ("Dev@example.com", "Dev@exa"),
                       ("\"First Last\"@example.com", "\"First Last\"@exa")]
        let wrappers = [("", ""), ("(", ")"), ("\"", "\""), ("'", "'"), ("“", "”"),
                        ("«", "»"), ("[", "]"), ("{", "}"), ("`", "`")]
        var rows: [[String: String]] = []
        for (value, prefix) in samples {
            var history = PersonalHistory(); history.observe(token: value, previous: nil)
            for (open, close) in wrappers {
                for middle in [false, true] {
                    let right = middle ? String(value.dropFirst(prefix.count + 1)) : ""
                    for leading in ["", "önce "] {
                        for tail in ["", " sonra "] {
                            let before = leading + open + prefix, after = right + close + tail
                            let offers = history.completions(before: before, after: after, selected: nil)
                            let offer = offers.first { $0.surface == value }
                            let expected = leading + open + value + close + tail
                            var result = ""
                            if let offer {
                                XCTAssertTrue(offer.matches(before: before, after: after, selected: nil))
                                XCTAssertTrue(before.hasSuffix(offer.prefix))
                                result = String(before.dropLast(offer.prefix.count)) + offer.replacementBeforeCursor + after
                                XCTAssertEqual(result, expected, "Any offered replacement must preserve both wrappers and right text")
                            }
                            XCTAssertNotNil(offer, "Eligible paired-wrapper and bare completions must be available")
                            rows.append(["value": value, "prefix": prefix, "open": open, "close": close,
                                "middle": String(middle), "leading": leading, "tail": tail,
                                "offered": String(offer != nil), "result": result, "expected": expected])
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 288)
        if let output {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        }
        print("WRAPPED COMPLETION AUDIT: \(rows.count) cases; \(rows.filter { $0["offered"] == "true" }.count) exact offers")
    }
}
