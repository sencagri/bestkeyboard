import XCTest
import Foundation
import KBFoundation
import KBGeometry
@testable import KBRuntime

final class SelectionUnicodeIdentityTests: XCTestCase {
    func testSelectedCanonicalVariantsKeepDecoderEvidenceAndOriginal() throws {
        let pack = RecordingTestSupport.loaded, layout = TurkishQ.layout()
        for word in ["resmî", "millî", "dinî", "fiilî", "sükûn", "kâğıt"] {
            for casing in 0..<3 {
                let styled = casing == 2 ? TurkishText.uppercased(word) : casing == 1 ? TurkishText.uppercased(String(word.prefix(1))) + word.dropFirst() : word
                var candidates: [[String]] = []
                for source in [styled.precomposedStringWithCanonicalMapping, styled.decomposedStringWithCanonicalMapping] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    let selected = " " + source + "\u{00a0}"
                    let expected = "önce" + selected + "sonra"
                    doc.hostRewrites(to: expected); doc.hostSelects(selected)
                    XCTAssertNotNil(c.handleSelection(selected, into: doc))
                    XCTAssertEqual(c.session.literal, TurkishText.key(source), source)
                    XCTAssertEqual(c.session.touches.count, source.count, source)
                    XCTAssertFalse(c.session.selectionHasRealEvidence)
                    let original = try XCTUnwrap(c.suggestions().first)
                    XCTAssertEqual(Array(original.surface.utf8), Array(source.utf8))
                    candidates.append(c.candidates().map(\.word))
                    try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
                    XCTAssertEqual(doc.text, expected)
                    XCTAssertNil(doc.selectedText)
                    XCTAssertEqual(c.calibration.sampleCount, 0)
                }
                XCTAssertFalse(candidates[0].isEmpty, word)
                XCTAssertEqual(candidates[0], candidates[1], "NFC/NFD must offer the same decoder alternatives: \(styled)")
            }
        }
    }

    func testCaseIdentityComposesBeforeTurkishFolding() {
        for word in ["resmî", "millî", "dinî", "fiilî", "sükûn", "kâğıt", "istanbul", "ılık"] {
            let upper = TurkishText.uppercased(word)
            for left in [word, word.decomposedStringWithCanonicalMapping, upper, upper.decomposedStringWithCanonicalMapping] {
                for right in [word, word.decomposedStringWithCanonicalMapping, upper, upper.decomposedStringWithCanonicalMapping] {
                    XCTAssertTrue(TurkishText.equalIgnoringCase(left, right), "\(left) / \(right)")
                }
            }
        }
        XCTAssertFalse(TurkishText.equalIgnoringCase("I", "i"))
        XCTAssertFalse(TurkishText.equalIgnoringCase("Î", "ı"))
        XCTAssertFalse(TurkishText.equalIgnoringCase("resmî", "resmi"))
    }
}
