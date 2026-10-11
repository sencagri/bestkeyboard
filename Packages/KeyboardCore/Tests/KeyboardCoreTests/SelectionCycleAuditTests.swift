import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class SelectionCycleAuditTests: XCTestCase {
    func testRepeatedSelections() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SELECTION_CYCLE_AUDIT"] else { throw XCTSkip("Set KB_SELECTION_CYCLE_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["kalem", "Kalem", "İstanbul", "QRmenü"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "önce " + word {
                if ch == " " { c.space(into: doc, fieldProtectsLiteral: true); continue }
                let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR")).first!
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: lower))]
                if ch.isUppercase { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: .init(down: key.center), into: doc) }
                else { c.insertLetter(ch, touch: .init(down: key.center), into: doc) }
            }
            c.space(into: doc, fieldProtectsLiteral: true)
            for stage in ["first_selection", "duplicate_callback", "reselection_after_clear"] {
                if stage == "reselection_after_clear" {
                    doc.hostClearsSelection()
                    c.handleSelection(nil, into: doc)
                }
                doc.hostSelects(word)
                c.handleSelection(doc.selectedText, into: doc)
                rows.append(["word": word, "stage": stage, "editing": String(c.session.isEditingSelection),
                    "real_evidence": String(c.session.selectionHasRealEvidence),
                    "suggestions": c.suggestions().map(\.surface).joined(separator: " | "), "document": doc.text])
                XCTAssertEqual(doc.text, "önce " + word + " ")
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
