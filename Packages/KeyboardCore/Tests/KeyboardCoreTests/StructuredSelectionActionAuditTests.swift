import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class StructuredSelectionActionAuditTests: XCTestCase {
    func testActionsOnStructuredSelection() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_STRUCTURED_ACTION_AUDIT"] else { throw XCTSkip("Opt-in selected actions audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for surface in ["kalem", "0532 123 45 67", "+90 532 123 45 67", "\"Çağrı Şen\"@örnek.com",
                        "\"First Last\"@[IPv6:2001:db8::1]", "çağrı@örnek.com"] {
            for padding in ["", " ", "\t", "\u{00a0}"] {
                for action in ["letter", "backspace", "delete_word", "period", "newline", "space_then_letter"] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = StructuredActionDocument()
                    let before = "🇹🇷 önce (", after = "), sonra 192.0.2.1"
                    let selected = padding + surface + padding
                    doc.insertText(before + selected + after); doc.hostSelects(selected)
                    c.handleSelection(doc.selectedText, into: doc)
                    let editing = c.session.isEditingSelection
                    var inserted = ""
                    switch action {
                    case "backspace": c.backspaceTap(into: doc)
                    case "delete_word": c.deleteWord(into: doc)
                    case "period": c.insertSymbol(".", into: doc); inserted = "."
                    case "newline": c.newline(into: doc); inserted = "\n"
                    default:
                        if action == "space_then_letter" { c.space(into: doc) }
                        let key = try XCTUnwrap(layout.keyIndex(for: "x"))
                        c.insertLetter("x", touch: .init(down: layout.keys[key].center), into: doc)
                        inserted = "x"
                    }
                    rows.append(["surface": surface, "padding": padding, "action": action,
                                 "editing": String(editing), "exact": String(doc.text == before + inserted + after),
                                 "selection_ended": String(doc.selectedText == nil && !c.session.isEditingSelection),
                                 "personal_empty": String(c.personal.entries.isEmpty),
                                 "calibration_empty": String(c.calibration.sampleCount == 0), "actual": doc.text])
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

private final class StructuredActionDocument: DocumentEditor {
    private(set) var text = ""
    private var caret = 0
    private var selection: Range<Int>?
    private func index(_ offset: Int) -> String.Index { text.index(text.startIndex, offsetBy: offset) }
    func insertText(_ value: String) {
        let range = selection ?? caret..<caret
        text.replaceSubrange(index(range.lowerBound)..<index(range.upperBound), with: value)
        caret = range.lowerBound + value.count
        selection = nil
    }
    func deleteBackward() {
        let range = selection ?? max(0, caret - 1)..<caret
        text.removeSubrange(index(range.lowerBound)..<index(range.upperBound))
        caret = range.lowerBound; selection = nil
    }
    func hostSelects(_ word: String) {
        guard let range = text.range(of: word) else { selection = nil; return }
        selection = text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
    }
    var selectedText: String? { selection.map { String(text[index($0.lowerBound)..<index($0.upperBound)]) } }
    var contextBeforeInput: String? { String(text.prefix(selection?.lowerBound ?? caret)) }
    var contextAfterInput: String? { String(text.dropFirst(selection?.upperBound ?? caret)) }
}
