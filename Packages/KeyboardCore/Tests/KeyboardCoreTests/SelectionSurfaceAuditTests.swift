import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class SelectionSurfaceAuditTests: XCTestCase {
    func testSelectedSurfaces() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SELECTION_SURFACE_AUDIT"] else { throw XCTSkip("Set KB_SELECTION_SURFACE_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let defaultWords = ["kalem", "Kalem", "KALEM", "istanbul", "İstanbul", "qrmenü", "QRmenü", "çağrı", "çağrı".decomposedStringWithCanonicalMapping, "kalem ", " kalem", "kalem\u{00a0}", "ankara'nın", "ankara’nın", "e-posta", "covid19"]
        let words: [String]
        if let corpus = ProcessInfo.processInfo.environment["KB_SELECTION_SURFACE_CORPUS"] {
            words = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: corpus)))
        } else { words = defaultWords }
        var rows: [[String: String]] = []
        for word in words {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            doc.hostRewrites(to: "önce " + word)
            doc.hostSelects(word)
            let selected = c.handleSelection(doc.selectedText, into: doc)
            rows.append(["input": word, "scalars": word.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "),
                "in_vocabulary": String(pack.literalChannel.score(word).isInVocabulary),
                "selected_return": selected ?? "nil", "editing": String(c.session.isEditingSelection),
                "suggestions": c.suggestions().map(\.surface).joined(separator: " | "),
                "document": doc.text])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
