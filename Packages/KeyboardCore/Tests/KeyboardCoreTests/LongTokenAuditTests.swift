import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class LongTokenAuditTests: XCTestCase {
    func testLongTokenBoundaries() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_LONG_TOKEN_AUDIT"] else { throw XCTSkip("Set KB_LONG_TOKEN_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let chain = "ev" + String(repeating: "dekiler", count: 18)
        // Prefix truncations deliberately probe representation boundaries, not grammar.
        let cases = [37,39,40,41,44,72,120].map { String(chain.prefix($0)) }
        var rows: [[String:String]] = []
        for word in cases {
            for mode in ["space", "literal_pick", "delete_last_then_space"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let i = try XCTUnwrap(layout.keyIndex(for: ch))
                    c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                }
                let typedExactly = doc.text == word
                var offeredLiteral = false
                if mode == "literal_pick" {
                    let item = try XCTUnwrap(c.suggestions().first)
                    offeredLiteral = item.surface == word && item.origin == .literal
                    try c.perform(.suggestionPick(id:item.id,surface:item.surface,origin:item.origin), touch:nil,into:doc)
                } else {
                    if mode == "delete_last_then_space" { c.backspaceTap(into: doc) }
                    c.space(into: doc)
                }
                let expected = (mode == "delete_last_then_space" ? String(word.dropLast()) : word) + " "
                rows.append(["length":String(word.count), "mode":mode, "input":word,
                    "typed_exactly":String(typedExactly), "output":doc.text,
                    "matches_literal_commit":String(doc.text == expected),
                    "offered_original":String(offeredLiteral), "learned":String(c.personal.isAdmitted(word))])
                if mode == "literal_pick" || expected.count > 41 { XCTAssertEqual(doc.text,expected) }
            }
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("LONG TOKEN AUDIT: \(rows.count) sequences")
    }
}
