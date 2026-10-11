import XCTest
import Foundation
import KBFoundation
import KBGeometry
@testable import KBRuntime

final class WholeWordUnicodeAuditTests: XCTestCase {
    func testWholeWordUnicodeIdentityAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_WHOLE_WORD_UNICODE_AUDIT"] else {
            throw XCTSkip("Opt-in whole-word Unicode identity audit")
        }
        let layout = TurkishQ.layout(), pack = RecordingTestSupport.loaded
        func normalized(_ s: String, decomposed: Bool) -> String {
            decomposed ? s.decomposedStringWithCanonicalMapping : s.precomposedStringWithCanonicalMapping
        }
        var rows: [[String: String]] = []
        for (root, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            for rootNFD in [false, true] {
                for inputNFD in [false, true] {
                    for casing in 0..<3 {
                        for opening in ["", "(\""] {
                            for right in ["", "\") sonra", " sonra"] {
                                var c = InputCoordinator(layout: layout)
                                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                                c.confirmWholeWord(normalized(root, decomposed: rootNFD))
                                let raw = form + "baç"
                                let cased = casing == 2 ? TurkishText.uppercased(raw) : casing == 1 ? TurkishText.uppercased(String(raw.prefix(1))) + raw.dropFirst() : raw
                                let source = normalized(cased, decomposed: inputNFD)
                                let before = "önce " + opening + source
                                let offer = try XCTUnwrap(c.wholeWordSuggestion(before: before, after: right, selected: nil))
                                let originalBytes = Array(offer.original.utf8) == Array(source.utf8)
                                    && Array((offer.surfaces.first ?? "").utf8) == Array(source.utf8)
                                let repaired = offer.surfaces.contains { TurkishText.key($0) == form + " aç" }
                                let replacement = offer.replacement(for: source)
                                let replacementBytes = replacement.map { Array($0.utf8) == Array((source + (right.isEmpty ? " " : "")).utf8) } == true
                                // One explicit choice admits the canonical word. Repeated
                                // NFC/NFD/case forms must not create separate entries.
                                for accepted in [source, source.precomposedStringWithCanonicalMapping,
                                                 source.decomposedStringWithCanonicalMapping,
                                                 TurkishText.uppercased(source)] {
                                    c.confirmWholeWord(accepted)
                                }
                                let canonical = TurkishText.key(source)
                                let learnedOnce = Set(c.personal.admitted) == Set([root, canonical])
                                let acceptedOffer = c.wholeWordSuggestion(before: before, after: right, selected: nil)
                                let acceptedNotSplit = acceptedOffer?.surfaces == [source]
                                let forgotten = c.forgetPersonal(source.decomposedStringWithCanonicalMapping)
                                let restoredOffer = c.wholeWordSuggestion(before: before, after: right, selected: nil)
                                let repairRestored = restoredOffer?.surfaces.contains { TurkishText.key($0) == form + " aç" } == true
                                let rootPreserved = c.personal.admitted == [root]
                                let checks = ["original_bytes": originalBytes, "repair_canonical": repaired,
                                    "replacement_bytes": replacementBytes, "learned_once": learnedOnce,
                                    "accepted_not_split": acceptedNotSplit, "forgotten": forgotten,
                                    "repair_restored": repairRestored, "root_preserved": rootPreserved]
                                for (name, passed) in checks { XCTAssertTrue(passed, "\(root) rootNFD=\(rootNFD) inputNFD=\(inputNFD) case=\(casing): \(name)") }
                                var row = checks.mapValues(String.init)
                                row["root"] = root; row["root_nfd"] = String(rootNFD); row["input_nfd"] = String(inputNFD)
                                row["casing"] = String(casing); row["opening"] = opening; row["right"] = right
                                rows.append(row)
                            }
                        }
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
