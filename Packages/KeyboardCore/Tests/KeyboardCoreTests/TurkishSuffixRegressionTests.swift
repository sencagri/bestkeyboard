import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime
import KBMorphology

final class TurkishSuffixRegressionTests: XCTestCase {
    func testFutureBufferRecognizesCorrectFormsAndRejectsMissingY() throws {
        let morphology = MorphologyAutomaton(roots: [
            Root("yap", pos: .verb, lexCost: 4),
            Root("oku", pos: .verb, lexCost: 4),
            Root("gel", pos: .verb, lexCost: 4)
        ])
        for (index, valid, invalid) in [(0, "yapamayacak", "yapamaacak"),
                                       (1, "okuyacak", "okuacak"),
                                       (2, "gelmeyecek", "gelmeecek")] {
            let forms = Set(try morphology.generate(rootIndex: index, maxSuffixes: 2).map(\.surface))
            XCTAssertTrue(forms.contains(valid), valid)
            XCTAssertFalse(forms.contains(invalid), invalid)
        }
    }

    func testProductionFutureAndAttachedSuffixSurviveSpace() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for phrase in ["yapamayacakmışız", "bahsedemeyecekmişiz", "ankara’daymışız", "ankara'daymışız", "2026’daymışız"] {
            for offset in [-0.2, 0.0, 0.2] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                func type(_ word: String) {
                    for ch in word {
                        guard let index = layout.keyIndex(for: ch) else {
                            c.insertSymbol(ch, into: doc); continue
                        }
                        let key = layout.keys[index]
                        c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                                  y: key.center.y + offset * key.height)), into: doc)
                    }
                }
                type(phrase)
                c.space(into: doc)
                XCTAssertEqual(doc.text, phrase + " ", "offset=\(offset)")
                // Protection must end at the word boundary; genuine typos still correct.
                type("geliyprum")
                c.space(into: doc)
                XCTAssertEqual(doc.text, phrase + " geliyorum ")
            }
        }
    }
}

extension TurkishSuffixRegressionTests {
    func testNegativeEvidentialAndVowelFinalPersonParadigms() throws {
        let morphology = MorphologyAutomaton(roots: [Root("gel", pos: .verb, lexCost: 4)])
        let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 3).map(\.surface))
        for word in ["gelmemiş", "gelmemişsiniz", "gelmeliyim", "gelmeliyiz", "geliyorsunuz"] {
            XCTAssertTrue(forms.contains(word), word)
        }
        for word in ["gelmeliim", "gelmeliiz", "gelmemişsinizsiniz"] {
            XCTAssertFalse(forms.contains(word), word)
        }
    }

    func testInflectedNominalCopulasWithoutRepeatingCase() throws {
        let morphology = MorphologyAutomaton(roots: [Root("ev", pos: .noun, lexCost: 4)])
        let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 3).map(\.surface))
        for word in ["evdeymiş", "evdeymişsiniz", "evdeydim", "evimmiş", "evindeydi"] {
            XCTAssertTrue(forms.contains(word), word)
        }
        for word in ["evdeimiş", "evdeidi", "evdedeydi"] {
            XCTAssertFalse(forms.contains(word), word)
        }
        XCTAssertEqual(Set(TurkishMorphotactics.suffixes.map(\.id)).count, TurkishMorphotactics.suffixes.count)
    }
}

extension TurkishSuffixRegressionTests {
    func testPassiveCoreTensesAndCircumflexVowelBuffers() throws {
        let morphology = MorphologyAutomaton(roots: [Root("yaz", pos: .verb, lexCost: 4), Root("zekâ", pos: .noun, lexCost: 4)])
        let passive = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 4).map(\.surface))
        for word in ["yazılıyor", "yazılmadı", "yazılmamış", "yazılmış", "yazılacak"] {
            XCTAssertTrue(passive.contains(word), word)
        }
        XCTAssertFalse(passive.contains("yazılılmış"))
        let noun = Set(try morphology.generate(rootIndex: 1, maxSuffixes: 1).map(\.surface))
        XCTAssertTrue(noun.contains("zekâya"))
        XCTAssertFalse(noun.contains("zekâa"))
    }
}

extension TurkishSuffixRegressionTests {
    func testAbilityAndNegativeAoristHaveSeparatePersonParadigms() throws {
        let morphology = MorphologyAutomaton(roots: [Root("yap", pos: .verb, lexCost: 4, aoristClass: .ar)])
        let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 4).map(\.surface))
        for word in ["yapabilirim", "yapabilirseniz", "yapamam", "yapamayız", "yapamazsınız", "yapamıyorum", "yapmam", "yapmayız", "yapmazsınız"] {
            XCTAssertTrue(forms.contains(word), word)
        }
        for word in ["yapabilar", "yapabilabilir", "yapmazım", "yapamazım", "yapmazız"] {
            XCTAssertFalse(forms.contains(word), word)
        }
        XCTAssertEqual(Set(TurkishMorphotactics.suffixes.map(\.id)).count, TurkishMorphotactics.suffixes.count)
    }
}

extension TurkishSuffixRegressionTests {
    func testDroppedVowelHarmonyCombinedAlternationAndLexicalSeedMetadata() throws {
        let morphology = MorphologyAutomaton(roots: [
            Root("vakit", pos: .noun, lexCost: 4, dropsVowel: true),
            Root("kayıp", pos: .noun, lexCost: 4, finalAlternation: .pToB, dropsVowel: true),
            Root("yaz", pos: .verb, lexCost: 4, aoristClass: .ar)
        ])
        let first = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 1).map(\.surface))
        XCTAssertTrue(first.contains("vakti")); XCTAssertFalse(first.contains("vaktı"))
        let second = Set(try morphology.generate(rootIndex: 1, maxSuffixes: 1).map(\.surface))
        XCTAssertTrue(second.contains("kaybı")); XCTAssertFalse(second.contains("kaypı"))
        XCTAssertFalse(second.contains("kayıbı"))
        let third = Set(try morphology.generate(rootIndex: 2, maxSuffixes: 1).map(\.surface))
        XCTAssertTrue(third.contains("yazar")); XCTAssertFalse(third.contains("yazır"))
    }
}
