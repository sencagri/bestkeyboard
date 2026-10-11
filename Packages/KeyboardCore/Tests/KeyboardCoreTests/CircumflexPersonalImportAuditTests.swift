import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBSessions
@testable import KBRuntime

final class CircumflexPersonalImportAuditTests: XCTestCase {
    func testCircumflexImportDoesNotLearnFragments() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (word, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            for variant in [word, word.uppercased(with: Locale(identifier: "tr_TR")), word.decomposedStringWithCanonicalMapping, word.uppercased(with: Locale(identifier: "tr_TR")).decomposedStringWithCanonicalMapping] {
                let text = Array(repeating: variant, count: 3).joined(separator: " ")
                let tokens = PersonalLexicon.importTokens(from: text, layout: layout)
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                _ = c.ingestPersonal(tokens: tokens)
                XCTAssertEqual(tokens, [word, word, word])
                XCTAssertEqual(c.personal.admitted, [word], "Must not learn fragments: \(tokens)")
                XCTAssertTrue(c.isKnownPersonalInflection(form), form)
            }
        }
    }
    func testImportKeepsSeparatorsAndRecordingPromptContract() {
        let layout = TurkishQ.layout()
        let text = "Wi-Fi Caddesi'ne HTTP/2 QRmenü"
        XCTAssertEqual(PersonalLexicon.importTokens(from: text, layout: layout),
                       ["wi", "fi", "caddesi", "ne", "http", "qrmenü"])
        XCTAssertEqual(PersonalLexicon.importTokens(from: "KÂR RESMÎ SÜKÛN", layout: layout),
                       ["kâr", "resmî", "sükûn"])
        XCTAssertTrue(PersonalLexicon.importTokens(from: "123 / @ 👩🏽‍💻", layout: layout).isEmpty)
        XCTAssertEqual(PromptTokenizer(layout: layout).tokens(of: "kâr"), ["k", "r"],
                       "Recording alignment must still follow symbol command boundaries")
    }

}
