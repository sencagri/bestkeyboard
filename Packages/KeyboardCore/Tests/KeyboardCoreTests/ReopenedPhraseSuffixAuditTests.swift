import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBSpatial
@testable import KBRuntime

final class ReopenedPhraseSuffixAuditTests: XCTestCase {
    func testReopenedPhraseSuffixAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_REOPENED_SUFFIX_AUDIT"] else { throw XCTSkip("Opt-in reopened phrase suffix audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        func type(_ text: String, _ c: inout InputCoordinator, _ doc: FakeDocument) throws {
            for ch in text {
                let lower = Character(String(ch).lowercased(with: locale))
                let key = try XCTUnwrap(layout.keyIndex(for: lower))
                let touch = TouchSample(down: layout.keys[key].center)
                if ch == lower { c.insertLetter(lower, touch: touch, into: doc) }
                else { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
            }
        }
        var rows: [[String: String]] = []
        for (inputBase, phraseBase, suffixes) in [
            ("merhababdünya", "merhaba dünya", ["ya", "dan", "lar"]),
            ("bubev", "bu ev", ["e", "de", "ler"]),
            ("birbkitap", "bir kitap", ["lar", "ta", "çı"]),
            ("bubokul", "bu okul", ["a", "dan", "lar"])] {
            for suffixBase in suffixes {
                for casing in ["lower", "title", "caps"] {
                    func styled(_ value: String) -> String {
                        if casing == "caps" { return value.uppercased(with: locale) }
                        if casing == "title" { return value.prefix(1).uppercased(with: locale) + value.dropFirst() }
                        return value
                    }
                    let input = styled(inputBase), phrase = styled(phraseBase)
                    let suffix = casing == "caps" ? suffixBase.uppercased(with: locale) : suffixBase
                    for cycles in [1, 2, 4] {
                        for prefix in ["", "önce "] {
                            var c = InputCoordinator(layout: layout)
                            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                            let doc = FakeDocument(); doc.hostRewrites(to: prefix)
                            try type(input, &c, doc)
                            let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase }, input)
                            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                            for _ in 0..<cycles { c.backspaceTap(into: doc); c.space(into: doc) }
                            c.backspaceTap(into: doc)
                            try type(suffix, &c, doc)
                            let tail = String(phrase.split(separator: " ").last!) + suffix
                            let originalVisible = c.suggestions().first?.surface == tail
                            let detached = c.session.isDetached && c.session.touches.isEmpty
                            c.space(into: doc)
                            let committedExact = doc.text == prefix + phrase + suffix + " "
                            c.backspaceTap(into: doc)
                            let reopenedExact = c.session.display == tail && c.session.isDetached && c.session.touches.isEmpty
                            for _ in suffix { c.backspaceTap(into: doc) }
                            c.space(into: doc)
                            rows.append(["input": input, "suffix": suffix, "prefix": prefix, "cycles": String(cycles),
                                         "literal_visible": String(originalVisible), "detached": String(detached),
                                         "committed_exact": String(committedExact), "reopened_exact": String(reopenedExact),
                                         "removed_suffix_exact": String(doc.text == prefix + phrase + " "), "actual": doc.text])
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
