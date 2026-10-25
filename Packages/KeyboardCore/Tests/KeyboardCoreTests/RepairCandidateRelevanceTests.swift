import XCTest
import KBAssembly
import KBDecoder
import KBGeometry
import KBLexicon
import KBMorphology
import KBSpatial
@testable import KBRuntime

final class RepairCandidateRelevanceTests: XCTestCase {
    private let layout = TurkishQ.layout()
    private func type(_ word: String, into c: inout InputCoordinator, doc: FakeDocument, offset: Double = 0) throws {
        for ch in word {
            let keyCharacter = Character(String(ch).lowercased(with: Locale(identifier: "tr_TR")))
            let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: keyCharacter))]
            let touch = TouchSample(down: .init(x: key.center.x + offset * key.width,
                                               y: key.center.y + offset * key.height))
            if ch.isUppercase {
                c.insertUppercaseLetter(keyCharacter, uppercase: String(ch), touch: touch, into: doc)
            } else {
                c.insertLetter(ch, touch: touch, into: doc)
            }
        }
    }

    func testDuplicateRepairDoesNotGrowUnsupportedSpareInflections() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected, rejected) in [
            ("gelemeyeceğimm", "gelemeyeceğim", "gelemeyeceğimim"),
            ("geleceğimm", "geleceğim", "geleceğimim"),
            ("yapacağımm", "yapacağım", "yapacağımım"),
            ("öğretmenimm", "öğretmenim", "öğretmenimim"),
            ("üşütmeyeesin", "üşütmeyesin", "üşütmeyenesin"),
            ("hhatırlatıcıları", "hatırlatıcıları", "hatırlatışçıları"),
            ("markettten", "marketten", "marketsten")
        ] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                try type(input, into: &c, doc: doc, offset: offset)
                let offers = c.suggestionSurfaces()
                XCTAssertTrue(offers.contains(expected), "\(input): \(offers)")
                XCTAssertFalse(offers.contains(rejected), "\(input): \(offers)")
                XCTAssertEqual(offers.first, input)
            }
        }
        var c = InputCoordinator(layout: layout)
        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        let doc = FakeDocument()
        try type("başlatt", into: &c, doc: doc)
        XCTAssertTrue(c.suggestionSurfaces().contains("başlattı"))
        XCTAssertTrue(c.suggestionSurfaces().contains("başlat"))
    }

    func testDuplicateRepairKeepsNearbyGeneratedPossessiveAlternative() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        XCTAssertFalse(pack.literalChannel.hasListedSurface("randevunuzu"))
        // These offsets already expose randevunuzu in the baseline beam.
        // At +0.18 it was absent before this presentation filter.
        for offset in [-0.18, 0.0] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type("randevvumuzu", into: &c, doc: doc, offset: offset)
            XCTAssertTrue(c.suggestionSurfaces().contains("randevumuzu"))
            XCTAssertTrue(c.suggestionSurfaces().contains("randevunuzu"))
        }
    }

    func testLongNegativeDuplicateRemainsAvailableAcrossTouchOffsets() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let input = "yetkilendirilmemmiş", expected = "yetkilendirilmemiş"
        XCTAssertTrue(pack.literalChannel.score(input).isInVocabulary)
        XCTAssertTrue(pack.literalChannel.score(expected).isInVocabulary)
        XCTAssertFalse(pack.literalChannel.hasListedSurface(input))
        XCTAssertFalse(pack.literalChannel.hasListedSurface(expected))
        XCTAssertLessThan(pack.literalChannel.score(expected).lexCost,
                          pack.literalChannel.score(input).lexCost)
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc, offset: offset)
            XCTAssertEqual(Array(c.suggestionSurfaces().prefix(2)), [input, expected])
            c.newline(into: doc)
            XCTAssertEqual(doc.text, input + "\n", "Recognized literal stays intact")
            c.backspaceTap(into: doc)
            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == expected })
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertEqual(doc.text, expected + " ")
            XCTAssertTrue(c.personal.entries.isEmpty)
        }
    }

    func testDuplicateAlternativeQualityAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_DUPLICATE_ALTERNATIVE_AUDIT"] else {
            throw XCTSkip("Set KB_DUPLICATE_ALTERNATIVE_AUDIT to inspect spare suggestions")
        }
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: Any]] = []
        for input in ["gelemeyeceğimm", "geleceğimm", "yapacağımm", "üşütmeyeesin",
                      "başlatt", "kannı", "annemmi", "geleceğinimm", "öğretmenimm"] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                try type(input, into: &c, doc: doc, offset: offset)
                let candidates: [[String: Any]] = c.candidates(topK: 12).map {
                    ["word": $0.word, "decode_cost": $0.cost,
                     "lexical_cost": pack.literalChannel.score($0.word).lexCost,
                     "listed": pack.literalChannel.hasListedSurface($0.word),
                     "duplicate_repair": SuggestionPresenter.removesDuplicate($0.word, from: input)]
                }
                rows.append(["input": input, "offset": offset,
                             "offers": c.suggestionSurfaces(), "candidates": candidates])
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    func testBoundaryRepairRejectsMultiEditGeneratedSpareWords() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected, rejected) in [("helezkonuşak", "hele konuşak", "helezonmuşsak"),
                                             ("seniözledim", "seni özledim", "senizleydim"),
                                             ("senibözledim", "seni özledim", "senizleydim")] {
            XCTAssertFalse(pack.literalChannel.hasListedSurface(rejected), rejected)
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                try type(input, into: &c, doc: doc, offset: offset)
                for limit in [3, 5] {
                    let offers = c.suggestionSurfaces(limit: limit)
                    XCTAssertEqual(offers.first, input)
                    XCTAssertTrue(offers.contains(expected), "\(input): \(offers)")
                    XCTAssertFalse(offers.contains(rejected), "\(input): \(offers)")
                }
            }
        }
    }

    func testBoundaryRepairRejectsDistantListedSpareWords() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected, rejected) in [("börtüböcek", "börtü böcek", "görünmek"),
                                             ("börtübböcek", "börtü böcek", "görünmek"),
                                             ("börtüzböcek", "börtü böcek", "görüşmek"),
                                             ("parılcparıl", "parıl parıl", "şarkıcıları")] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                try type(input, into: &c, doc: doc, offset: offset)
                for limit in [3, 5] {
                    let offers = c.suggestionSurfaces(limit: limit)
                    XCTAssertEqual(offers.first, input)
                    XCTAssertTrue(offers.contains(expected), "\(input): \(offers)")
                    XCTAssertFalse(offers.contains(rejected), "\(input): \(offers)")
                }
            }
        }
    }

    func testMissingSpaceDoesNotOfferUnrelatedGeneratedInflection() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for input in ["senibseviyorum", "seniseviyorum"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc)
            for limit in [3, 5] {
                let offers = c.suggestionSurfaces(limit: limit)
                XCTAssertEqual(offers.first, input)
                XCTAssertTrue(offers.contains("seni seviyorum"))
                XCTAssertFalse(offers.contains("webinarcıydım"), "Unrelated inflection: \(offers)")
            }
            c.space(into: doc)
            XCTAssertEqual(doc.text, input + " ")
        }
    }

    func testNearbyGeneratedCandidateRemainsAvailableAlongsideRepair() throws {
        let forms = try TestLexicon.formTrie(["ev": 500, "dem": 500])
        let lexicon = LexiconSet(formTrie: forms, morphology: MorphologyAutomaton(roots: [Root("ev", pos: .noun, lexCost: 1)]))
        let decoder = Decoder(layout: layout, spatial: SpatialModel(layout: layout), lexicon: lexicon, beamWidth: 128)
        var c = InputCoordinator(layout: layout)
        c.setEngine(.init(decoder: decoder, literalChannel: LiteralChannel(vocabulary: lexicon, charModel: nil)))
        let doc = FakeDocument()
        try type("evdem", into: &c, doc: doc)
        XCTAssertTrue(c.boundaryRepairs().contains("ev dem"))
        let generated = c.shownCandidates().filter { lexicon.sources[Int($0.source)].formTrie == nil }
        XCTAssertFalse(generated.isEmpty, "Control must exercise a generated candidate")
        let offers = c.suggestionSurfaces(limit: 5)
        XCTAssertTrue(offers.contains("ev dem"))
        XCTAssertTrue(generated.contains { offers.contains($0.word) }, "Nearby inflections must remain: \(generated.map(\.word)), \(offers)")
    }
    func testSingleBoundaryRepairPrecedesMoreDistantDictionaryWord() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected) in [("subiç", "su iç"), ("logbaç", "log aç"), ("sqlbaç", "sql aç")] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc)
            for limit in [3, 5] {
                let offers = c.suggestions(limit: limit)
                XCTAssertEqual(offers.dropFirst().first?.surface, expected, "\(input): \(offers.map(\.surface))")
            }
            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == expected })
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertEqual(doc.text, expected + " ")
            XCTAssertFalse(c.personal.isAdmitted(input))
        }
    }

    func testOneLetterAndAdjacentSwapDictionaryCorrectionsRetainPriority() throws {
        for (input, expected, left, right) in [("evdem", "evden", "ev", "dem"), ("kalme", "kalem", "kal", "me")] {
            var c = try TestLexicon.coordinator([left: 500, right: 500, expected: 8000], layout: layout)
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc)
            XCTAssertTrue(c.boundaryRepairs().contains(left + " " + right))
            XCTAssertEqual(c.suggestionSurfaces().dropFirst().first, expected)
        }
    }

    func testDuplicateLetterCorrectionSurvivesCompetingBoundaryRepairs() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, target) in [("buluşallım", "buluşalım"), ("başvurummun", "başvurumun"),
                                ("saygılarımmla", "saygılarımla"), ("eczannelerden", "eczanelerden"),
                                ("bağlantısınnı", "bağlantısını"), ("randevummuz", "randevumuz"),
                                ("otobüstteyim", "otobüsteyim"), ("alışverişşe", "alışverişe")] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc)
            print("DUPLICATE CANDIDATES", input, c.candidates(topK: 8).map(\.word), "shown", c.shownCandidates().map(\.word))
            let offers = c.suggestions()
            XCTAssertTrue(offers.contains { $0.surface == target }, "\(input): \(offers.map(\.surface))")
            for offer in offers where offer.surface.contains(" ") {
                let parts = offer.surface.split(separator: " ")
                XCTAssertEqual(parts.joined(), input)
                XCTAssertEqual(parts.first?.last, parts.last?.first,
                               "Keep only a split at the duplicated boundary: \(input)")
            }
            if let pick = offers.first(where: { $0.surface == target }) {
                try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                XCTAssertEqual(doc.text, target + " ")
                XCTAssertFalse(c.personal.isAdmitted(input))
            }
        }
    }

    func testShiftedDuplicateTargetRemainsSelectable() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, target) in [("başvuruumun", "başvurumun"), ("çocuklarımızzı", "çocuklarımızı")] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc, offset: -0.18)
            print("SHIFTED DUPLICATE", input, c.candidates(topK: 12).map { "\($0.word):\($0.cost)" }, "shown", c.shownCandidates().map(\.word))
            let pick = c.suggestions().first { $0.surface == target }
            XCTAssertNotNil(pick, "\(input): \(c.suggestionSurfaces())")
            if let pick {
                try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                XCTAssertEqual(doc.text, target + " ")
            }
        }
    }

    func testDuplicateSplitLexicalEvidenceAudit() throws {
        guard ProcessInfo.processInfo.environment["KB_DUPLICATE_SPLIT_AUDIT"] != nil else {
            throw XCTSkip("Set KB_DUPLICATE_SPLIT_AUDIT")
        }
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for input in ["gereğininn", "başvurunuzzun", "annemmi", "buluşallım", "başvurummun",
                      "saygılarımmla", "eczannelerden", "bağlantısınnı", "randevummuz",
                      "otobüstteyim", "alışverişşe", "bellimi", "hissettimmi", "seniseviyorum",
                      "babammı", "dedemmi", "tamammı", "benimmi", "bizimmi", "güzellaf", "çokkolay"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            try type(input, into: &c, doc: FakeDocument())
            for repair in c.boundaryRepairs() {
                print("SPLIT_EVIDENCE", input, repair, repair.split(separator: " ").map {
                    "\($0):\(pack.literalChannel.score(String($0)).lexCost)"
                })
            }
            print("SPLIT_OFFERS", input, c.suggestionSurfaces())
            print("DUPLICATE_LEXICAL", input, c.shownCandidates().filter { SuggestionPresenter.removesDuplicate($0.word, from: input) }.map { "\($0.word):\(pack.literalChannel.score($0.word).lexCost)" })
        }
    }

    func testDuplicateRepairKeepsOnlyMatchingMissingSpaceAmbiguity() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, target, phrase) in [("annemmi", "annemi", "annem mi"),
                                        ("gereğininn", "gereğinin", ""),
                                        ("başvurunuzzun", "başvurunuzun", ""),
                                        ("saygılarımmla", "saygılarımla", ""),
                                        ("eczannelerden", "eczanelerden", ""),
                                        ("bağlantısınnı", "bağlantısını", ""),
                                        ("randevummuz", "randevumuz", ""),
                                        ("alışverişşe", "alışverişe", ""),
                                        ("babammı", "babamı", "babam mı"),
                                        ("dedemmi", "dedemi", "dedem mi"),
                                        ("benimmi", "benimi", "benim mi"),
                                        ("bizimmi", "bizimi", "bizim mi")] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                try type(input, into: &c, doc: doc, offset: offset)
                for limit in [3, 5] {
                    let offers = c.suggestions(limit: limit)
                    XCTAssertTrue(offers.contains { $0.surface == target }, "\(input), \(offset)")
                    let splits = offers.filter { $0.surface.contains(" ") }.map(\.surface)
                    if phrase.isEmpty {
                        XCTAssertTrue(splits.isEmpty, "\(input), \(offset): \(splits)")
                    } else {
                        XCTAssertTrue(splits.contains(phrase), "\(input), \(offset): \(splits)")
                    }
                }
                if !phrase.isEmpty {
                    let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
                    try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    XCTAssertEqual(doc.text, phrase + " ")
                }
            }
        }
    }

    func testQuestionParticleSplitSurvivesGeneratedWholeWord() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for input in ["bellimi", "hazırmı", "güzelmi", "uygunmu", "Bellimi", "BELLİMİ"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            try type(input, into: &c, doc: doc)
            let phrase = String(input.dropLast(2)) + " " + input.suffix(2)
            XCTAssertTrue(c.suggestionSurfaces().contains(phrase), input)
            c.space(into: doc)
            XCTAssertEqual(doc.text, input + " ", "A phrase requires explicit selection")
            c.backspaceTap(into: doc)
            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertEqual(doc.text, phrase + " ")
        }
    }

    func testQuestionParticleOffersDoNotSplitListedOrPersonalWholeWords() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["evimi", "kalemi", "belli", "bunda"] {
            XCTAssertTrue(WordBoundaryRepair.suggestions(for: word, channel: pack.literalChannel).isEmpty, word)
        }
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: "bellimi", channel: pack.literalChannel,
            personalCost: { $0 == "bellimi" ? 1 : nil }).isEmpty)
    }

    func testListedJoinedQuestionsOfferExplicitSpacedForms() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        for (input, phrase) in [("tamammı", "tamam mı"), ("varmı", "var mı"),
                                ("yokmu", "yok mu"), ("öylemi", "öyle mi")] {
            for form in [input, input.prefix(1).uppercased(with: locale) + input.dropFirst(), input.uppercased(with: locale)] {
                for offset in [-0.18, 0.0, 0.18] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel, expansions: pack.expansions))
                    let doc = FakeDocument()
                    try type(form, into: &c, doc: doc, offset: offset)
                    XCTAssertTrue(c.suggestions().contains { $0.surface == phrase }, form)
                    c.space(into: doc)
                    XCTAssertEqual(doc.text, form + " ", "Keep the user's literal until an explicit choice")
                    c.backspaceTap(into: doc)
                    guard let pick = c.suggestions().first(where: { $0.surface == phrase }) else {
                        XCTFail("Missing explicit question repair: \(form)"); continue
                    }
                    try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    let expected = String(form.dropLast(2)) + " " + form.suffix(2)
                    XCTAssertEqual(doc.text, expected + " ")
                    c.backspaceTap(into: doc)
                    XCTAssertEqual(doc.text, expected)
                }
            }
        }
    }

}
