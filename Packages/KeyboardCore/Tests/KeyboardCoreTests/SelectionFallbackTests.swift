import XCTest
import KBGeometry
@testable import KBRuntime

final class SelectionFallbackTests: XCTestCase {
    func testUnmappedCharactersStillOfferExactSelectedWord() throws {
        for word in ["e-posta", "covid19", "qrmenü", "kâğıt", "TCP/IP"] {
            var c = try TestLexicon.coordinator(["kalem": 500], layout: TurkishQ.layout())
            let doc = FakeDocument()
            doc.hostRewrites(to: "önce " + word + " sonra")
            doc.hostSelects(word)
            XCTAssertNotNil(c.handleSelection(word, into: doc), word)
            let original = try XCTUnwrap(c.suggestions().first { $0.surface == word }, word)
            c.pickSuggestion(original.surface, into: doc)
            XCTAssertEqual(doc.text, "önce " + word + " sonra")
            XCTAssertEqual(c.calibration.sampleCount, 0)
        }
    }

    func testSelectionCorrectionPreservesEdgeWhitespace() throws {
        var c = try TestLexicon.coordinator(["güzel": 500], layout: TurkishQ.layout())
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce  guzel\u{00a0} sonra")
        doc.hostSelects(" guzel\u{00a0}")
        XCTAssertNotNil(c.handleSelection(doc.selectedText, into: doc))
        c.pickSuggestion("güzel", into: doc)
        XCTAssertEqual(doc.text, "önce  güzel\u{00a0} sonra")
    }
}
