import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class TechnicalSurroundingPhraseAuditTests: XCTestCase {
    func testSelectedRepairPreservesTechnicalSurroundings() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_TECHNICAL_PHRASE_AUDIT"] else { throw XCTSkip("Opt-in technical surroundings audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let contexts = [
            ("192.0.2.1 ", " tcp/ip"),
            ("https://örnek.com/çağrı ", " https://example.com/a%20b?q=1#x"),
            ("çağrı@örnek.com (", ") dev@example.com"),
            ("+90 532 123 45 67 “", "” 0532 123 45 67"),
            ("/Users/çağrı/proje: ", "; /var/log/app.log"),
            ("v1.2.3\n", "\nHTTP/2"),
            ("👨‍👩‍👧‍👦 🇹🇷 ", " 🏳️‍🌈 👩🏽‍💻"),
            ("cafe\u{0301} «", "» o\u{0308}rnek")
        ]
        var rows: [[String: String]] = []
        for (raw, phrase) in [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki"), ("subiç", "su iç"),
                              ("obzaman", "o zaman"), ("qrmenübaç", "qrmenü aç"), ("qrmenüdenbaç", "qrmenüden aç")] {
            for (before, after) in contexts {
                for padding in ["", " ", "\t"] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    var personal = PersonalLexicon(); personal.observe("qrmenü", confidence: .strong)
                    c.replacePersonalLexicon(personal)
                    let doc = TechnicalPhraseDocument()
                    let selected = padding + raw + padding
                    doc.insertText(before + selected + after); doc.hostSelects(selected)
                    c.handleSelection(doc.selectedText, into: doc)
                    let originalVisible = c.suggestions().contains { $0.surface == raw }
                    let pick = c.suggestions().first { $0.surface == phrase }
                    if let pick {
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    }
                    let expectedBefore = before + padding + phrase + padding
                    let exact = doc.text == expectedBefore + after
                    let tail = doc.contextAfterInput == after
                    let collapsed = doc.selectedText == nil
                    let key = try XCTUnwrap(layout.keyIndex(for: "x"))
                    c.insertLetter("x", touch: .init(down: layout.keys[key].center), into: doc)
                    let continued = doc.text == expectedBefore + "x" + after
                    c.backspaceTap(into: doc)
                    let deletion = doc.text == expectedBefore + after
                    rows.append(["input": raw, "before": before, "after": after, "padding": padding,
                                 "original_visible": String(originalVisible), "offered": String(pick != nil),
                                 "exact": String(exact), "tail_preserved": String(tail), "selection_ended": String(collapsed),
                                 "continuation_exact": String(continued), "deletion_exact": String(deletion)])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

private final class TechnicalPhraseDocument: DocumentEditor {
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
