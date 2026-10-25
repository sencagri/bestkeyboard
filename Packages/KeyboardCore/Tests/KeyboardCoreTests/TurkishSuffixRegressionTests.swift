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


extension TurkishSuffixRegressionTests {
    func testHastiveCompoundsUseHarmonyBufferAndAuxiliaryInflection() throws {
        let roots = ["gel", "bak", "al", "oku", "gör"]
        let morphology = MorphologyAutomaton(roots: roots.map { Root($0, pos: .verb, lexCost: 4) })
        let stems = ["geliver", "bakıver", "alıver", "okuyuver", "görüver"]
        for (index, stem) in stems.enumerated() {
            let forms = Set(try morphology.generate(rootIndex: index, maxSuffixes: 3).map(\.surface))
            for tail in ["", "di", "iyor", "ir", "me", "mek", "ince", "mişsiniz"] {
                XCTAssertTrue(forms.contains(stem + tail), stem + tail)
            }
            for invalid in [stem + "er", stem + "iver", stem + "mişsinizsiniz"] {
                XCTAssertFalse(forms.contains(invalid), invalid)
            }
            if index == 3 { XCTAssertFalse(forms.contains("okuver")); XCTAssertFalse(forms.contains("okuıver")) }
        }
    }
}


extension TurkishSuffixRegressionTests {
    func testProductionUpdateVerbFamilyIsRecognized() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["güncelleştir", "güncelleştirmek", "güncelleştirmeyi", "güncelleştirmeleri",
                     "güncelleştiriyorum", "güncelleştirdim", "güncelleştirecek", "güncelleştirilmiş",
                     "güncelleştirebilir", "güncelleştirir"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }
    func testDryerNounInflectionsAreRecognized() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for word in ["kurutucu", "kurutucudan", "kurutucuyu", "kurutucunun", "kurutucular", "kurutucularımızdan"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }

    func testRestoredCircumflexRootsPreserveInflections() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for word in ["fedakâr", "fedakârlardan", "adalî", "adalîye", "üçkâğıt", "üçkâğıdı",
                     "kâğıtlamak", "kâğıtlıyor", "rüzgârlanmak", "rüzgârlanıyor",
                     "helâlin", "arzuhâli", "mahkûku", "merkûpu"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
        for word in ["adalîa", "üçkâğıtı", "kâğıtlaıyor", "mahkûğu", "merkûbu"] {
            XCTAssertFalse(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }

    func testEverydayUnaccentedSpellingsRemainLiteral() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["fedakar", "helal", "rüzgar", "kağıtlamak", "resmi", "milli",
                     "helalin", "arzuhali", "ihtilalin", "istimlaki", "mahkuku", "merkupu", "mahkumiyetinin"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, "Unaccented inflection: \(word)")
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                        y: key.center.y + offset * key.height)), into: doc)
                }
                c.space(into: doc)
                XCTAssertEqual(doc.text, word + " ", "No forced circumflex: \(word), \(offset)")
            }
        }
        let isolated = MorphologyAutomaton(roots: [Root("helâl", pos: .noun, lexCost: 4, features: .inverseHarmony)])
        let forms = Set(try isolated.generate(rootIndex: 0, maxSuffixes: 1).map(\.surface))
        XCTAssertTrue(forms.contains("helâlin"))
        XCTAssertFalse(forms.contains("helâlın"))
    }

    func testUnaccentedLexicalRootsKeepTheirPronunciation() throws {
        let data = try XCTUnwrap(RecordingTestSupport.packSource.read(.turkish, .roots)).data
        let roots = try RootPack(data: data).roots
        // Inspect the actual lexical root, avoiding unrelated homographs or
        // listed forms that could hide a broken inflection rule.
        for (stem, valid, invalid) in [
            ("helal", "helalin", "helalın"),
            ("arzuhal", "arzuhali", "arzuhalı"),
            ("ihtilal", "ihtilalin", "ihtilalın"),
            ("istimlak", "istimlaki", "istimlakı"),
            ("mahkuk", "mahkuku", "mahkuğu"),
            ("merkup", "merkupu", "merkubu"),
            ("mahkumiyet", "mahkumiyeti", "mahkumiyedi")
        ] {
            let root = try XCTUnwrap(roots.first { String($0.surface) == stem && $0.pos == .noun })
            let morphology = MorphologyAutomaton(roots: [root])
            let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 1).map(\.surface))
            XCTAssertTrue(forms.contains(valid), valid)
            XCTAssertFalse(forms.contains(invalid), invalid)
        }
    }

    func testDesiderativeParticipleAndPossession() throws {
        for (stem, expected) in [("sarıl", "sarılasım"), ("gül", "gülesim"),
                                 ("uyu", "uyuyasım"), ("özle", "özleyesim")] {
            let morphology = MorphologyAutomaton(roots: [Root(stem, pos: .verb, lexCost: 4)])
            let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 2).map(\.surface))
            XCTAssertTrue(forms.contains(expected), expected)
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["sarılasım", "gülesim", "uyuyasım", "göresimiz", "gidesiniz",
                     "gelmeyesim", "görmeyesin", "sarılasımın"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "sarıılasım" {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                    y: key.center.y + offset * key.height)), into: doc)
            }
            XCTAssertTrue(c.suggestionSurfaces().contains("sarılasım"))
            c.space(into: doc)
            XCTAssertTrue(["sarıılasım ", "sarılasım "].contains(doc.text), doc.text)
            XCTAssertFalse(c.personal.isAdmitted("sarıılasım"))
        }
    }

    func testProductiveAgentiveDerivationAndNominalInflection() throws {
        for (stem, expected) in [("temizle", "temizleyici"), ("oku", "okuyucu"),
                                 ("yaz", "yazıcı"), ("sür", "sürücü"), ("gör", "görücü")] {
            let morphology = MorphologyAutomaton(roots: [Root(stem, pos: .verb, lexCost: 4)])
            let forms = Set(try morphology.generate(rootIndex: 0, maxSuffixes: 1).map(\.surface))
            XCTAssertTrue(forms.contains(expected), expected)
            XCTAssertFalse(forms.contains(stem + "çı"))
        }
        let causative = MorphologyAutomaton(roots: [Root("hatırla", pos: .verb, lexCost: 4, causativeClass: .t)])
        XCTAssertTrue(try causative.generate(rootIndex: 0, maxSuffixes: 2).contains { $0.surface == "hatırlatıcı" })
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["temizleyici", "temizleyiciyi", "temizleyicilerimiz", "temizleyicilerden", "temizleyicimizin"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }

    func testPlanningReminderNounAndInflectionsAreRecognized() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["hatırlatıcı", "hatırlatıcıları", "hatırlatıcımız", "hatırlatıcının", "hatırlatıcınıza"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "hhatırlatıcıları" {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                    y: key.center.y + offset * key.height)), into: doc)
            }
            XCTAssertTrue(c.suggestionSurfaces().contains("hatırlatıcıları"))
            c.space(into: doc)
            XCTAssertTrue(["hhatırlatıcıları ", "hatırlatıcıları "].contains(doc.text), doc.text)
        }
    }

    func testUnaccentedAdetPreservesBothHomographInflections() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let data = try XCTUnwrap(RecordingTestSupport.packSource.read(.turkish, .roots)).data
        let roots = try RootPack(data: data).roots.filter { String($0.surface) == "adet" && $0.pos == .noun }
        var forms = Set<String>()
        for root in roots {
            forms.formUnion(try MorphologyAutomaton(roots: [root]).generate(rootIndex: 0, maxSuffixes: 1).map(\.surface))
        }
        XCTAssertTrue(forms.contains("adeti"))
        XCTAssertTrue(forms.contains("adedi"))
        for word in ["adetini", "adetimiz", "adetinden", "adedini", "adedimiz", "adedinden"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in word {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: key.center), into: doc)
            }
            c.space(into: doc)
            XCTAssertEqual(doc.text, word + " ")
        }
    }

    func testUnaccentedCorrectionPrecedesCircumflexAlias() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected) in [("fedakkar", "fedakar"), ("ihtilallin", "ihtilalin"),
                                  ("mahkummiyetinin", "mahkumiyetinin")] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in input {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                        y: key.center.y + offset * key.height)), into: doc)
                }
                XCTAssertEqual(c.suggestionSurfaces().dropFirst().first, expected)
                XCTAssertEqual(c.suggestionSurfaces(limit: 2).dropFirst().first, expected)
            }
        }
    }

}
