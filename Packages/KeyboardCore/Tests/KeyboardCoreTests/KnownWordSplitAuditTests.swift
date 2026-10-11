import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBLearning
@testable import KBRuntime

final class KnownWordSplitAuditTests: XCTestCase {
    func testKnownWordsAreNotSplit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_KNOWN_WORD_SPLIT_AUDIT"] else {
            throw XCTSkip("Opt-in known word split audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        var rows: [[String: String]] = []
        for word in ["bunda", "bunun", "bana", "sana", "bizim", "biraz", "birkaç", "birçok",
                     "bugün", "hiçbir", "herhangi", "başkent", "bilgisayar", "ayakkabı", "kahvaltı",
                     "qrmenü", "mavilo", "zepnuk"] {
            for profile in ["none", "accepted", "imported"] {
                var base = InputCoordinator(layout: layout)
                base.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                if profile == "accepted" {
                    var personal = PersonalLexicon(); personal.observe(word, confidence: .strong)
                    base.replacePersonalLexicon(personal)
                } else if profile == "imported" { _ = base.ingestPersonal(tokens: [word, word, word]) }
                for input in [word, word.prefix(1).uppercased(with: locale) + word.dropFirst(), word.uppercased(with: locale)] {
                    var c = base
                    let doc = FakeDocument()
                    for ch in input {
                        let lower = Character(String(ch).lowercased(with: locale))
                        let key = try XCTUnwrap(layout.keyIndex(for: lower))
                        let touch = TouchSample(down: layout.keys[key].center)
                        if ch == lower { c.insertLetter(lower, touch: touch, into: doc) }
                        else { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
                    }
                    let known = pack.literalChannel.score(word).isInVocabulary || profile != "none"
                    let splits = c.suggestions().map(\.surface).filter { $0.contains(" ") }
                    c.space(into: doc)
                    rows.append(["input": input, "profile": profile, "known": String(known),
                                 "split_offers": splits.joined(separator: " | "),
                                 "preserved": String(doc.text == input + " "), "actual": doc.text])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
