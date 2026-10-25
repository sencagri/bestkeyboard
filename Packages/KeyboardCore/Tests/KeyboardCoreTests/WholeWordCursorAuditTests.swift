import XCTest
import Foundation
import KBFoundation
import KBGeometry
import KBLearning
@testable import KBRuntime

final class WholeWordCursorAuditTests: XCTestCase {
    private final class CursorDocument: DocumentEditor {
        var before: String
        var after: String
        init(before: String, after: String) { self.before = before; self.after = after }
        var contextBeforeInput: String? { before }
        var contextAfterInput: String? { after }
        var selectedText: String? { nil }
        var text: String { before + after }
        func insertText(_ text: String) { before += text }
        func deleteBackward() { if !before.isEmpty { before.removeLast() } }
    }

    func testWholeWordCursorAndStaleContextAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_WHOLE_WORD_CURSOR_AUDIT"] else {
            throw XCTSkip("Opt-in whole-word cursor/context audit")
        }
        let layout = TurkishQ.layout(), pack = RecordingTestSupport.loaded
        var rows: [[String: String]] = []
        for (root, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            for opening in ["", "(", "\"", "«"] {
                for right in ["", " sonra", ") sonra", "\" sonra", "\nsonra"] {
                    for original in [true, false] {
                        for casing in 0..<3 {
                            var c = InputCoordinator(layout: layout)
                            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                            c.ingestPersonal(tokens: [root, root, root])
                            let raw = form + "baç"
                            let source = casing == 2 ? TurkishText.uppercased(raw) : casing == 1 ? TurkishText.uppercased(String(raw.prefix(1))) + raw.dropFirst() : raw
                            let pair = TurkishText.applying(TurkishText.casing(of: source), to: form + " aç")
                            let target = original ? source : pair
                            let left = "önce 👩🏽‍💻 " + opening
                            let doc = CursorDocument(before: left + source, after: right)
                            let offer = try XCTUnwrap(c.wholeWordSuggestion(before: doc.before, after: doc.after, selected: nil))
                            let offered = offer.surfaces.first == source && offer.surfaces.contains(pair)
                            let staleRejected = !offer.matches(before: nil, after: right, selected: nil)
                                && !offer.matches(before: doc.before, after: nil, selected: nil)
                                && !offer.matches(before: "x" + doc.before, after: right, selected: nil)
                                && !offer.matches(before: doc.before, after: right + "x", selected: nil)
                                && !offer.matches(before: doc.before, after: right, selected: source)
                            // Same document text can still have an obsolete candidate:
                            // forgetting the root must revoke its inflected split.
                            c.forgetPersonal(root)
                            let revoked = c.wholeWordSuggestion(before: doc.before, after: right, selected: nil)?.surfaces.contains(pair) == false
                            c.ingestPersonal(tokens: [root, root, root])
                            let restored = c.wholeWordSuggestion(before: doc.before, after: right, selected: nil)?.surfaces.contains(pair) == true
                            let replacement = try XCTUnwrap(offer.replacement(for: target))
                            XCTAssertTrue(offer.matches(before: doc.before, after: right, selected: nil))
                            c.invalidateComposing()
                            for _ in source { _ = c.backspaceTap(into: doc) }
                            c.insertText(replacement, into: doc)
                            if original { c.confirmWholeWord(source) }
                            let expectedBefore = left + target + (right.isEmpty ? " " : "")
                            let replacedExactly = doc.text == expectedBefore + right
                            let rightPreserved = doc.after == right && doc.before == expectedBefore
                            // Continue typing at the actual caret and undo it; this
                            // detects moving the caret to the end of the right suffix.
                            let key = try XCTUnwrap(layout.keyIndex(for: "x"))
                            c.insertLetter("x", touch: .init(down: layout.keys[key].center), into: doc)
                            let continuedExactly = doc.text == expectedBefore + "x" + right
                            _ = c.backspaceTap(into: doc)
                            let undoExact = doc.text == expectedBefore + right
                            let expectedWords = [root]
                            let learningExact = Set(c.personal.admitted) == Set(expectedWords)
                            let checks = ["offered": offered, "stale_rejected": staleRejected,
                                "forgotten_revoked": revoked, "relearn_restored": restored,
                                "replacement_exact": replacedExactly, "right_preserved": rightPreserved,
                                "continuation_exact": continuedExactly, "undo_exact": undoExact,
                                "learning_exact": learningExact]
                            for (name, passed) in checks { XCTAssertTrue(passed, "\(root) \(opening) \(right) \(original) \(casing): \(name)") }
                            var row = checks.mapValues(String.init)
                            row["root"] = root; row["opening"] = opening; row["right"] = right
                            row["original"] = String(original); row["casing"] = String(casing)
                            rows.append(row)
                        }
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
