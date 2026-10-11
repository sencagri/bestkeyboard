import XCTest
import KBRuntime

final class UnicodeTrackpadLineTests: XCTestCase {
    private let separators = ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}", "\u{000b}", "\u{000c}"]

    func testEveryLogicalLinePositionUsesTheCorrectUTF16Offset() {
        let samples = [["abcd", "wxyz", "mnop"], ["a😀b", "👨‍👩‍👧", "e\u{0301}xyz"],
                       ["", "xy", ""], ["abcdef", "x", "uvwxyz"]]
        var cases = 0
        for separator in separators {
            for lines in samples {
                let document = lines.joined(separator: separator)
                for row in lines.indices {
                    for column in 0...lines[row].count {
                        let before = lines.prefix(row).map { $0 + separator }.joined() + lines[row].prefix(column)
                        for direction in [-1, 1] {
                            var trackpad = CursorTrackpad(before: before, after: String(document.dropFirst(before.count)))
                            XCTAssertEqual(trackpad.update(dx: 0, dy: 0, time: 0), 0)
                            let targetRow = row + direction
                            let expected: String
                            if targetRow < 0 { expected = "" }
                            else if targetRow >= lines.count { expected = document }
                            else {
                                expected = lines.prefix(targetRow).map { $0 + separator }.joined()
                                    + lines[targetRow].prefix(min(column, lines[targetRow].count))
                            }
                            let delta = trackpad.update(dx: 0, dy: Double(direction) * 31, time: 1)
                            let label = "separator=\(separator.debugDescription) row=\(row) column=\(column) direction=\(direction)"
                            XCTAssertEqual(delta, expected.utf16.count - before.utf16.count, label)
                            XCTAssertEqual(trackpad.position, expected.count, label)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 752)
        print("UNICODE TRACKPAD LINES: \(cases) moves")
    }

    func testPreferredColumnSurvivesShortIntermediateLines() {
        for separator in separators {
            let document = ["abcdef", "x", "uvwxyz"].joined(separator: separator)
            let before = "abcdef" + separator + "x" + separator + "uvwx"
            var trackpad = CursorTrackpad(before: before, after: "yz")
            _ = trackpad.update(dx: 0, dy: 0, time: 0)
            var offset = before.utf16.count
            for (step, move) in [(-30.0, "abcdef" + separator + "x"), (-60.0, "abcd"),
                                   (-30.0, "abcdef" + separator + "x"), (0.0, before)].enumerated() {
                let (dy, expected) = move
                offset += trackpad.update(dx: 0, dy: dy, time: Double(step + 1))
                XCTAssertEqual(offset, expected.utf16.count, separator.debugDescription)
                XCTAssertEqual(String(document.prefix(trackpad.position)), expected)
            }
        }
    }
}
