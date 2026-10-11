import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Diagnostic capture only: does not assert that every observed output is correct.
final class TurkishInteractionAuditTests: XCTestCase {
    func testEditingSequences() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_INTERACTION_AUDIT"] else {
            throw XCTSkip("Set KB_INTERACTION_AUDIT to export editing sequences")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["qrmenü", "cepmenü", "sokaktaydım", "gelemiyormuşsunuz", "kitabımdı", "gelmemişsiniz", "bugünkülerden", "kitap"] {
            for mode in ["reopen", "retype_last", "delete_retype", "choose_then_append", "choose_reopen"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                func type(_ s: String) throws {
                    for ch in s {
                        let index = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
                    }
                }
                func capture(_ step: String) {
                    rows.append(["input": word, "mode": mode, "step": step, "document": doc.text,
                                 "literal": c.session.literal, "display": c.session.display,
                                 "suggestions": c.suggestionSurfaces().joined(separator: " | "),
                                 "calibration_samples": String(c.calibration.sampleCount),
                                 "learned_original": String(c.personal.isAdmitted(word))])
                }
                try type(word)
                capture("typed")
                if mode.hasPrefix("choose") {
                    let item = try XCTUnwrap(c.suggestions().first)
                    try c.perform(.suggestionPick(id: item.id, surface: item.surface, origin: item.origin), touch: nil, into: doc)
                } else { c.space(into: doc) }
                capture("committed")
                c.backspaceTap(into: doc)
                capture("backspace")
                switch mode {
                case "retype_last":
                    c.backspaceTap(into: doc)
                    try type(String(word.suffix(1)))
                    capture("last_retyped")
                case "delete_retype":
                    c.deleteWord(into: doc)
                    try type(word)
                    capture("whole_retyped")
                case "choose_then_append":
                    try type("den")
                    capture("suffix_appended")
                default: break
                }
                c.space(into: doc)
                capture("recommitted")
                c.backspaceTap(into: doc)
                capture("second_backspace")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("INTERACTION AUDIT: 40 sequences, \(rows.count) snapshots; \(output)")
    }
}
