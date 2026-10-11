import XCTest
import Foundation
import KBFoundation
import KBGeometry
@testable import KBRuntime

final class SelectionWhitespaceCasingTests: XCTestCase {
    func testSelectedCorrectionKeepsCasingAndBoundaryWhitespace() throws {
        let layout = TurkishQ.layout()
        let lexicon: [String: Double] = ["kalem": 500, "güzel": 500, "merhaba": 500, "dünya": 500]
        let edges = [("", ""), (" ", ""), ("", " "), (" ", " "), ("\t", "\t"),
                     ("\n", "\r\n"), ("\u{00a0}", "\u{202f}"), (" \t", "\n ")]
        let words = [("kalen", ["kalem", "Kalem", "KALEM"]),
                     ("guzel", ["güzel", "Güzel", "GÜZEL"]),
                     ("merhababdünya", ["merhaba dünya", "Merhaba dünya", "MERHABA DÜNYA"])]
        for (typed, corrected) in words {
            for casing in 0..<3 {
                let source = casing == 2 ? TurkishText.uppercased(typed) : casing == 1 ? TurkishText.uppercased(String(typed.prefix(1))) + typed.dropFirst() : typed
                for (leading, trailing) in edges {
                    var c = try TestLexicon.coordinator(lexicon, layout: layout)
                    let doc = FakeDocument()
                    let selected = leading + source + trailing
                    doc.hostRewrites(to: "önce|" + selected + "|sonra")
                    doc.hostSelects(selected)
                    XCTAssertNotNil(c.handleSelection(selected, into: doc))
                    let picked = try XCTUnwrap(c.suggestions().first { TurkishText.key($0.surface) == corrected[0] }, source)
                    // The extension uses this same casing projection for its
                    // history replacement witness; it must agree with the edit.
                    let projected = TurkishText.applying(TurkishText.casing(of: selected), to: picked.surface)
                    XCTAssertEqual(projected, corrected[casing], selected.debugDescription)
                    try c.perform(.suggestionPick(id: picked.id, surface: picked.surface, origin: picked.origin), touch: nil, into: doc)
                    XCTAssertEqual(doc.text, "önce|" + leading + corrected[casing] + trailing + "|sonra", selected.debugDescription)
                    XCTAssertNil(doc.selectedText)
                    XCTAssertEqual(c.calibration.sampleCount, 0)
                }
            }
        }
    }

    func testWhitespaceDoesNotChangeCasingClassification() {
        XCTAssertEqual(TurkishText.casing(of: " \tK \n"), .capitalized)
        XCTAssertEqual(TurkishText.casing(of: " Kalem \t"), .capitalized)
        XCTAssertEqual(TurkishText.casing(of: " KALEM "), .allCaps)
        XCTAssertEqual(TurkishText.casing(of: " \t\n"), .none)
    }
}
