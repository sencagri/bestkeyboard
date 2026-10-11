import XCTest
import Foundation
import KBLearning

final class WrapperDepthSafetyTests: XCTestCase {
    func testDeepWrappersNeverBecomeAddressData() throws {
        var rows: [[String: String]] = []
        for depth in 1...12 {
            for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("«", "»")] {
                for internalDepth in [0, 1, 8, 12] {
                    let value = "https://example.com/f" + String(repeating: "(", count: internalDepth) + "x" + String(repeating: ")", count: internalDepth)
                    var history = PersonalHistory(); history.observe(token: value, previous: nil)
                    for leading in ["", "önce "] {
                        let prefix = "https://example.com/f"
                        let before = leading + String(repeating: open, count: depth) + prefix
                        let after = String(repeating: close, count: depth)
                        let offers = history.completions(before: before, after: after, selected: nil)
                        let offer = offers.first { $0.surface == value }
                        let expected = leading + String(repeating: open, count: depth) + value + after
                        let result = offer.map { String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor + after }
                        let label = "depth=\(depth) pair=\(open)\(close) internal=\(internalDepth) leading=\(leading)"
                        if depth <= 8 { XCTAssertNotNil(offer, label) }
                        if let result { XCTAssertEqual(result, expected, label) }
                        rows.append(["case": label, "offered": String(offer != nil), "result": result ?? "", "expected": expected, "correct": String(result == nil || result == expected)])
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["KB_WRAPPER_DEPTH_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(rows.count, 384)
    }
}
