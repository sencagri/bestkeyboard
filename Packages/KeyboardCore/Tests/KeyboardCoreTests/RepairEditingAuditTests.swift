import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class RepairEditingAuditTests: XCTestCase {
    func testRepairAcrossEditingModes() throws {
        let output = ProcessInfo.processInfo.environment["KB_REPAIR_EDITING_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for (input, expected) in [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki"),
                                  ("subiç", "su iç"), ("obzaman", "o zaman"),
                                  ("qrmenübaç", "qrmenü aç"), ("qrmenüdenbaç", "qrmenüden aç")] {
            for mode in ["typing", "reopened", "typed_selection", "host_selection", "padded_selection", "detached"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                var personal = PersonalLexicon()
                personal.observe("qrmenü", confidence: .strong)
                c.replacePersonalLexicon(personal)
                let doc = FakeDocument()
                if ["typing", "reopened", "typed_selection"].contains(mode) {
                    for ch in input {
                        let key = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                    }
                    if mode == "reopened" {
                        c.space(into: doc)
                        c.backspaceTap(into: doc)
                    } else if mode == "typed_selection" {
                        doc.hostSelects(input)
                        XCTAssertNotNil(c.handleSelection(input, into: doc))
                    }
                } else if mode == "detached" {
                    doc.hostRewrites(to: "önce " + input)
                    c.adoptDetachedSurface(input)
                } else {
                    let selected = mode == "padded_selection" ? " " + input + "\u{00a0}" : input
                    doc.hostRewrites(to: "önce " + selected + " sonra")
                    doc.hostSelects(selected)
                    XCTAssertNotNil(c.handleSelection(selected, into: doc))
                }
                let offered = c.suggestions().map(\.surface)
                let before = doc.text
                var picked = false
                XCTAssertEqual(offered.contains(expected), mode != "detached", "\(mode): \(input)")
                if let pick = c.suggestions().first(where: { $0.surface == expected }) {
                    try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    picked = true
                }
                let expectedText: String
                switch mode {
                case "typing", "reopened": expectedText = expected + " "
                case "typed_selection": expectedText = expected
                case "host_selection": expectedText = "önce " + expected + " sonra"
                case "padded_selection": expectedText = "önce  " + expected + "\u{00a0} sonra"
                default: expectedText = before
                }
                XCTAssertEqual(doc.text, expectedText, "\(mode): \(input)")
                rows.append(["mode": mode, "input": input, "expected": expected,
                             "offered": String(offered.contains(expected)),
                             "picked": String(picked), "before": before, "after": doc.text,
                             "suggestions": offered.joined(separator: " | ")])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("REPAIR EDITING AUDIT: \(rows.count) observations")
    }

    func testStaleSelectionRejectsPhrasePickAndMultiwordSelectionIsNotResplit() throws {
        let layout = TurkishQ.layout()
        for stale in ["başka", ""] {
            var c = try TestLexicon.coordinator(["merhaba": 500, "dünya": 500], layout: layout)
            let doc = FakeDocument()
            doc.hostRewrites(to: "merhababdünya başka")
            doc.hostSelects("merhababdünya")
            XCTAssertNotNil(c.handleSelection(doc.selectedText, into: doc))
            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == "merhaba dünya" })
            if stale.isEmpty { doc.hostRewrites(to: "merhababdünya başka") }
            else { doc.hostSelects(stale) }
            let before = doc.text
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertEqual(doc.text, before)
        }
        var c = try TestLexicon.coordinator(["merhaba": 500, "dünya": 500], layout: layout)
        let doc = FakeDocument()
        doc.hostRewrites(to: "merhaba dünya")
        doc.hostSelects("merhaba dünya")
        c.handleSelection(doc.selectedText, into: doc)
        XCTAssertTrue(c.boundaryRepairs().isEmpty)
    }
}
