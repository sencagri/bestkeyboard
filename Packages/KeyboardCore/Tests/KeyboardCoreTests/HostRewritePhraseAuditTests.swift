import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class HostRewritePhraseAuditTests: XCTestCase {
    func testHostRewriteRejectsRepeatedOldSuggestion() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_HOST_REWRITE_PHRASE_AUDIT"] else { throw XCTSkip("Opt-in host rewrite audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for (raw, phrase) in [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki"), ("subiç", "su iç"),
                              ("obzaman", "o zaman"), ("qrmenübaç", "qrmenü aç"), ("qrmenüdenbaç", "qrmenüden aç")] {
            for mode in ["typing", "selected", "reopened"] {
                for replacement in ["", "başka", "https://örnek.com/çağrı", "dev@example.com", "👨‍👩‍👧‍👦", "önce\nsonra"] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    var personal = PersonalLexicon(); personal.observe("qrmenü", confidence: .strong)
                    c.replacePersonalLexicon(personal)
                    let doc = FakeDocument()
                    for ch in raw {
                        let key = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                    }
                    if mode == "selected" {
                        c.space(into: doc); doc.hostSelects(raw); c.handleSelection(doc.selectedText, into: doc)
                    }
                    var target = phrase
                    if mode == "reopened" {
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        c.backspaceTap(into: doc); target = c.session.display
                    }
                    let stale = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                    let personalBefore = c.personal
                    let calibrationBefore = c.calibration.sampleCount
                    doc.hostRewrites(to: replacement)
                    var unchanged = true
                    // Deliberately omit the host callback to test the final coordinator guard.
                    // The app also validates full presented context before reaching this path.
                    for _ in 0..<3 {
                        if let current = c.suggestions().first(where: { $0.surface == stale.surface }) {
                            try c.perform(.suggestionPick(id: current.id, surface: current.surface, origin: current.origin), touch: nil, into: doc)
                        }
                        unchanged = unchanged && doc.text == replacement
                    }
                    c.handleSelection(nil, into: doc)
                    let key = try XCTUnwrap(layout.keyIndex(for: "x"))
                    c.insertLetter("x", touch: .init(down: layout.keys[key].center), into: doc)
                    rows.append(["input": raw, "mode": mode, "replacement": replacement,
                                 "unchanged": String(unchanged), "continued_exact": String(doc.text == replacement + "x"),
                                 "personal_unchanged": String(c.personal == personalBefore),
                                 "calibration_unchanged": String(c.calibration.sampleCount == calibrationBefore)])
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
