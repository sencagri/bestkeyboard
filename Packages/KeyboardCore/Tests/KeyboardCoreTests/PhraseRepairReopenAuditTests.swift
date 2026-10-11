import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBSpatial
@testable import KBRuntime

final class PhraseRepairReopenAuditTests: XCTestCase {
    func testPhraseRepairReopenAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_PHRASE_REOPEN_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        func type(_ text: String, _ c: inout InputCoordinator, _ doc: FakeDocument) throws {
            for ch in text {
                let lower = Character(String(ch).lowercased(with: locale))
                let key = try XCTUnwrap(layout.keyIndex(for: lower))
                let touch = TouchSample(down: layout.keys[key].center)
                if ch == lower { c.insertLetter(lower, touch: touch, into: doc) }
                else { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
            }
        }
        var rows: [[String: String]] = []
        for (raw, phrase) in [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki"), ("subiç", "su iç"),
                              ("obzaman", "o zaman"), ("qrmenübaç", "qrmenü aç"), ("qrmenüdenbaç", "qrmenüden aç")] {
            for casing in ["lower", "title", "caps"] {
                func styled(_ text: String) -> String {
                    if casing == "caps" { return text.uppercased(with: locale) }
                    if casing == "title" { return text.prefix(1).uppercased(with: locale) + text.dropFirst() }
                    return text
                }
                let input = styled(raw), expected = styled(phrase)
                let words = expected.split(separator: " ").map(String.init)
                for prefix in ["", "önce "] {
                    for action in ["space_cycles", "delete_last_word", "replace_last_letter", "delete_all"] {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        var personal = PersonalLexicon(); personal.observe("qrmenü", confidence: .strong)
                        c.replacePersonalLexicon(personal)
                        let doc = FakeDocument(); doc.hostRewrites(to: prefix)
                        try type(input, &c, doc)
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == expected }, input)
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        var target = prefix + expected + " "
                        var reopenExact = true
                        var reopenStates: [String] = []
                        switch action {
                        case "space_cycles":
                            for _ in 0..<3 {
                                c.backspaceTap(into: doc)
                                reopenStates.append("display=\(c.session.display);touches=\(c.session.touches.count);reopened=\(c.session.isReopened)")
                                reopenExact = reopenExact && c.session.display == words[1] && c.session.touches.isEmpty
                                c.space(into: doc)
                            }
                        case "delete_last_word":
                            c.backspaceTap(into: doc); c.deleteWord(into: doc)
                            target = prefix + words[0] + " "
                        case "replace_last_letter":
                            c.backspaceTap(into: doc); c.backspaceTap(into: doc)
                            try type(String(words[1].suffix(1)), &c, doc); c.space(into: doc)
                        default:
                            for _ in (expected + " ") { c.backspaceTap(into: doc) }
                            target = prefix
                        }
                        XCTAssertEqual(doc.text, target, input + action)
                        XCTAssertTrue(reopenExact, input + action)
                        rows.append(["input": input, "prefix": prefix, "action": action, "expected": target,
                                     "reopen_states": reopenStates.joined(separator: " | "), "actual": doc.text, "exact": String(doc.text == target), "reopen_exact": String(reopenExact)])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
