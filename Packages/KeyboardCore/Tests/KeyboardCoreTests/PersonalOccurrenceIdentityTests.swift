import XCTest
import KBGeometry
import KBLearning
import Foundation
@testable import KBRuntime

final class PersonalOccurrenceIdentityTests: XCTestCase {
    private let layout = TurkishQ.layout()

    private func chooseLiteral(_ c: inout InputCoordinator, _ doc: FakeDocument) throws {
        let pick = try XCTUnwrap(c.suggestions().first { $0.origin == .literal })
        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
    }

    func testReadoptingTheSameHostWordDoesNotCreateIndependentUses() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        for _ in 0..<4 {
            doc.hostRewrites(to: "qrmenü")
            c.adoptDetachedSurface("qrmenü")
            try chooseLiteral(&c, doc)
            XCTAssertEqual(doc.text, "qrmenü ")
            XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
            XCTAssertFalse(c.personal.isAdmitted("qrmenü"))
        }
    }

    func testSelectingAlreadyObservedWordDoesNotAddAnotherOccurrence() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.correction.oovTheta = 1000
        let doc = FakeDocument()
        for ch in "qrmenü" {
            c.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: doc)
        }
        c.space(into: doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
        for _ in 0..<4 {
            doc.hostSelects("qrmenü")
            c.handleSelection(doc.selectedText, into: doc)
            try chooseLiteral(&c, doc)
            XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 1)
        }
    }

    func testWholeWordConfirmationCannotBeMultipliedByDetachedBoundaries() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        for _ in 0..<4 {
            doc.hostRewrites(to: "qrmâvi")
            c.adoptDetachedSurface("qrmâvi")
            c.insertText(" ", into: doc)
            c.confirmWholeWord("qrmâvi")
            XCTAssertEqual(c.personal.entries["qrmâvi"]?.points, 1)
        }
    }

    func testExistingWordConfirmationSurvivesRestartWithoutMultiplyingEvidence() throws {
        for mode in ["detached", "selected", "wholeWord"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for restart in 0..<4 {
                var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
                if restart > 0 { c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory)) }
                let doc = FakeDocument()
                doc.hostRewrites(to: "qrmâvi")
                switch mode {
                case "detached":
                    c.adoptDetachedSurface("qrmâvi")
                    try chooseLiteral(&c, doc)
                case "selected":
                    doc.hostSelects("qrmâvi")
                    c.handleSelection(doc.selectedText, into: doc)
                    try chooseLiteral(&c, doc)
                default: c.confirmWholeWord("qrmâvi")
                }
                XCTAssertEqual(c.personal.entries["qrmâvi"]?.points, 1, "\(mode), restart \(restart)")
                XCTAssertFalse(c.personal.isAdmitted("qrmâvi"))
                try PersonalLexiconStore.save(c.personal, to: directory)
            }
        }
    }

    func testExistingConfirmationCannotPromoteTwoPointsButFreshTypingCan() throws {
        var seed = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        seed.ingestPersonal(tokens: ["qrmenü", "qrmenü"])
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        c.replacePersonalLexicon(seed.personal)
        let doc = FakeDocument()
        doc.hostRewrites(to: "qrmenü")
        c.adoptDetachedSurface("qrmenü")
        try chooseLiteral(&c, doc)
        XCTAssertEqual(c.personal.entries["qrmenü"]?.points, 2)
        XCTAssertFalse(c.personal.isAdmitted("qrmenü"))
        // A fresh coordinator is an extension restart; real new input still counts.
        var fresh = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        fresh.replacePersonalLexicon(c.personal)
        let next = FakeDocument()
        for ch in "qrmenü" {
            fresh.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: next)
        }
        try chooseLiteral(&fresh, next)
        XCTAssertTrue(fresh.personal.isAdmitted("qrmenü"))
    }

    func testIndependentTypedOccurrencesStillAccumulate() throws {
        var c = try TestLexicon.coordinator(["kalem": 900], layout: layout)
        let doc = FakeDocument()
        for occurrence in 1...3 {
            for ch in "qrmenü" {
                c.insertLetter(ch, touch: .init(down: layout.keys[layout.keyIndex(for: ch)!].center), into: doc)
            }
            try chooseLiteral(&c, doc)
            XCTAssertEqual(c.personal.entries["qrmenü"]?.points, occurrence)
        }
        XCTAssertTrue(c.personal.isAdmitted("qrmenü"))
    }
}
