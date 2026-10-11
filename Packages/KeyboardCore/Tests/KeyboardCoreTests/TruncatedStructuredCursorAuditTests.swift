import XCTest
import Foundation
import KBAssembly
import KBGeometry
@testable import KBRuntime

final class TruncatedStructuredCursorAuditTests: XCTestCase {
    func testTruncatedStructuredCursorBoundary() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_TRUNCATED_STRUCTURED_CURSOR_AUDIT"] else {
            throw XCTSkip("Opt-in structured cursor deletion audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let surfaces = ["tcp/ip", "HTTP/2", "192.0.2.1:8080", "[2001:db8::1]:443",
                        "https://örnek.com/Çağrı?q=1#Section", "https://example.com/a%20b",
                        "ÇağrıDeveloper@örnek.com", "\"Çağrı Şen\"@örnek.com", "dev@[IPv6:2001:db8::1]",
                        "+90 532 123 45 67", "(0532) 123-45-67", "/Users/çağrı/Project",
                        "myDeveloper_Value", "--dry-run", "dev@o\u{0308}rnek.com", "https://example.com/👨‍👩‍👧‍👦"]
        let x = try XCTUnwrap(layout.keyIndex(for: "x"))
        var rows: [[String: String]] = []
        for surface in surfaces {
            for (prefix, suffix) in [("", ""), ("önce (", "), sonra"), ("🇹🇷 ", " 👩🏽‍💻")] {
                for offset in 1...surface.count {
                    for beforeWindow in [-1, 0, 1, 8] {
                    for afterWindow in [-1, 0, 4] {
                    let left = prefix + String(surface.prefix(offset))
                    let right = String(surface.dropFirst(offset)) + suffix
                    let original = left + right
                    let doc = TruncatedStructuredDocument(before: left, after: right, beforeWindow: beforeWindow, afterWindow: afterWindow)
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    c.backspaceTap(into: doc)
                    let deletionExact = doc.text == String(left.dropLast()) + right
                    c.insertText(String(left.suffix(1)), into: doc)
                    let restored = doc.text == original
                    c.insertLetter("x", touch: .init(down: layout.keys[x].center), into: doc)
                    let insertionExact = doc.text == left + "x" + right
                    c.backspaceTap(into: doc)
                    let finalExact = doc.text == original
                    let noLearning = c.personal.entries.isEmpty
                    let checks = ["deletion_exact": deletionExact,
                                  "restored": restored, "insertion_exact": insertionExact,
                                  "final_exact": finalExact, "no_personal_learning": noLearning]
                    for (name, passed) in checks { XCTAssertTrue(passed, "\(surface) @\(offset): \(name)") }
                    var row = checks.mapValues(String.init)
                    row["surface"] = surface; row["offset"] = String(offset); row["prefix"] = prefix
                    row["before_window"] = String(beforeWindow); row["after_window"] = String(afterWindow)
                    rows.append(row)
                    }
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

private final class TruncatedStructuredDocument: DocumentEditor {
    var before: String
    let after: String
    let beforeWindow: Int
    let afterWindow: Int
    init(before: String, after: String, beforeWindow: Int, afterWindow: Int) {
        self.before = before; self.after = after
        self.beforeWindow = beforeWindow; self.afterWindow = afterWindow
    }
    var text: String { before + after }
    var contextBeforeInput: String? { beforeWindow < 0 ? nil : String(before.suffix(beforeWindow)) }
    var contextAfterInput: String? { afterWindow < 0 ? nil : String(after.prefix(afterWindow)) }
    var selectedText: String? { nil }
    func insertText(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}
