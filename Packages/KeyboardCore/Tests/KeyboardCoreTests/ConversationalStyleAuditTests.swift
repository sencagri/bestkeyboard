import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class ConversationalStyleAuditTests: XCTestCase {
    private let forms = ["uşağum", "gardaş", "nörüyon", "geliyom", "gidiyom", "yapıyom",
                     "ediyom", "bakıyon", "napıyon", "naber", "bi", "hele", "ula", "la",
                     "içek", "gidek", "napıyoz", "geliyon", "gidiyon", "yapıyon", "bilmiyom",
                     "biliyon", "diyom", "diyon", "oluyo", "oluyom", "oluyon", "geliyoz",
                     "gidiyoz", "yapıyoz", "ediyoz", "soğudi", "gardaşım", "konuşak", "napıyosun", "gelecem"]

    func testIntentionalConversationalFormsStayUnchangedWithShiftedTouches() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in forms {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
            for offset in [-0.18, 0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                              y: key.center.y + offset * key.height)), into: doc)
                }
                c.space(into: doc)
                XCTAssertEqual(doc.text, word + " ", "\(word), offset=\(offset)")
                XCTAssertTrue(c.personal.entries.isEmpty, "Built-in forms must not pollute personal learning")
            }
        }
    }

    func testConversationStyleAndTypoControls() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_STYLE_AUDIT"] else {
            throw XCTSkip("Set KB_STYLE_AUDIT to export conversational style probes")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let controls = [("şimdş", "şimdi"), ("belkş", "belki"), ("geldş", "geldi"),
                        ("hangş", "hangi"), ("patstes", "patates"), ("anaokuku", "anaokulu"),
                        ("özledşm", "özledim"), ("geliyprum", "geliyorum"),
                        ("mühendislik", "mühendislik"), ("veritabanı", "veritabanı"),
                        ("değerlendirilmesini", "değerlendirilmesini"), ("saygılarımla", "saygılarımla")]
        var rows: [[String: String]] = []
        for (group, cases) in [("style", forms.map { ($0, $0) }), ("control", controls)] {
            for (word, expected) in cases {
                for offset in [-0.18, 0, 0.18] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    for ch in word {
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                                  y: key.center.y + offset * key.height)), into: doc)
                    }
                    let offers = c.suggestionSurfaces()
                    let report = c.space(into: doc)
                    rows.append(["group": group, "word": word, "expected": expected + " ",
                                 "offset": String(offset), "actual": doc.text,
                                 "exact": String(doc.text == expected + " "),
                                 "offers": offers.joined(separator: " | "),
                                 "delta": report.delta.map(String.init(describing:)) ?? "nil"])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
