import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class TurkishBoundaryAuditTests: XCTestCase {
    func testSelectionCasingAndContext() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_BOUNDARY_AUDIT"] else {
            throw XCTSkip("Set KB_BOUNDARY_AUDIT to export diagnostic observations")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        func coordinator() -> InputCoordinator {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            return c
        }
        func type(_ text: String, _ c: inout InputCoordinator, _ doc: FakeDocument, offset: Double = 0) throws {
            for ch in text {
                let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR"))
                guard let k = lower.first, let i = layout.keyIndex(for: k) else {
                    c.insertSymbol(ch, into: doc); continue
                }
                let key = layout.keys[i]
                let point = Point(x: key.center.x + offset * key.width, y: key.center.y + offset * key.height)
                if ch.isUppercase { c.insertUppercaseLetter(k, uppercase: String(ch), touch: .init(down: point), into: doc) }
                else { c.insertLetter(ch, touch: .init(down: point), into: doc) }
            }
        }
        var rows: [[String: String]] = []
        for word in ["qrmenü", "cepmenü", "QRmenü", "iPhone", "eDevlet", "BiTaksi", "İşTakibi", "QRMenü", "qrMENÜ", "Ankara", "İstanbul", "Çağrı", "HELLO"] {
            for mode in ["typed_pick", "selected_pick", "tracked_selection_pick", "typed_space"] {
                var c = coordinator()
                let doc = FakeDocument()
                if mode == "tracked_selection_pick" {
                    try type("önce", &c, doc); c.space(into: doc)
                    try type(word, &c, doc); c.space(into: doc, fieldProtectsLiteral: true)
                    try type("sonra", &c, doc); c.space(into: doc)
                    doc.hostSelects(word)
                    c.handleSelection(doc.selectedText, into: doc)
                } else if mode == "selected_pick" {
                    doc.hostRewrites(to: "önce " + word + " sonra")
                    doc.hostSelects(word)
                    c.handleSelection(doc.selectedText, into: doc)
                } else { try type(word, &c, doc) }
                let before = c.suggestionSurfaces().joined(separator: " | ")
                var action = "no suggestion"
                if mode == "typed_space" { action = c.space(into: doc).kind.rawValue }
                else if let original = c.suggestions().first {
                    let report = try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
                    action = String(describing: report)
                }
                rows.append(["group":"selection_casing", "input":word, "mode":mode,
                             "suggestions_before":before,"output":doc.text,
                             "admitted":String(c.personal.isAdmitted(word)),"action":action])
            }
        }
        for window in [0, 4, 8, 9, 10, 14, 64] {
            for offset in [-0.2, 0.0, 0.2] {
                var c = coordinator()
                let doc = FakeDocument()
                doc.contextWindow = window
                try type("ankara’daymışız", &c, doc, offset: offset)
                let report = c.space(into: doc)
                rows.append(["group":"short_context", "input":"ankara’daymışız", "window":String(window),
                             "offset":String(offset),"output":doc.text,"action":report.kind.rawValue])
            }
        }
        // Explicit choice offered on a detached surface: audit whether it is actionable.
        for word in ["qrmenü", "cepmenü"] {
            var c = coordinator()
            let doc = FakeDocument()
            doc.hostRewrites(to: word)
            c.adoptDetachedSurface(word)
            let item = try XCTUnwrap(c.suggestions().first)
            let report = try c.perform(.suggestionPick(id: item.id, surface: item.surface, origin: item.origin), touch: nil, into: doc)
            rows.append(["group":"detached_pick", "input":word, "offered":item.surface,
                         "output":doc.text,"admitted":String(c.personal.isAdmitted(word)),
                         "action":String(describing: report)])
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: URL(fileURLWithPath: output))
        print("BOUNDARY AUDIT: \(rows.count) scenarios; \(output)")
    }
}
