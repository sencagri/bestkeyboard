import XCTest
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime
import KBLearning
import Foundation

final class UnknownWordSafetyTests: XCTestCase {
    func testRepeatedTypedWordChoicesLearnAndPreserveNextUse() throws {
        let layout = TurkishQ.layout()
        let loaded = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let words = ["qrmenü", "karemenü", "cepmenü", "dijitalmenü", "masakodu",
                     "ödemelinkim", "siparişkodum", "çaymolası", "iştakibi", "günsayacı",
                     "akıllıdefter", "sesliyazım", "denizsu", "ayışığım", "gökçesu",
                     "elifsu", "zeynepcim", "çağrıcım", "merhabaaa", "tamamdırmış",
                     "görüşürüzcü", "şipşakçı", "evdekilerimiz", "paylaşılabilirlik",
                     "özelleştirilebilir", "menüleştir", "kahveciğim", "düşüncebulutu",
                     "klavyecik", "yazıarkadaşım", "bulutnot", "notkutusu", "sencagri"]
        XCTAssertTrue(loaded.literalChannel.autoCorrectsOutOfVocabulary)
        for offset in [-0.2, 0.0, 0.2] {
            for word in words {
                var coordinator = InputCoordinator(layout: layout)
                coordinator.setEngine(.init(decoder: loaded.decoder, literalChannel: loaded.literalChannel))
                let document = FakeDocument()
                for occurrence in 1...3 {
                    for ch in word {
                        let index = try XCTUnwrap(layout.keyIndex(for: ch))
                        let key = layout.keys[index]
                        let point = Point(x: key.center.x + offset * key.width,
                                          y: key.center.y + offset * key.height)
                        coordinator.insertLetter(ch, touch: .init(down: point), into: document)
                    }
                    let original = try XCTUnwrap(coordinator.suggestions().first)
                    XCTAssertEqual(original.surface, word)
                    XCTAssertEqual(original.origin, .literal)
                    try coordinator.perform(.suggestionPick(id: original.id, surface: word,
                                                           origin: original.origin), touch: nil, into: document)
                    XCTAssertEqual(document.text, String(repeating: word + " ", count: occurrence))
                }
                XCTAssertTrue(coordinator.engine!.literalChannel.score(word).isInVocabulary)
                // Yeni koordinatör: oturuma özel koruma değil, kişisel sözlük çalışmalı.
                var next = InputCoordinator(layout: layout)
                next.setEngine(.init(decoder: loaded.decoder, literalChannel: loaded.literalChannel))
                next.replacePersonalLexicon(coordinator.personal)
                let second = FakeDocument()
                for ch in word {
                    let index = try XCTUnwrap(layout.keyIndex(for: ch))
                    next.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: second)
                }
                let report = next.space(into: second)
                XCTAssertEqual(second.text, word + " ", "\(word), offset=\(offset)")
                XCTAssertEqual(report.kind, .literal)
            }
        }
    }

    func testPhoneTyposAreNotAdmittedByOnePickOrRepeatedReopening() throws {
        let layout = TurkishQ.layout()
        let pack = RecordingTestSupport.loaded
        for word in ["şimdş", "belkş", "geldş", "hangş", "patstes", "anaokuku", "bunlat", "buradsb"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in word {
                c.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: doc)
            }
            for _ in 0..<4 {
                let literal = try XCTUnwrap(c.suggestions().first)
                try c.perform(.suggestionPick(id: literal.id, surface: word, origin: .literal), touch: nil, into: doc)
                XCTAssertEqual(doc.text, word + " ")
                XCTAssertFalse(c.personal.isAdmitted(word), word)
                XCTAssertEqual(c.personal.entries[word]?.points, 1, word)
                c.backspaceTap(into: doc)
            }
            c.backspaceTap(into: doc)
            XCTAssertNil(c.personal.entries[word], "Edited typo must lose its one observation")
        }
    }

    func testSuggestionsStillApplyWhenUserChoosesThem() throws {
        let layout = TurkishQ.layout()
        let loaded = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var coordinator = InputCoordinator(layout: layout)
        coordinator.setEngine(.init(decoder: loaded.decoder, literalChannel: loaded.literalChannel))
        let document = FakeDocument()
        for ch in "lslem" {
            let index = try XCTUnwrap(layout.keyIndex(for: ch))
            coordinator.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: document)
        }
        let suggestion = try XCTUnwrap(coordinator.suggestions().first { $0.origin != .literal })
        XCTAssertNotEqual(suggestion.surface, "lslem")
        let report = try coordinator.perform(.suggestionPick(id: suggestion.id,
                surface: suggestion.surface, origin: suggestion.origin), touch: nil, into: document)
        XCTAssertEqual(document.text, suggestion.surface + " ")
        guard case .boundary(let boundary) = report else { return XCTFail("Sınır raporu eksik") }
        XCTAssertEqual(boundary.kind, .suggestion)
    }

    func testExplicitChoicePersistsAndRejectsStalePicks() throws {
        let layout = TurkishQ.layout()
        var c = try TestLexicon.coordinator(layout: layout)
        let doc = FakeDocument()
        for ch in "qrmenü" {
            c.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: doc)
        }
        XCTAssertThrowsError(try c.perform(.suggestionPick(id: "literal:başka", surface: "başka",
                                 origin: .literal), touch: nil, into: doc))
        XCTAssertEqual(doc.text, "qrmenü")
        XCTAssertTrue(c.personal.isEmpty)
        try c.perform(.suggestionPick(id: "literal:qrmenü", surface: "qrmenü",
                                     origin: .literal), touch: nil, into: doc)
        XCTAssertFalse(c.personal.isAdmitted("qrmenü"))
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
        XCTAssertTrue(c.wantsPersonalSave)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PersonalLexiconStore.save(c.personal, to: dir)
        let reloaded = try PersonalLexiconStore.load(from: dir)
        XCTAssertFalse(reloaded.isAdmitted("qrmenü"))
        XCTAssertEqual(reloaded.entries["qrmenü"]?.points, 1)
    }

    func testLiteralIsVisibleWithoutDecoderAndSecureChoiceDoesNotLearn() throws {
        let layout = TurkishQ.layout()
        var c = InputCoordinator(layout: layout)
        c.fieldIsSecure = true
        let doc = FakeDocument()
        for ch in "İrem" {
            let key: Character = ch == "İ" ? "i" : ch
            c.insertUppercaseLetter(key, uppercase: String(ch),
                touch: .init(down: layout.keys[layout.keyIndex(for: key)!].center),
                synthetic: true, into: doc)
        }
        XCTAssertEqual(c.suggestionSurfaces(), ["İrem"])
        XCTAssertEqual(c.suggestionSurfaces(limit: 0), [])
        try c.perform(.suggestionPick(id: "literal:İrem", surface: "İrem",
                                     origin: .literal), touch: nil, into: doc)
        XCTAssertEqual(doc.text, "İrem ")
        XCTAssertTrue(c.personal.isEmpty)
        XCTAssertFalse(c.wantsPersonalSave)
    }

}
