import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBFoundation
@testable import KBRuntime

final class WholeWordSuggestionTests: XCTestCase {
    func testCircumflexRepairsSpanSymbolBoundariesAndPreserveOriginal() throws {
        let layout = TurkishQ.layout()
        let pack = RecordingTestSupport.loaded
        for (root, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            for separator in [""] + "zxcvbnmçö".map(String.init) {
                for casing in 0..<3 {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    c.ingestPersonal(tokens: [root, root, root])
                    let raw = form + separator + "aç"
                    let word = casing == 2 ? TurkishText.uppercased(raw) : casing == 1 ? TurkishText.uppercased(String(raw.prefix(1))) + raw.dropFirst() : raw
                    let doc = FakeDocument()
                    doc.hostRewrites(to: "önce ")
                    for ch in word {
                        let lower = TurkishText.lowercased(String(ch)).first!
                        if let index = layout.keyIndex(for: lower) {
                            c.insertUppercaseLetter(lower, uppercase: String(ch), touch: .init(down: layout.keys[index].center), into: doc)
                        } else { c.insertSymbol(ch, into: doc) }
                    }
                    let before = "önce " + word
                    XCTAssertEqual(doc.text, before)
                    let offer = try XCTUnwrap(c.wholeWordSuggestion(before: before, after: " sonra", selected: nil))
                    let expected = TurkishText.applying(TurkishText.casing(of: word), to: form + " aç")
                    XCTAssertEqual(offer.surfaces.first, word)
                    XCTAssertTrue(offer.surfaces.contains(expected), word)
                    XCTAssertTrue(offer.matches(before: before, after: " sonra", selected: nil))
                    XCTAssertFalse(offer.matches(before: before + "x", after: " sonra", selected: nil))
                    XCTAssertFalse(offer.matches(before: before, after: "sonra", selected: nil))
                    XCTAssertFalse(offer.matches(before: before, after: " sonra", selected: word))
                    // Merely offering a repair cannot modify or learn it.
                    XCTAssertEqual(doc.text, before)
                    XCTAssertEqual(c.personal.admitted, [root])
                }
            }
        }
    }

    func testProperApostropheDuplicateOffersPreserveSpellingAndProtection() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        for (input, expected) in [("Arapsuyu'nnda", "Arapsuyu'nda"),
                                  ("Arappsuyu’nda", "Arapsuyu’nda"),
                                  ("ARAPSUYU’NNDA", "ARAPSUYU’NDA"),
                                  ("Ankara'nnın", "Ankara'nın"),
                                  ("İstanbul'ddan", "İstanbul'dan"),
                                  ("Çanakkale'dde", "Çanakkale'de")] {
            let before = "önce (" + input
            let offer = try XCTUnwrap(c.wholeWordSuggestion(before: before, after: ") sonra", selected: nil), input)
            XCTAssertEqual(offer.original, input)
            XCTAssertEqual(offer.surfaces.first, input)
            XCTAssertTrue(offer.surfaces.contains(expected), input)
            XCTAssertEqual(offer.replacement(for: expected), expected)
            XCTAssertFalse(offer.matches(before: before + "x", after: ") sonra", selected: nil))
            XCTAssertTrue(CorrectionContext(display: input, before: before).protectsLiteral)
        }
        for input in ["Çanakkale'de", "Arapsuyu'nda", "qzx'nnda", "kalem'dde",
                      "https://Arapsuyu'nnda", "x@Arapsuyu'nnda", "Arapsuyu''nnda",
                      "Arapsuyu'nndax", "Arapsuyu'", "Arapsuyu'12"] {
            XCTAssertNil(c.wholeWordSuggestion(before: input, after: "", selected: nil), input)
        }
        XCTAssertNil(c.wholeWordSuggestion(before: "Arapsuyu'nnda", after: ".com", selected: nil))
        XCTAssertNil(c.wholeWordSuggestion(before: "Arapsuyu'nnda", after: "", selected: "n"))
        XCTAssertTrue(c.personal.entries.isEmpty)
        c.fieldIsSecure = true
        XCTAssertNil(c.wholeWordSuggestion(before: "Arapsuyu'nnda", after: "", selected: nil))
    }

    func testStraySpaceJoinRequiresWholeWordEvidenceAndPreservesRealPhrases() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        for (input, expected) in [("gele cek", "gelecek"), ("Gele cek", "Gelecek"),
                                  ("GELE CEK", "GELECEK"), ("bilgisa yar", "bilgisayar")] {
            let before = "önce (" + input
            let offer = try XCTUnwrap(c.wholeWordSuggestion(before: before, after: ") sonra", selected: nil), input)
            XCTAssertEqual(offer.original, input)
            XCTAssertEqual(offer.surfaces, [input, expected])
            XCTAssertEqual(offer.replacement(for: expected), expected)
            XCTAssertFalse(offer.matches(before: before + "x", after: ") sonra", selected: nil))
        }
        for input in ["gelecek misin", "ev de", "bir şey", "bu gün", "gele\ncek", "gele  cek",
                      "gele\tcek", "gele. cek", "https://gele cek", "x@gele cek", "gele Cek", "qzx vwx"] {
            XCTAssertNil(c.wholeWordSuggestion(before: input, after: "", selected: nil), input)
        }
        XCTAssertNil(c.wholeWordSuggestion(before: "gele cek", after: ".com", selected: nil))
        XCTAssertNil(c.wholeWordSuggestion(before: "gele cek", after: "", selected: "e"))
        XCTAssertTrue(c.personal.entries.isEmpty)
        c.fieldIsSecure = true
        XCTAssertNil(c.wholeWordSuggestion(before: "gele cek", after: "", selected: nil))
    }

    func testRepeatedWholeWordConfirmationIsOneObservation() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        for word in ["qrmâvi", "QRMÂVİ", "qrmâvi".decomposedStringWithCanonicalMapping, "qrmâvi"] {
            c.confirmWholeWord(word)
        }
        XCTAssertEqual(c.personal.entries["qrmâvi"]?.points, 1)
        XCTAssertFalse(c.personal.isAdmitted("qrmâvi"))
    }

    func testUnsafeContextsAndKnownWords() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        for before in [nil, "", "normal", "https://qrmâvi", "a@qrmâvi", "qrmâvi/", "qrmâvi ", String(repeating: "â", count: 100)] as [String?] {
            XCTAssertNil(c.wholeWordSuggestion(before: before, after: "", selected: nil))
        }
        for after in ["a", "@host", "/path", "_x", "1"] {
            XCTAssertNil(c.wholeWordSuggestion(before: "qrmâvi", after: after, selected: nil))
        }
        XCTAssertNil(c.wholeWordSuggestion(before: "qrmâvi", after: "", selected: "a"))
        c.ingestPersonal(tokens: ["qrmâvi", "qrmâvi", "qrmâvi"])
        XCTAssertEqual(c.wholeWordSuggestion(before: "qrmâvi", after: "", selected: nil)?.surfaces, ["qrmâvi"])
        c.fieldIsSecure = true
        XCTAssertNil(c.wholeWordSuggestion(before: "qrmâvi", after: "", selected: nil))
        c.confirmWholeWord("qrmîlo")
        XCTAssertFalse(c.personal.admitted.contains("qrmîlo"))
    }
    func testWrappedCircumflexOffersAndTechnicalRightTails() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        c.ingestPersonal(tokens: ["qrmâvi", "qrmâvi", "qrmâvi"])
        let word = "qrmâvidenbaç"
        for opening in ["", "(", "[", "{", "\"", "'", "“", "‘", "«", "(\"", "（"] {
            for closing in ["", ")", "]", "}", "\"", "'", "”", "’", "»", "). sonra", "… sonra", "）"] {
                let before = "önce " + opening + word
                let offer = c.wholeWordSuggestion(before: before, after: closing, selected: nil)
                XCTAssertEqual(offer?.original, word, "opening=\(opening), closing=\(closing)")
                XCTAssertTrue(offer?.surfaces.contains("qrmâviden aç") == true)
                XCTAssertEqual(offer?.replacement(for: "qrmâviden aç"), "qrmâviden aç" + (closing.isEmpty ? " " : ""))
                XCTAssertNil(offer?.replacement(for: "not offered"))
            }
        }
        for tail in [".com", ".txt", ":443", "?q=1", "#section", "’dan", "'dan", "\"@host.com", ")suffix"] {
            XCTAssertNil(c.wholeWordSuggestion(before: word, after: tail, selected: nil), tail)
        }
    }

    func testWholeWordBoundaryScanIsBoundedAndDoesNotPeelTechnicalPrefixes() throws {
        var c = InputCoordinator(layout: TurkishQ.layout())
        let pack = RecordingTestSupport.loaded
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        for prefix in ["https://", "a@", "file/", "x.", "#", "_", "`", String(repeating: "(", count: 9), String(repeating: "a", count: 10000)] {
            XCTAssertNil(c.wholeWordSuggestion(before: prefix + "qrmâvi", after: "", selected: nil), String(prefix.prefix(20)))
        }
        for tail in [" sonra", "\nsonra", ") sonra", "\" sonra"] {
            let offer = try XCTUnwrap(c.wholeWordSuggestion(before: "(qrmâvi", after: tail, selected: nil))
            XCTAssertEqual(offer.replacement(for: "qrmâvi"), "qrmâvi")
            XCTAssertEqual("(" + (offer.replacement(for: "qrmâvi") ?? "") + tail, "(qrmâvi" + tail)
        }
    }

    func testDecomposedUppercaseCircumflexKeepsPersonalInflectionAndRepair() throws {
        let pack = RecordingTestSupport.loaded
        for (root, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            var c = InputCoordinator(layout: TurkishQ.layout())
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            c.ingestPersonal(tokens: [root, root, root])
            for value in [form, form.decomposedStringWithCanonicalMapping,
                          TurkishText.uppercased(form), TurkishText.uppercased(form).decomposedStringWithCanonicalMapping] {
                XCTAssertTrue(c.isKnownPersonalInflection(value), value)
                let input = value + TurkishText.applying(TurkishText.casing(of: value), to: "baç")
                let offer = try XCTUnwrap(c.wholeWordSuggestion(before: input, after: "", selected: nil))
                XCTAssertEqual(Array(offer.original.utf8), Array(input.utf8))
                XCTAssertTrue(offer.surfaces.contains { TurkishText.key($0) == form + " aç" }, value)
            }
        }
    }

}
