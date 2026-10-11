import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBSpatial
@testable import KBRuntime

final class ReopenedPhraseSymbolAuditTests: XCTestCase {
    func testReopenedPhraseSymbolAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_REOPENED_SYMBOL_AUDIT"] else { throw XCTSkip("Opt-in reopened phrase symbol audit") }
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
        for (inputBase, phraseBase) in [("merhababdünya", "merhaba dünya"), ("bubev", "bu ev"),
                                        ("birbkitap", "bir kitap"), ("bubokul", "bu okul")] {
            for casing in ["lower", "title", "caps"] {
                func styled(_ value: String) -> String {
                    if casing == "caps" { return value.uppercased(with: locale) }
                    if casing == "title" { return value.prefix(1).uppercased(with: locale) + value.dropFirst() }
                    return value
                }
                let input = styled(inputBase), phrase = styled(phraseBase)
                for separator in [".", ",", "?!", "🙂", "👨‍👩‍👧‍👦", "12", "   ", "… "] {
                    for prefix in ["", "önce "] {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        let doc = FakeDocument(); doc.hostRewrites(to: prefix)
                        try type(input, &c, doc)
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase }, input)
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        c.backspaceTap(into: doc)
                        for ch in separator { c.insertSymbol(ch, into: doc) }
                        let insertionExact = doc.text == prefix + phrase + separator
                        for _ in separator { c.backspaceTap(into: doc) }
                        let tail = String(phrase.split(separator: " ").last!)
                        let literalVisible = c.suggestions().first?.surface == tail
                        let reopened = c.session.display == tail && c.session.isDetached && c.session.touches.isEmpty
                        let removalExact = doc.text == prefix + phrase
                        try type(casing == "caps" ? "X" : "x", &c, doc)
                        c.space(into: doc)
                        rows.append(["input": input, "separator": separator, "prefix": prefix,
                                     "inserted_exact": String(insertionExact), "removed_exact": String(removalExact),
                                     "literal_visible": String(literalVisible), "reopened_exact": String(reopened),
                                     "continued_exact": String(doc.text == prefix + phrase + (casing == "caps" ? "X " : "x ")),
                                     "actual": doc.text])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
