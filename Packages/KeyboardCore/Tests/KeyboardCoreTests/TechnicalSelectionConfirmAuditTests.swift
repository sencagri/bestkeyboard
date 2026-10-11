import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class TechnicalSelectionConfirmAuditTests: XCTestCase {
    func testTechnicalSelectionLiteralConfirmation() throws {
        let output = ProcessInfo.processInfo.environment["KB_TECH_SELECTION_CONFIRM_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let surfaces = ["tcp/ip", "HTTP/2", "192.0.2.1:8080", "[2001:db8::1]:443",
                        "https://örnek.com/Çağrı?q=1#Section", "https://example.com/a%20b",
                        "ÇağrıDeveloper@örnek.com", "\"Çağrı Şen\"@örnek.com", "dev@[IPv6:2001:db8::1]",
                        "+90 532 123 45 67", "(0532) 123-45-67", "/Users/çağrı/Project",
                        "myDeveloper_Value", "--dry-run", "dev@o\u{0308}rnek.com", "https://example.com/👨‍👩‍👧‍👦"]
        var rows: [[String: String]] = []
        for surface in surfaces {
            for padding in ["", " ", "\t", "\u{00a0}"] {
                for (before, after) in [("", ""), ("önce (", "), sonra"), ("🇹🇷 ", " 👩🏽‍💻")] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = TechnicalConfirmDocument()
                    let selected = padding + surface + padding
                    let original = before + selected + after
                    doc.insertText(original); doc.hostSelects(selected)
                    c.handleSelection(doc.selectedText, into: doc)
                    let literal = c.suggestions().first { $0.origin == .literal && $0.surface == surface }
                    if let literal {
                        try c.perform(.suggestionPick(id: literal.id, surface: literal.surface, origin: literal.origin), touch: nil, into: doc)
                    }
                    let exact = doc.text == original
                    let bytes = Array(doc.text.utf8) == Array(original.utf8)
                    let collapsed = doc.selectedText == nil && !c.session.isEditingSelection
                    let key = try XCTUnwrap(layout.keyIndex(for: "x"))
                    c.insertLetter("x", touch: .init(down: layout.keys[key].center), into: doc)
                    let continued = doc.text == before + selected + "x" + after
                    c.backspaceTap(into: doc)
                    XCTAssertNotNil(literal, surface)
                    XCTAssertTrue(exact && bytes, surface)
                    XCTAssertTrue(collapsed, surface)
                    XCTAssertTrue(continued, surface)
                    XCTAssertEqual(doc.text, original, surface)
                    XCTAssertTrue(c.personal.entries.isEmpty, surface)
                    rows.append(["surface": surface, "padding": padding, "before": before, "after": after,
                                 "literal_offered": String(literal != nil), "exact": String(exact), "bytes_exact": String(bytes),
                                 "selection_ended": String(collapsed), "continued_exact": String(continued),
                                 "deletion_exact": String(doc.text == original), "personal_empty": String(c.personal.entries.isEmpty)])
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try e.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
    func testOrdinaryPhrasesAndMalformedStructuredSelectionsStayExcluded() {
        for surface in ["merhaba dünya", "0532 12", "+90 532\n1234567", "dev name@example.com",
                        "\"dev\nname\"@example.com", "https://example.com/a b", "önce 0532 123 45 67"] {
            var session = ComposingSession()
            _ = session.beginEditingSelectionSynthetic(surface, touches: [])
            XCTAssertFalse(session.isEditingSelection, surface)
        }
    }

}

private final class TechnicalConfirmDocument: DocumentEditor {
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
