import XCTest
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class ShortFragmentRepairTests: XCTestCase {
    func testDetachedSuffixCorpusEntriesAreNotStandaloneWords() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for fragment in ["nı", "nın", "nün"] {
            XCTAssertFalse(pack.literalChannel.hasListedSurface(fragment), fragment)
        }
        for fragment in ["nı", "nın"] {
            XCTAssertFalse(pack.literalChannel.score(fragment).isInVocabulary, fragment)
        }
        // nü + second-person possession remains a valid generated path;
        // removing its corpus unigram must not blacklist that inflection.
        for word in ["nun", "nü", "nün", "kanını", "senin", "günün", "annemi"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "kannı" {
                let key = layout.keys[layout.keyIndex(for: ch)!]
                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                    y: key.center.y + offset * key.height)), into: doc)
            }
            XCTAssertFalse(c.boundaryRepairs().contains("kan nı"))
            XCTAssertTrue(c.suggestionSurfaces().contains("kanı"))
        }
    }

    func testRareFragmentsDoNotSuppressWholeWordCorrection() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (word, target) in [("patstes", "patates"), ("lslem", "kalem")] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in word {
                c.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: doc)
            }
            XCTAssertTrue(c.boundaryRepairs().isEmpty, "Speculative fragment split: \(c.boundaryRepairs())")
            XCTAssertTrue(c.suggestionSurfaces().contains(target))
            let report = c.space(into: doc)
            XCTAssertNotNil(report.delta, "A fragment split must not bypass normal correction scoring")
        }
    }

    func testCommonShortPhrasesRemainRepairable() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let phrases = ["su iç", "bak o", "o gel", "bu iş", "bir gün", "az tuz", "tuz koy", "çay iç",
                       "çay koy", "iyi ki", "ne var", "ne yok", "al gel", "git al", "gel bak", "ben de",
                       "sen de", "bu da", "çok iyi", "pek iyi", "az ye", "az iç", "az koy", "boş ver",
                       "her gün", "tek tek", "yüz ver", "can ver", "yol ver", "son kez", "bir kez",
                       "onu al", "bunu al", "kod yaz", "log aç", "api yaz", "sql aç", "run it",
                       "try it", "go home", "see you", "let go", "why not"]
        for phrase in phrases {
            let parts = phrase.split(separator: " ").map(String.init)
            for separator in ["", "b"] {
                let input = parts[0] + separator + parts[1]
                let repairs = WordBoundaryRepair.suggestions(for: input, channel: pack.literalChannel, limit: 10)
                if pack.literalChannel.score(input).isInVocabulary {
                    XCTAssertTrue(repairs.isEmpty, "An existing whole word stays intact")
                } else {
                    XCTAssertTrue(repairs.contains(phrase), "Lost short phrase: \(input) → \(phrase); offers \(repairs)")
                }
            }
        }
    }

    func testShortSplitAlternativesStayNearCredibleWinner() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        let repairs = WordBoundaryRepair.suggestions(for: "subiç", channel: pack.literalChannel)
        XCTAssertTrue(repairs.contains("su iç"))
        XCTAssertFalse(repairs.contains("sub iç"), "Unrelated spare-slot split: \(repairs)")
        for phrase in ["su iç", "sub iç", "sql aç", "log aç", "kod yaz", "run it", "try it", "ben de", "sen de"] {
            let parts = phrase.split(separator: " ").map(String.init)
            let scores = parts.map { pack.literalChannel.score($0).lexCost }
            print("SHORT SPLIT COST: \(phrase): \(scores), sum \(scores.reduce(0,+))")
        }
    }

    func testExactListedSplitDoesNotOfferWeakerGeneratedLetterDeletion() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        let repairs = WordBoundaryRepair.suggestions(for: "erişimreddedildi", channel: pack.literalChannel, limit: 10)
        XCTAssertTrue(repairs.contains("erişim reddedildi"))
        XCTAssertFalse(repairs.contains("erişi reddedildi"), "Unnecessary deletion: \(repairs)")
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "senibseviyorum", channel: pack.literalChannel,
            limit: 10).contains("seni seviyorum"), "A real mistap still needs a deletion repair")
        let personal = WordBoundaryRepair.suggestions(for: "erişimreddedildi", channel: pack.literalChannel,
            limit: 10, personalCost: { $0 == "erişi" ? PersonalLexicon.lexCost : nil })
        XCTAssertTrue(personal.contains("erişi reddedildi"), "Preserve the user's own vocabulary")
    }

    func testListedExactBoundaryPrecedesLetterDeletion() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for (input, expected) in [("arzederim", "arz ederim"), ("ricaederim", "rica ederim"),
                                  ("talepediyorum", "talep ediyorum")] {
            let repairs = WordBoundaryRepair.suggestions(for: input, channel: pack.literalChannel, limit: 10)
            XCTAssertEqual(repairs.first, expected, "Input: \(input), offers: \(repairs)")
        }
        XCTAssertEqual(WordBoundaryRepair.suggestions(for: "subiç", channel: pack.literalChannel).first, "su iç")
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "senibseviyorum", channel: pack.literalChannel).contains("seni seviyorum"))
    }

    func testPersonalShortWordsAreNotFilteredAsCorpusFragments() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        c.ingestPersonal(tokens: ["qrx", "qrx", "qrx", "zup", "zup", "zup"])
        let repairs = WordBoundaryRepair.suggestions(for: "qrxzup", channel: c.engine!.literalChannel, limit: 10,
            personalCost: { c.isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
        XCTAssertTrue(c.personal.isAdmitted("qrx"))
        XCTAssertTrue(c.personal.isAdmitted("zup"))
        XCTAssertTrue(repairs.contains("qrx zup"), "Offers: \(repairs)")
        // A personalized root plus a rare built-in short word exceeds the
        // corpus-only cutoff; the user's own vocabulary remains usable.
        let corpusOnly = WordBoundaryRepair.suggestions(for: "qrxlem", channel: c.engine!.literalChannel, limit: 10)
        let personalized = WordBoundaryRepair.suggestions(for: "qrxlem", channel: c.engine!.literalChannel, limit: 10,
            personalCost: { c.isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
        XCTAssertFalse(corpusOnly.contains("qrx lem"))
        XCTAssertTrue(personalized.contains("qrx lem"))
    }
}
