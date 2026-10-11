import XCTest
import KBFoundation
import KBGeometry
import KBSpatial
@testable import KBRuntime

final class CorrectionContextTests: XCTestCase {
    func testTechnicalSpanAndCaseProtection() {
        for input in ["tcp/ip", "feature/graphql", "index.tsx", "me@example.com", "192.168.1.1", "@qrmenü", "#qrmenü", "--graphql", "v2graphql", "getUserById", "QRmenü", "HTTP", "Ankara'dayım"] {
            let context = CorrectionContext(display: String(input.reversed().prefix { $0.isLetter }.reversed()), before: "önce " + input)
            XCTAssertTrue(context.protectsLiteral, input)
        }
        for input in ["kalen", "Kalen", "KALEN", "“kalen", "'kalen", "(kalen"] {
            let display = String(input.reversed().prefix { $0.isLetter }.reversed())
            XCTAssertFalse(CorrectionContext(display: display, before: input).protectsLiteral, input)
        }
        XCTAssertTrue(CorrectionContext(display: "kalen", before: "other").protectsLiteral)
        XCTAssertTrue(CorrectionContext(display: "kalen", before: nil).protectsLiteral)
    }

    func testProtectionThroughActualTypingAndResetAtWhitespace() throws {
        let layout = TurkishQ.layout()
        for input in ["api/kalen", "feature/kalen", "index.kalen", "test_kalen", "@kalen", "#kalen", "x:kalen", "v2kalen", "kaLen", "KALN"] {
            var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
            c.correction.oovTheta = -1000
            let doc = FakeDocument()
            for ch in input {
                let lower = TurkishText.lowercased(String(ch))
                if let key = lower.first, let index = layout.keyIndex(for: key) {
                    let touch = TouchSample(down: layout.keys[index].center)
                    if ch.isUppercase { c.insertUppercaseLetter(key, uppercase: String(ch), touch: touch, synthetic: false, into: doc) }
                    else { c.insertLetter(ch, touch: touch, into: doc) }
                } else { c.insertSymbol(ch, into: doc) }
            }
            XCTAssertNotEqual(c.space(into: doc).kind, .autocorrect, input)
            XCTAssertEqual(doc.text, input + " ")
            for ch in "kalen" {
                let index = try XCTUnwrap(layout.keyIndex(for: ch))
                c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
            }
            XCTAssertEqual(c.space(into: doc).kind, .autocorrect)
            XCTAssertEqual(doc.text, input + " kalem ")
        }
    }

    func testStaleLiteralSuggestionDoesNotLearnOrModifyHost() throws {
        let layout = TurkishQ.layout()
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        for ch in "qrmenü" {
            let index = try XCTUnwrap(layout.keyIndex(for: ch))
            c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
        }
        let pick = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
        doc.hostRewrites(to: "başka metin")
        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
        XCTAssertEqual(doc.text, "başka metin")
        XCTAssertFalse(c.wantsPersonalSave)
    }

    func testExternalUppercaseSelectionOffersAndLearnsOriginal() throws {
        let layout = TurkishQ.layout()
        for word in ["qrmenü", "QRmenü", "İzmirli", "GÜZEL"] {
            var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
            let doc = FakeDocument()
            doc.hostRewrites(to: "önce " + word)
            doc.hostSelects(word)
            XCTAssertEqual(c.handleSelection(doc.selectedText, into: doc), word)
            let pick = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
            XCTAssertEqual(pick.surface, word)
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertNil(doc.selectedText)
            XCTAssertTrue(c.wantsPersonalSave)
            let index = try XCTUnwrap(layout.keyIndex(for: "a"))
            c.insertLetter("a", touch: .init(down: layout.keys[index].center), into: doc)
            XCTAssertEqual(doc.text, "önce " + word + "a")
        }
    }
}

extension CorrectionContextTests {
    func testCompositionFragmentCannotRewriteTailOfWholeWord() {
        XCTAssertTrue(CorrectionContext(display: "ğıtlar", before: "kâğıtlar").protectsLiteral)
        XCTAssertTrue(CorrectionContext(display: "menü", before: "qrmenü").protectsLiteral)
        XCTAssertFalse(CorrectionContext(display: "kalen", before: "(kalen").protectsLiteral)
    }
}
