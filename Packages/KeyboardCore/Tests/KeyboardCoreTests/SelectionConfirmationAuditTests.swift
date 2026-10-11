import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// End-of-document selections only: FakeDocument models their caret correctly.
final class SelectionConfirmationAuditTests: XCTestCase {
    func testSelectionConfirmation() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_SELECTION_CONFIRM_AUDIT"] else { throw XCTSkip("Set KB_SELECTION_CONFIRM_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["kitap", "qrmenü", "sokaktaydım"] {
            for mode in ["literal_pick", "literal_pick_reconcile", "different_surface_control", "space", "direct_typing_control"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                doc.hostRewrites(to: "önce " + word)
                doc.hostSelects(word)
                c.handleSelection(doc.selectedText, into: doc)
                XCTAssertTrue(c.session.isEditingSelection)
                let original = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
                var applied = ""
                if mode.hasPrefix("literal_pick") {
                    applied = original.surface
                    try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
                } else if mode == "different_surface_control" {
                    // Direct API control, not a claim that kalem is visible in this suggestion bar.
                    applied = "kalem"
                    c.pickSuggestion(applied, into: doc)
                } else if mode == "space" { c.space(into: doc) }
                let selectedAfter = doc.selectedText ?? "nil"
                let coreEditingAfter = String(c.session.isEditingSelection)
                let afterPick = doc.text
                if mode == "literal_pick_reconcile" { c.handleSelection(doc.selectedText, into: doc) }
                for ch in "lar" {
                    let i = try XCTUnwrap(layout.keyIndex(for: ch))
                    c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                }
                rows.append(["input": word, "mode": mode, "applied": applied,
                    "selected_after_action": selectedAfter, "core_editing_after_action": coreEditingAfter,
                    "document_after_action": afterPick, "document_after_typing": doc.text])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("SELECTION CONFIRM AUDIT: \(rows.count) sequences")
    }
}
