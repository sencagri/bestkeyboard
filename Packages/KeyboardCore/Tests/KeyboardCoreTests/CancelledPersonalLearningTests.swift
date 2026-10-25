import XCTest
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class CancelledPersonalLearningTests: XCTestCase {
    private let layout = TurkishQ.layout()

    private func type(_ word: String, coordinator: inout InputCoordinator, doc: FakeDocument) throws {
        for ch in word {
            let index = try XCTUnwrap(layout.keyIndex(for: ch))
            coordinator.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
        }
    }

    func testRepeatedCancelledPrefixesNeverBecomePersonalWords() throws {
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (prefix, tail) in [("müh", "endislik"), ("seviyoru", "m"), ("değerl", "endirilmesini")] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for attempt in 1...4 {
                try type(prefix, coordinator: &c, doc: doc)
                c.space(into: doc)
                c.backspaceTap(into: doc)
                try type(tail, coordinator: &c, doc: doc)
                c.space(into: doc)
                XCTAssertEqual(doc.text, String(repeating: prefix + tail + " ", count: attempt))
                XCTAssertNil(c.personal.entries[prefix], "Cancelled prefix was learned: \(prefix), attempt \(attempt)")
            }
        }
    }

    func testIndependentEvidenceSurvivesCancellingLatestOccurrence() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = 1000
        let doc = FakeDocument()
        try type("qrmenü", coordinator: &c, doc: doc)
        c.space(into: doc)
        try type("qrmenü", coordinator: &c, doc: doc)
        c.space(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 2)
        c.backspaceTap(into: doc)
        // Reopening and closing unchanged must neither multiply nor lose evidence.
        c.space(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 2)
        c.backspaceTap(into: doc)
        try type("ler", coordinator: &c, doc: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
        c.space(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
    }

    func testDeletingWholeWeakOccurrenceRetractsOnlyThatOccurrence() throws {
        for repeatDelete in [false, true] {
            var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
            c.correction.oovTheta = 1000
            let doc = FakeDocument()
            try type("qrmenü", coordinator: &c, doc: doc)
            c.space(into: doc)
            if repeatDelete {
                for _ in "qrmenü " { c.backspaceRepeat(into: doc) }
            } else { c.deleteWord(into: doc) }
            XCTAssertEqual(doc.text, "")
            XCTAssertNil(c.personal.entries["qrmenü"])
        }
    }

    func testCancelledLiteralChoiceRetractsItsOccurrence() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        try type("qrmenü", coordinator: &c, doc: doc)
        let original = try XCTUnwrap(c.suggestions().first)
        try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
        c.backspaceTap(into: doc)
        try type("ler", coordinator: &c, doc: doc)
        XCTAssertNil(c.personal.entries["qrmenü"])
    }

    func testCancellingAdmissionPreservesImportedEvidenceAndPersists() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = 1000
        c.ingestPersonal(tokens: ["qrmenü", "qrmenü"])
        let imported = try XCTUnwrap(c.personal.entries["qrmenü"])
        XCTAssertEqual(imported.points, 2)
        let doc = FakeDocument()
        try type("qrmenü", coordinator: &c, doc: doc)
        c.space(into: doc)
        XCTAssertTrue(c.personal.isAdmitted("qrmenü"))
        c.personalSaved()
        c.backspaceTap(into: doc)
        try type("ler", coordinator: &c, doc: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"], imported)
        XCTAssertFalse(c.engine!.literalChannel.score("qrmenü").isInVocabulary)
        XCTAssertTrue(c.wantsPersonalSave)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try PersonalLexiconStore.save(c.personal, to: directory)
        XCTAssertEqual(try PersonalLexiconStore.load(from: directory).entries["qrmenü"], imported)
    }

    func testUnattributedHostChangeDoesNotRetractAnotherOccurrence() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = 1000
        let doc = FakeDocument()
        try type("qrmenü", coordinator: &c, doc: doc)
        c.space(into: doc)
        let evidence = c.personal.entries["qrmenü"]
        c.backspaceTap(into: doc)
        doc.hostRewrites(to: "başka")
        c.handleSelection(nil, into: doc)
        c.backspaceTap(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"], evidence)
    }
}
