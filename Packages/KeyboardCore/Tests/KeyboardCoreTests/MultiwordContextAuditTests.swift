import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLexicon
import KBRuntime

final class MultiwordContextAuditTests: XCTestCase {
    func testExpansionContext() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_MULTIWORD_CONTEXT_AUDIT"] else { throw XCTSkip("Set KB_MULTIWORD_CONTEXT_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let (bytes, _) = try BigramPackBuilder().build(
            unigrams: ["bak": 1000, "bay": 1000, "selam": 1000, "kalem": 900, "işlem": 1500],
            bigrams: ["bak", "bay", "selam"].flatMap { [BigramCount(context: $0, word: "kalem", count: 400), BigramCount(context: $0, word: "işlem", count: 5)] })
        let bigrams = try BigramPack(packData: Data(bytes))
        var rows: [[String: String]] = []
        for enabled in [false, true] {
            for trigger in ["slm", "kib", "bb"] {
                let target = try XCTUnwrap(pack.expansions?.expansions(of: trigger).first)
                for mode in ["expansion", "typed"] {
                    var decoder = pack.decoder; var literal = pack.literalChannel
                    if enabled { decoder.bigrams = bigrams; literal.bigrams = bigrams }
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: decoder, literalChannel: literal, expansions: pack.expansions))
                    let doc = FakeDocument()
                    for ch in mode == "expansion" ? trigger : target {
                        if ch == " " { c.space(into: doc); continue }
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: key.center), into: doc)
                    }
                    if mode == "expansion" {
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    } else { c.space(into: doc) }
                    XCTAssertEqual(doc.text, target + " ")
                    let channel = try XCTUnwrap(c.engine?.literalChannel)
                    var row = ["controlled_bigrams": String(enabled), "mode": mode, "trigger": trigger, "target": target,
                        "context": c.engine?.context.word ?? "nil", "document": doc.text,
                        "kalem_cost": String(channel.totalLexicalCost(channel.score("kalem"), token: "kalem"))]
                    row["kalem_context_delta"] = String(channel.contextDelta(of: "kalem"))
                    c.backspaceTap(into: doc)
                    row["after_backspace"] = doc.text
                    row["reopened_display"] = c.session.display
                    row["reopened_literal"] = c.session.literal
                    rows.append(row)
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
