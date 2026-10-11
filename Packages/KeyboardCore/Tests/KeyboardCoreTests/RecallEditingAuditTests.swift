import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class RecallEditingAuditTests: XCTestCase {
    func testEditingAfterCompletion() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_RECALL_EDIT_AUDIT"] else { throw XCTSkip("Set KB_RECALL_EDIT_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for full in ["192.168.1.10", "dev@example.com", "https://example.com/api", "/usr/local/bin", "foo_bar", "qrmenü"] {
            for mode in ["delete_all", "space_backspace", "replace_tail"] {
                let doc = FakeDocument(); doc.hostRewrites(to: "önce ")
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                c.insertText(full, into: doc) // completion insertion path, not manually typed letters
                let expected: String
                switch mode {
                case "delete_all":
                    for _ in full { c.backspaceTap(into: doc) }
                    expected = "önce "
                case "space_backspace":
                    c.space(into: doc)
                    c.backspaceTap(into: doc)
                    expected = "önce " + full
                default:
                    c.backspaceTap(into: doc)
                    let index = try XCTUnwrap(layout.keyIndex(for: "x"))
                    c.insertLetter("x", touch: .init(down: layout.keys[index].center), into: doc)
                    c.space(into: doc)
                    expected = "önce " + full.dropLast() + "x "
                }
                rows.append(["full": full, "mode": mode, "output": doc.text, "expected": expected,
                             "matches_expected": String(doc.text == expected), "literal": c.session.literal])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
