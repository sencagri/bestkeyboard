import XCTest
import Foundation
import KBGeometry
import KBRuntime

final class UnicodeLineDeletionAuditTests: XCTestCase {
    func testRepeatedWordDeletionPreservesLineBarrier() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_UNICODE_LINE_DELETE_AUDIT"] else {
            throw XCTSkip("Opt-in Unicode line deletion audit")
        }
        var rows: [[String: String]] = []
        for newline in ["\n", "\r", "\r\n", "\u{0085}", "\u{000b}", "\u{000c}", "\u{2028}", "\u{2029}"] {
            XCTAssertTrue(newline.first!.isNewline)
            for padding in ["", " ", "\t", "\u{00a0}", "\u{2009}"] {
                for tail in ["çağrı", "qrmenüden", "https://örnek.com/a", "+90 532 123", "👩🏽‍💻"] {
                    for mode in ["host", "inserted"] {
                        var c = InputCoordinator(layout: TurkishQ.layout())
                        let doc = FakeDocument()
                        let barrier = "önce" + newline
                        doc.hostRewrites(to: barrier)
                        if mode == "host" { doc.hostRewrites(to: barrier + tail + padding) }
                        else { c.insertText(tail + padding, into: doc) }
                        var monotonic = true, preserved = true, steps = 0
                        while doc.text != barrier && steps < tail.count + padding.count + 1 {
                            let before = doc.text
                            c.deleteWord(into: doc)
                            monotonic = monotonic && doc.text.count < before.count && before.hasPrefix(doc.text)
                            preserved = preserved && doc.text.hasPrefix(barrier)
                            steps += 1
                        }
                        let reached = doc.text == barrier
                        c.deleteWord(into: doc)
                        let separatorOnly = doc.text == "önce"
                        c.deleteWord(into: doc)
                        let cleared = doc.text.isEmpty
                        c.deleteWord(into: doc)
                        let emptyStable = doc.text.isEmpty
                        let checks = ["progress": monotonic, "barrier_preserved": preserved,
                                      "barrier_reached": reached, "separator_only": separatorOnly,
                                      "cleared": cleared, "empty_stable": emptyStable]
                        for (name, passed) in checks { XCTAssertTrue(passed, "\(newline.debugDescription) \(tail) \(mode): \(name)") }
                        var row = checks.mapValues(String.init)
                        row["newline"] = newline; row["tail"] = tail; row["padding"] = padding; row["mode"] = mode; row["steps"] = String(steps)
                        rows.append(row)
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
