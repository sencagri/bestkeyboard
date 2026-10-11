import XCTest
import Foundation
import KBAssembly
import KBGeometry
@testable import KBRuntime

final class ChangingContextCompositionAuditTests: XCTestCase {
    func testContextDisappearsDuringComposition() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_CHANGING_CONTEXT_AUDIT"] else {
            throw XCTSkip("Opt-in changing context composition audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        func type(_ text: String, _ c: inout InputCoordinator, _ doc: ChangingContextDocument) throws {
            for ch in text {
                let index = try XCTUnwrap(layout.keyIndex(for: ch))
                c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
            }
        }
        var rows: [[String: String]] = []
        for word in ["merhaba", "çağrı", "qrmenü", "geliştiricilerden", "tcp", "ip", "developer", "örnek"] {
            for (prefix, suffix) in [("önce ", " sonra"), ("https://", "/api"), ("dev@", ".com")] {
                for window in [-1, 0, 1, 4, 1000] {
                    for action in ["delete_one", "delete_word", "insert_delete"] {
                        let doc = ChangingContextDocument(before: prefix, after: suffix)
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        try type(word, &c, doc)
                        let initial = doc.text == prefix + word + suffix
                        doc.window = window
                        var expected: String
                        switch action {
                        case "delete_one":
                            c.backspaceTap(into: doc)
                            expected = prefix + String(word.dropLast()) + suffix
                        case "delete_word":
                            c.deleteWord(into: doc)
                            expected = prefix + suffix
                        default:
                            try type("x", &c, doc)
                            c.backspaceTap(into: doc)
                            expected = prefix + word + suffix
                        }
                        let limitedExact = doc.text == expected
                        // Restore full visibility without changing the actual document.
                        doc.window = 1000
                        try type("z", &c, doc)
                        c.backspaceTap(into: doc)
                        let resumedExact = doc.text == expected
                        let noLearning = c.personal.entries.isEmpty
                        let checks = ["initial_exact": initial, "limited_exact": limitedExact,
                                      "resumed_exact": resumedExact, "no_personal_learning": noLearning]
                        for (name, passed) in checks { XCTAssertTrue(passed, "\(word) \(prefix) window\(window) \(action): \(name)") }
                        var row = checks.mapValues(String.init)
                        row["word"] = word; row["prefix"] = prefix; row["window"] = String(window); row["action"] = action
                        rows.append(row)
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

private final class ChangingContextDocument: DocumentEditor {
    var before: String
    let after: String
    var window = 1000
    init(before: String, after: String) { self.before = before; self.after = after }
    var text: String { before + after }
    var contextBeforeInput: String? { window < 0 ? nil : String(before.suffix(window)) }
    var contextAfterInput: String? { window < 0 ? nil : String(after.prefix(window)) }
    var selectedText: String? { nil }
    func insertText(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}
