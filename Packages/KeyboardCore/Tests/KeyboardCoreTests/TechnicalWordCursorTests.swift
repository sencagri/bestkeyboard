import XCTest
import Foundation
import KBRuntime

final class TechnicalWordCursorTests: XCTestCase {
    func testTechnicalAndUnicodeWordStepsAgainstIndependentRanges() throws {
        let tokens = ["tcp/ip", "192.168.1.1:8080", "[2001:db8::1]:443", "dev+tag@example.com",
                      "https://example.com/Path?q=a%20b#c", "C:\\Users\\Dev\\file.swift", "~/src/main.swift",
                      "foo_bar::Baz<T>", "--dry-run", "v1.2.3-beta+42", "git@github.com:org/repo.git",
                      "\"First Last\"@example.com", "+90 (532) 123-45-67", "qrmenüden", "e\u{0301}cole", "👨‍👩‍👧🇹🇷😀"]
        let regex = try NSRegularExpression(pattern: "\\S+")
        var positions = 0, comparisons = 0
        for token in tokens {
            for separator in [" ", "\t", "\n", "\r\n", "\u{00a0}", "\u{0085}", "\u{2028}", "\u{2029}"] {
                for document in [token, "önce" + separator + token + separator + "sonra", separator + token + separator + separator] {
                    let length = document.utf16.count
                    let ranges = regex.matches(in: document, range: NSRange(location: 0, length: length)).map(\.range)
                    for index in Array(document.indices) + [document.endIndex] {
                        let before = String(document[..<index]), after = String(document[index...])
                        let cursor = before.utf16.count
                        positions += 1
                        for count in [-1, 0, 1, 2, 8, Int.max] {
                            let left = ranges.map(\.location).filter { $0 < cursor }.reversed()
                            let right = ranges.map(\.location).filter { $0 > cursor }
                            let back = count <= 0 ? cursor : (count <= left.count ? Array(left)[count - 1] : 0)
                            let next = count <= 0 ? cursor : (count <= right.count ? right[count - 1] : length)
                            let label = "\(document.debugDescription) utf16=\(cursor) count=\(count)"
                            XCTAssertEqual(WordBoundaries.toPreviousWordStart(before: before, count: count), back - cursor, label)
                            XCTAssertEqual(WordBoundaries.toNextWordStart(after: after, count: count), next - cursor, label)
                            comparisons += 2
                        }
                        let firstLeft = ranges.map(\.location).last(where: { $0 < cursor }) ?? 0
                        let firstRight = ranges.map(\.location).first(where: { $0 > cursor }) ?? length
                        XCTAssertEqual(WordBoundaries.toPreviousWordStart(before: before), firstLeft - cursor)
                        XCTAssertEqual(WordBoundaries.toNextWordStart(after: after), firstRight - cursor)
                        let word = ranges.first { $0.location <= cursor && cursor <= NSMaxRange($0) }
                        let bounds = WordBoundaries.currentWord(before: before, after: after)
                        XCTAssertEqual(bounds.start, word.map { $0.location - cursor } ?? 0)
                        XCTAssertEqual(bounds.end, word.map { NSMaxRange($0) - cursor } ?? 0)
                        comparisons += 4
                    }
                }
            }
        }
        XCTAssertGreaterThan(positions, 8_000)
        XCTAssertEqual(comparisons, positions * 16)
        print("TECHNICAL WORD CURSOR: \(positions) positions; \(comparisons) offset comparisons")
    }
}
