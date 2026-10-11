import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class ExpansionEditingAuditTests: XCTestCase {
    func testExpansionCasingAndDeletion() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_EXPANSION_EDIT_AUDIT"] else { throw XCTSkip("Set KB_EXPANSION_EDIT_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        XCTAssertNotNil(pack.expansions)
        var rows: [[String: String]] = []
        for trigger in ["slm", "mrb", "nbr", "kib", "bb", "sagol", "napıyon", "tmm"] {
            for form in [trigger, trigger.prefix(1).uppercased() + trigger.dropFirst(), trigger.uppercased(with: Locale(identifier: "tr_TR"))] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel, expansions: pack.expansions))
                let doc = FakeDocument()
                for ch in form {
                    let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR")).first!
                    let i = try XCTUnwrap(layout.keyIndex(for: lower))
                    if ch.isUppercase { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: .init(down: layout.keys[i].center), into: doc) }
                    else { c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc) }
                }
                let targets = pack.expansions?.expansions(of: trigger) ?? []
                let suggestions = c.suggestions()
                rows.append(["scenario": "casing", "input": form, "expected_expansions": targets.joined(separator: " | "),
                             "suggestions": suggestions.map(\.surface).joined(separator: " | "),
                             "expansion_visible": String(suggestions.contains { targets.contains($0.surface) })])
                if form == trigger, let selected = suggestions.first(where: { targets.contains($0.surface) }), selected.surface.contains(" ") {
                    try c.perform(.suggestionPick(id: selected.id, surface: selected.surface, origin: selected.origin), touch: nil, into: doc)
                    let committed = doc.text
                    c.backspaceTap(into: doc)
                    let reopened = doc.text
                    c.deleteWord(into: doc)
                    rows.append(["scenario": "reopen_delete_word", "input": trigger, "expanded": selected.surface,
                                 "committed": committed, "reopened": reopened, "after_delete_word": doc.text])
                    let controlDoc = FakeDocument()
                    var control = InputCoordinator(layout: layout)
                    control.insertText(selected.surface, into: controlDoc)
                    control.deleteWord(into: controlDoc)
                    rows.append(["scenario": "insert_text_delete_word_control", "input": selected.surface, "after_delete_word": controlDoc.text])
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("EXPANSION EDIT AUDIT: \(rows.count) observations")
    }
}
