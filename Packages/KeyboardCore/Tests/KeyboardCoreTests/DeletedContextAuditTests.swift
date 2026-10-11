import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class DeletedContextAuditTests: XCTestCase {
    func testDeletedLanguageContext() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_DELETED_CONTEXT_AUDIT"] else { throw XCTSkip("Set KB_DELETED_CONTEXT_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["sokaktaydım", "qrmenü", "gelemiyormuşsunuz", "kitabımdı"] {
            for mode in ["fresh", "english_kept", "english_delete_word", "english_delete_taps", "english_host_cleared", "english_invalidate", "turkish_delete_word"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                func type(_ text: String) throws {
                    for ch in text {
                        let i = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                    }
                }
                if mode != "fresh" {
                    try type(mode == "turkish_delete_word" ? "merhaba" : "the")
                    c.space(into: doc)
                    switch mode {
                    case "english_delete_word", "turkish_delete_word": c.deleteWord(into: doc)
                    case "english_delete_taps":
                        while !doc.text.isEmpty { c.backspaceTap(into: doc) }
                    case "english_host_cleared":
                        doc.hostRewrites(to: "")
                        c.handleSelection(nil, into: doc)
                    case "english_invalidate":
                        doc.hostRewrites(to: "")
                        c.invalidateComposing()
                    default: break
                    }
                }
                let before = doc.text
                let previous = c.engine?.context.previousLanguage.map(String.init) ?? "nil"
                try type(word)
                let suggestions = c.suggestionSurfaces().joined(separator: " | ")
                let report = c.space(into: doc)
                rows.append(["input": word, "mode": mode, "before": before,
                    "previous_language": previous, "output": doc.text,
                    "suggestions": suggestions, "decision": report.kind.rawValue])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("DELETED CONTEXT AUDIT: \(rows.count) sequences")
    }
}
