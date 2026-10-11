import XCTest
import Foundation
import KBLearning
import KBRuntime
import KBGeometry

/// Models app recall -> closeComposition -> deleteTrailing -> insertAtBoundary.
/// Core editing is production code; UIKit refresh/timing is not exercised.
final class TechnicalRecallCursorAuditTests: XCTestCase {
    func testRecallInsideExistingToken() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_TECH_CURSOR_AUDIT"] else { throw XCTSkip("Set KB_TECH_CURSOR_AUDIT") }
        var rows: [[String: String]] = []
        for (full, prefix) in [("192.168.1.10", "192.16"), ("dev@example.com", "dev@exa"),
                               ("https://example.com/api", "https://exam"), ("/usr/local/bin", "/usr/loc")] {
            for mode in ["end", "inside", "before_space"] {
                let tail = mode == "inside" ? String(full.dropFirst(prefix.count)) : mode == "before_space" ? " sonra" : ""
                let doc = CursorRecallDocument(before: "önce " + prefix, after: tail)
                var h = PersonalHistory(); h.observe(text: full)
                let raw = String((doc.contextBeforeInput ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).last ?? "")
                let trimmed = PersonalHistory.tokenize(raw).last ?? ""
                let hit = raw.hasSuffix(trimmed) ? h.recall(prefix: trimmed).first : nil
                var c = InputCoordinator(layout: TurkishQ.layout())
                if let hit {
                    c.invalidateComposing()
                    if doc.contextBeforeInput?.hasSuffix(trimmed) == true {
                        for _ in trimmed { c.backspaceTap(into: doc) }
                        c.insertText(hit, into: doc)
                    }
                }
                let expected = "önce " + full + (mode == "before_space" ? " sonra" : "")
                rows.append(["full": full, "prefix": prefix, "mode": mode, "right_context": tail,
                             "offered": hit ?? "", "output": doc.text, "expected": expected,
                             "matches_expected": String(doc.text == expected)])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
private final class CursorRecallDocument: DocumentEditor {
    var before: String
    let after: String
    init(before: String, after: String) { self.before = before; self.after = after }
    var text: String { before + after }
    var contextBeforeInput: String? { before }
    var contextAfterInput: String? { after }
    var selectedText: String? { nil }
    func insertText(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}
