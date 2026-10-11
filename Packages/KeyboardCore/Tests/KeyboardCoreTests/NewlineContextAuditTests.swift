import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLexicon
import KBRuntime

/// Opt-in diagnostic: production bundle plus explicit bigram-enabled control.
final class NewlineContextAuditTests: XCTestCase {
    func testBoundaryContextPaths() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_NEWLINE_CONTEXT_AUDIT"] else {
            throw XCTSkip("Set KB_NEWLINE_CONTEXT_AUDIT")
        }
        let layout = TurkishQ.layout()
        let production = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let (bytes, _) = try BigramPackBuilder().build(
            unigrams: ["kalem": 900, "işlem": 1500, "ve": 20000],
            bigrams: [BigramCount(context: "ve", word: "kalem", count: 400),
                      BigramCount(context: "ve", word: "işlem", count: 5)])
        let bigrams = try BigramPack(packData: Data(bytes))
        var rows: [[String: String]] = []
        for configuration in ["production", "controlled_bigrams"] {
            for mode in ["direct_newline", "space_newline", "comma_newline", "pick_newline", "space_period", "space_insert_newline", "space_insert_two_newlines", "space_only"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(configuration == "production"
                    ? .init(decoder: production.decoder, literalChannel: production.literalChannel)
                    : try TestLexicon.engine(layout: layout, bigrams: bigrams))
                let doc = FakeDocument()
                for ch in "ve" {
                    let i = try XCTUnwrap(layout.keyIndex(for: ch))
                    c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                }
                switch mode {
                case "direct_newline": c.newline(into: doc)
                case "comma_newline": c.insertSymbol(",", into: doc); c.newline(into: doc)
                case "pick_newline": c.pickSuggestion("ve", into: doc); c.newline(into: doc)
                default:
                    c.space(into: doc)
                    switch mode {
                    case "space_newline": c.newline(into: doc)
                    case "space_period": c.insertSymbol(".", into: doc)
                    case "space_insert_newline": c.insertText("\n", into: doc)
                    case "space_insert_two_newlines": c.insertText("\n\n", into: doc)
                    default: break
                    }
                }
                let channel = try XCTUnwrap(c.engine?.literalChannel)
                rows.append(["configuration": configuration, "mode": mode,
                    "document": doc.text, "context_word": c.engine?.context.word ?? "nil",
                    "has_bigrams": String(c.engine?.decoder.bigrams != nil),
                    "kalem_lexical_cost": String(channel.totalLexicalCost(channel.score("kalem"))),
                    "islem_lexical_cost": String(channel.totalLexicalCost(channel.score("işlem")))])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        print("NEWLINE CONTEXT AUDIT: \(rows.count) paths")
    }
}
