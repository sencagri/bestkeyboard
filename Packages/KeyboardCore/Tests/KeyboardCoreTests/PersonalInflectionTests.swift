import XCTest
import KBGeometry
import KBLearning
@testable import KBRuntime

final class PersonalInflectionTests: XCTestCase {
    func testRepairUsesPersonalFormsAndForgetRevokesOnlyTheirOffers() throws {
        let layout = TurkishQ.layout()
        var c = try TestLexicon.coordinator(["aç": 500, "bu": 500], layout: layout)
        var learned = PersonalLexicon()
        learned.observe("qrmenü", confidence: .strong)
        c.replacePersonalLexicon(learned)
        let doc = FakeDocument()
        for ch in "qrmenüdenbaç" {
            let i = try XCTUnwrap(layout.keyIndex(for: ch))
            c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
        }
        XCTAssertTrue(c.boundaryRepairs().contains("qrmenüden aç"))
        c.space(into: doc)
        XCTAssertEqual(doc.text, "qrmenüdenbaç ", "No automatic phrase replacement")
        XCTAssertTrue(c.forgetPersonal("qrmenü"))
        for ch in "qrmenüdenbaç" {
            let i = try XCTUnwrap(layout.keyIndex(for: ch))
            c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
        }
        XCTAssertFalse(c.boundaryRepairs().contains("qrmenüden aç"))
    }

    func testWholePersonalInflectionIsNotSplit() throws {
        let engine = try TestLexicon.engine(["qr": 500, "menüden": 500], layout: TurkishQ.layout())
        let forms: Set<String> = ["qrmenüden"]
        let results = WordBoundaryRepair.suggestions(for: "qrmenüden", channel: engine.literalChannel,
            personalCost: { forms.contains($0) ? PersonalLexicon.lexCost : nil })
        XCTAssertTrue(results.isEmpty)
    }

    func testAcceptedRootProtectsTypedInflectionsAndForgetRevokesProtection() throws {
        let layout = TurkishQ.layout()
        var c = try TestLexicon.coordinator(["menü": 500], layout: layout)
        var learned = PersonalLexicon()
        learned.observe("qrmenü", confidence: .strong)
        c.replacePersonalLexicon(learned)
        for word in ["qrmenülerimizden", "qrmenümüz", "qrmenüden", "qrmenüdeymiş"] {
            XCTAssertTrue(c.isKnownPersonalInflection(word), word)
            let doc = FakeDocument()
            for ch in word {
                let i = try XCTUnwrap(layout.keyIndex(for: ch))
                c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
            }
            c.correction.oovTheta = -1000
            c.space(into: doc)
            XCTAssertEqual(doc.text, word + " ")
        }
        XCTAssertFalse(c.isKnownPersonalInflection("başkamenülerimizden"))
        XCTAssertTrue(c.forgetPersonal("qrmenü"))
        XCTAssertFalse(c.isKnownPersonalInflection("qrmenülerimizden"))
    }
}
