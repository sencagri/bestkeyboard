import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class MultiwordSelectionAuditTests: XCTestCase {
    func testLastWordSelection() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_MULTIWORD_SELECTION_AUDIT"] else { throw XCTSkip("Set KB_MULTIWORD_SELECTION_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for trigger in ["slm", "kib", "napcaz"] {
            let target = try XCTUnwrap(pack.expansions?.expansions(of: trigger).first)
            let last = String(try XCTUnwrap(target.split(separator: " ").last))
            for mode in ["expansion", "typed"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel, expansions: pack.expansions))
                let doc = FakeDocument()
                for ch in "önce " + (mode == "expansion" ? trigger : target) {
                    if ch == " " { c.space(into: doc); continue }
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: key.center), into: doc)
                }
                if mode == "expansion" {
                    let pick = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                    try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                } else { c.space(into: doc) }
                XCTAssertEqual(doc.text, "önce " + target + " ")
                doc.hostSelects(last)
                c.handleSelection(doc.selectedText, into: doc)
                var row = ["trigger": trigger, "mode": mode, "target": target, "selected": last,
                    "editing": String(c.session.isEditingSelection),
                    "real_evidence": String(c.session.selectionHasRealEvidence),
                    "literal": c.session.literal, "display": c.session.display,
                    "suggestions": c.suggestions().map(\.surface).joined(separator: " | ")]
                // Different-surface direct API control: not claiming kalem is a visible suggestion.
                c.pickSuggestion("kalem", into: doc)
                let expected = "önce " + String(target.dropLast(last.count)) + "kalem "
                row["after_pick"] = doc.text
                row["expected_after_pick"] = expected
                XCTAssertEqual(doc.text, expected)
                rows.append(row)
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
