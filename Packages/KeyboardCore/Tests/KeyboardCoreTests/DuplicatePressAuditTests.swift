import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Authored extra-key probes, separate from intentional expressive spelling.
final class DuplicatePressAuditTests: XCTestCase {
    func testGeneratedLiteralOffersFixedRootDuplicateWithoutAutomaticReplacement() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        XCTAssertTrue(pack.literalChannel.score("pıttır").isInVocabulary)
        XCTAssertFalse(pack.literalChannel.hasListedSurface("pıtır"))
        XCTAssertTrue(pack.literalChannel.hasFixedLexicalSurface("pıtır"))
        XCTAssertFalse(pack.literalChannel.hasFixedLexicalSurface("pıttır"))
        XCTAssertFalse(pack.literalChannel.hasFixedLexicalSurface("pıtırlar"))
        XCTAssertFalse(pack.literalChannel.hasFixedLexicalSurface("kalem"))
        XCTAssertFalse(pack.literalChannel.hasFixedLexicalSurface(""))
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "pıttır" {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                    y: key.center.y + offset * key.height)), into: doc)
            }
            XCTAssertEqual(Array(c.suggestionSurfaces().prefix(2)), ["pıttır", "pıtır"])
            c.space(into: doc)
            XCTAssertEqual(doc.text, "pıttır ", "The recognized literal remains protected")
            c.backspaceTap(into: doc)
            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == "pıtır" })
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin),
                          touch: nil, into: doc)
            XCTAssertEqual(doc.text, "pıtır ")
            XCTAssertTrue(c.personal.entries.isEmpty)
        }
    }

    func testExpressiveTripleLetterRunsRemainLiteral() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for word in ["çoook", "çooook", "evettt", "hayııır", "güzeeelll", "yaaa", "offf"] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: .init(
                        x: key.center.x + offset * key.width,
                        y: key.center.y + offset * key.height)), into: doc)
                }
                c.space(into: doc)
                XCTAssertEqual(doc.text, word + " ", "offset=\(offset)")
            }
        }
    }

    func testCompetingDuplicateCorrectionDoesNotChangeMeaningAutomatically() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, expected) in [("başşvurumun", "başvurumun"), ("başvuurumun", "başvurumun"),
                                  ("değerlendirrilmesini", "değerlendirilmesini"),
                                  ("çocuklarımızzı", "çocuklarımızı"), ("alışveriişe", "alışverişe"),
                                  ("ssevgilim", "sevgilim"), ("başvurunuzzun", "başvurunuzun"), ("dedemmi", "dedemi"),
                                  ("sarıılacağım", "sarılacağım"), ("sarrılacağım", "sarılacağım"),
                                  ("ssoluklan", "soluklan"), ("solukklan", "soluklan"),
                                  ("gardaşşım", "gardaşım"), ("garddaşım", "gardaşım"),
                                  ("gardaşıım", "gardaşım"), ("kkonuşak", "konuşak"),
                                  ("ggeliver", "geliver"), ("gelivver", "geliver"),
                                  ("napıyyosun", "napıyosun"), ("nnapıyosun", "napıyosun"),
                                  ("güncelleştirrmeyi", "güncelleştirmeyi"),
                                  ("ggüncelleştirmeyi", "güncelleştirmeyi"),
                                  ("kuurutucudan", "kurutucudan"), ("kurutucuudan", "kurutucudan"),
                                  ("fedakkar", "fedakar"), ("ihtilallin", "ihtilalin"),
                                  ("aanaokulundan", "anaokulundan"), ("aayakucuna", "ayakucuna"),
                                  ("yeryüüzlerinde", "yeryüzlerinde"), ("yeryüzleriinde", "yeryüzlerinde"),
                                  ("mademkii", "mademki"), ("hamdolsunn", "hamdolsun"),
                                  ("hhaydisene", "haydisene"), ("ayyol", "ayol"),
                                  ("biinaen", "binaen"), ("mmüteakiben", "müteakiben"),
                                  ("sürümlemmeyi", "sürümlemeyi"), ("doğrulayıcıının", "doğrulayıcının")] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in input {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: .init(
                        x: key.center.x + offset * key.width,
                        y: key.center.y + offset * key.height)), into: doc)
                }
                XCTAssertTrue(c.suggestionSurfaces().contains(expected),
                    "\(input), offset=\(offset), candidates=\(c.candidates(topK: 24))")
                c.space(into: doc)
                XCTAssertTrue([input + " ", expected + " "].contains(doc.text),
                              "\(input), offset=\(offset): \(doc.text)")
                if input == "ssevgilim" {
                    XCTAssertEqual(doc.text, expected + " ", "Unambiguous duplicate correction must still work")
                }
                XCTAssertFalse(c.personal.isAdmitted(input))
            }
        }
    }

    func testGeneratedInflectionStillOffersListedDuplicateAlternative() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        XCTAssertTrue(pack.literalChannel.score("markettin").isInVocabulary)
        XCTAssertFalse(pack.literalChannel.hasListedSurface("markettin"))
        XCTAssertTrue(pack.literalChannel.hasListedSurface("marketin"))
        for offset in [-0.18, 0.0, 0.18] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "markettin" {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: .init(
                    x: key.center.x + offset * key.width,
                    y: key.center.y + offset * key.height)), into: doc)
            }
            XCTAssertTrue(c.suggestionSurfaces().contains("marketin"), "offset=\(offset)")
            c.space(into: doc)
            XCTAssertEqual(doc.text, "markettin ", "Valid inflection must remain an explicit choice")
            XCTAssertTrue(c.personal.entries.isEmpty)
        }
    }

    func testExtraLettersAtEveryPosition() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_DUPLICATE_AUDIT"] else {
            throw XCTSkip("Set KB_DUPLICATE_AUDIT to export duplicate-key findings")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let defaultWords = ["sevgilim", "seviyorum", "özledim", "buluşalım", "sunucu", "mühendislik",
                     "veritabanı", "bağlantısını", "gardaş", "nörüyon", "uşağum", "geliyom",
                     "başvurumun", "değerlendirilmesini", "saygılarımla", "randevumuz",
                     "otobüsteyim", "eczanelerden", "çocuklarımızı", "alışverişe"]
        let requestedWords = ProcessInfo.processInfo.environment["KB_DUPLICATE_AUDIT_WORDS"]?
            .split(separator: ",").map(String.init)
        let words = requestedWords?.isEmpty == false ? requestedWords! : defaultWords
        var rows: [[String: String]] = []
        func run(_ input: String, expected: String, mode: String, position: Int) throws {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in input {
                    switch ch {
                    case " ": c.space(into: doc)
                    case "\n": c.newline(into: doc)
                    case "\u{8}": c.backspaceTap(into: doc)
                    default:
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                                  y: key.center.y + offset * key.height)), into: doc)
                    }
                }
                let offers = c.suggestionSurfaces()
                let report = c.space(into: doc)
                rows.append(["word": expected, "input": input, "mode": mode, "position": String(position),
                             "offset": String(offset), "actual": doc.text, "offers": offers.joined(separator: " | "),
                             "target_offered": String(offers.contains(expected)),
                             "exact": String(doc.text == expected + " "),
                             "delta": report.delta.map(String.init(describing:)) ?? "nil",
                             "personal": c.personal.entries.keys.sorted().joined(separator: " | ")])
            }
        }
        for word in words {
            let chars = Array(word)
            for i in chars.indices {
                let prefix = String(chars[...i]), suffix = String(chars.dropFirst(i + 1))
                try run(prefix + String(chars[i]) + suffix, expected: word, mode: "double", position: i)
                try run(prefix + String(chars[i]) + "\u{8}" + suffix, expected: word, mode: "double_undo", position: i)
                try run(prefix + String(chars[i]) + " \n\u{8}\u{8}\u{8}" + suffix,
                        expected: word, mode: "double_boundary_undo", position: i)
            }
        }
        for word in ["çoook", "evettt", "hayırdır", "anne", "elli", "hissettim", "reddettim", "seviyorumm"] {
            try run(word, expected: word, mode: "intentional_repeat", position: -1)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("DUPLICATE AUDIT: \(rows.count) rows")
    }
}
