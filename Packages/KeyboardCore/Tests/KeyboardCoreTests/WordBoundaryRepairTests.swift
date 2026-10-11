import XCTest
import KBGeometry
@testable import KBRuntime

final class WordBoundaryRepairTests: XCTestCase {
    func testShortRepairsPreserveLiteralUntilChosen() throws {
        let layout = TurkishQ.layout()
        for input in ["suiç", "subiç", "obgel", "bako", "bakbo"] {
            var c = try TestLexicon.coordinator(["su": 500, "iç": 500, "o": 500, "gel": 500, "bak": 500], layout: layout)
            let doc = FakeDocument()
            for ch in input {
                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
            }
            XCTAssertTrue(c.suggestions().contains { $0.surface.contains(" ") }, input)
            c.space(into: doc)
            XCTAssertEqual(doc.text, input + " ")
        }
    }

    func testSingleLetterSymbolsAndKnownWordsAreNotSplit() throws {
        let engine = try TestLexicon.engine(["x": 500, "a": 500, "su": 500, "iç": 500, "o": 500, "os": 500, "bunda": 500], layout: TurkishQ.layout())
        for input in ["xsu", "sux", "asu", "sua", "os", "bunda", "o", "su", "su/iç", "su1iç"] {
            XCTAssertTrue(WordBoundaryRepair.suggestions(for: input, channel: engine.literalChannel).isEmpty, input)
        }
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "SUiÇ", channel: engine.literalChannel).contains("Su iç"))
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "SUİÇ", channel: engine.literalChannel).contains("SU İÇ"))
    }

    func testEverySpaceAdjacentLetterOffersTheTwoWords() throws {
        let layout = TurkishQ.layout()
        for separator in [""] + "zxcvbnmçö".map(String.init) {
            var c = try TestLexicon.coordinator(["seni": 500, "seviyorum": 500], layout: layout)
            let doc = FakeDocument()
            let input = "seni" + separator + "seviyorum"
            for ch in input {
                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
            }
            XCTAssertEqual(c.suggestions().first?.surface, input)
            XCTAssertTrue(c.suggestions().contains { $0.surface == "seni seviyorum" }, input)
            c.space(into: doc)
            XCTAssertEqual(doc.text, input + " ", "A repair requires an explicit choice")
        }
    }

    func testMissingAndMistappedSpaceRequireTwoKnownWords() throws {
        let engine = try TestLexicon.engine(["merhaba": 500, "dünya": 500, "kitap": 500], layout: TurkishQ.layout())
        let channel = engine.literalChannel
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhabadünya", channel: channel).contains("merhaba dünya"))
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhababdünya", channel: channel).contains("merhaba dünya"))
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhabaqdünya", channel: channel).isEmpty)
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhabaxyz", channel: channel).isEmpty)
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhaba/dünya", channel: channel).isEmpty)
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "merhaba", channel: channel).isEmpty)
    }

    func testExplicitRepairPreservesSurroundingText() throws {
        let layout = TurkishQ.layout()
        var c = try TestLexicon.coordinator(["merhaba": 500, "dünya": 500], layout: layout)
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce ")
        for ch in "merhababdünya" {
            let i = try XCTUnwrap(layout.keyIndex(for: ch))
            c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
        }
        XCTAssertEqual(c.suggestions().first?.surface, "merhababdünya")
        let repair = try XCTUnwrap(c.suggestions().first { $0.surface == "merhaba dünya" })
        try c.perform(.suggestionPick(id: repair.id, surface: repair.surface, origin: repair.origin), touch: nil, into: doc)
        XCTAssertEqual(doc.text, "önce merhaba dünya ")
    }
}
