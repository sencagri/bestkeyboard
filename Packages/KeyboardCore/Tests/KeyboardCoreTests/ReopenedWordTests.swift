import XCTest
import KBGeometry
import KBLexicon
@testable import KBRuntime

final class ReopenedWordTests: XCTestCase {
    func testDeletingEntireDocumentClearsBothLanguageAndWordContext() throws {
        for byWord in [false, true] {
            var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
            let doc = FakeDocument()
            try type("kalem", &c, doc)
            c.space(into: doc)
            XCTAssertNotNil(c.engine?.context.previousLanguage)
            if byWord { c.deleteWord(into: doc) }
            else { while !doc.text.isEmpty { c.backspaceTap(into: doc) } }
            XCTAssertEqual(doc.text, "")
            XCTAssertNil(c.engine?.context.previousLanguage)
            XCTAssertNil(c.engine?.context.word)
        }
    }
    func testExpansionReopensOnlyFinalWordAndDeletesOnlyThatWord() throws {
        var c = try TestLexicon.coordinator(["kib": 20, "kendine": 30, "bak": 40], layout: layout)
        let doc = FakeDocument()
        try type("kib", &c, doc)
        c.pickSuggestion("kendine iyi bak", isExpansion: true, into: doc)
        XCTAssertEqual(doc.text, "kendine iyi bak ")
        let effect = c.backspaceTap(into: doc)
        XCTAssertEqual(effect.value?.pending, .restoreDerivedToken)
        XCTAssertEqual(c.session.display, "bak")
        XCTAssertTrue(c.session.touches.isEmpty)
        XCTAssertEqual(c.suggestions().first?.surface, "bak")
        c.deleteWord(into: doc)
        XCTAssertEqual(doc.text, "kendine iyi ")
    }

    private let layout = TurkishQ.layout()
    private func type(_ text: String, _ c: inout InputCoordinator, _ doc: FakeDocument) throws {
        for ch in text {
            let i = try XCTUnwrap(layout.keyIndex(for: ch))
            c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
        }
    }

    func testDeletingPunctuationEmojiDigitsOrExtraSpacesRestoresWholeWord() throws {
        for separator in [".", ",", "-", "🙂", "1", "   ", "\n"] {
            var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
            let doc = FakeDocument()
            try type("kalem", &c, doc)
            for ch in separator { c.insertSymbol(ch, into: doc) }
            for _ in separator { c.backspaceTap(into: doc) }
            XCTAssertEqual(doc.text, "kalem", separator)
            XCTAssertTrue(c.session.isReopened, separator)
            try type("ler", &c, doc)
            XCTAssertEqual(c.suggestions().first?.surface, "kalemler", separator)
            XCTAssertEqual(doc.text, "kalemler", separator)
        }
    }

    func testOriginalRemainsReachableAfterAutocorrectAndReopen() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = -1000
        let doc = FakeDocument()
        try type("kalen", &c, doc)
        XCTAssertEqual(c.space(into: doc).kind, .autocorrect)
        XCTAssertEqual(doc.text, "kalem ")
        c.backspaceTap(into: doc)
        let original = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
        XCTAssertEqual(original.surface, "kalen")
        try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
        XCTAssertEqual(doc.text, "kalen ")
        XCTAssertTrue(c.personal.isAdmitted("kalen"))
    }

    func testRecommitDoesNotMultiplyLearningOrAutocorrectAgain() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = 1000
        let doc = FakeDocument()
        try type("qrmenü", &c, doc)
        c.space(into: doc)
        let points = c.personal.entries["qrmenü"]?.points
        let samples = c.calibration.sampleCount
        c.correction.oovTheta = -1000
        for _ in 0..<4 {
            c.backspaceTap(into: doc)
            XCTAssertTrue(c.session.isReopened)
            XCTAssertNotEqual(c.space(into: doc).kind, .autocorrect)
            XCTAssertEqual(doc.text, "qrmenü ")
            XCTAssertEqual(c.personal.entries["qrmenü"]?.points, points)
            XCTAssertEqual(c.calibration.sampleCount, samples)
        }
        c.correction.oovTheta = 1000
        try type("qrmenü", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, (points ?? 0) + 1)
    }
}

extension ReopenedWordTests {
    func testExplicitDetachedLiteralCanBeAcceptedWithoutInventingTouches() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        doc.hostRewrites(to: "qrmenü")
        c.adoptDetachedSurface("qrmenü")
        let samples = c.calibration.sampleCount
        let original = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
        try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
        XCTAssertEqual(doc.text, "qrmenü ")
        XCTAssertTrue(c.personal.isAdmitted("qrmenü"))
        XCTAssertEqual(c.calibration.sampleCount, samples)
    }
}
