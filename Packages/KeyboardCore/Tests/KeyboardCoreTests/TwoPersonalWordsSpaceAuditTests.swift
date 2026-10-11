import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBLearning
@testable import KBRuntime

/// Both halves depend on learned roots: either root disappearing must revoke the repair.
final class TwoPersonalWordsSpaceAuditTests: XCTestCase {
    func testTwoLearnedRootsLifecycle() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_TWO_PERSONAL_SPACE_AUDIT"] else {
            throw XCTSkip("Set KB_TWO_PERSONAL_SPACE_AUDIT")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        var rows: [[String: String]] = []
        for left in ["qrmenü", "qrmenüden", "qrmenüler", "qrmenümüzde"] {
            for right in ["mavilo", "mavilodan", "mavilolar", "mavilomuzda"] {
                for separator in ["", "b", "n"] {
                    for casing in ["lower", "title", "caps"] {
                        for forgottenRoot in ["qrmenü", "mavilo"] {
                            func caseSurface(_ value: String) -> String {
                                if casing == "caps" { return value.uppercased(with: locale) }
                                if casing == "title" { return value.prefix(1).uppercased(with: locale) + value.dropFirst() }
                                return value
                            }
                            let input = caseSurface(left + separator + right)
                            let target = caseSurface(left + " " + right)
                            var c = InputCoordinator(layout: layout)
                            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                            var single = PersonalLexicon()
                            single.observe(forgottenRoot == "qrmenü" ? "mavilo" : "qrmenü", confidence: .strong)
                            c.replacePersonalLexicon(single)
                            let doc = FakeDocument()
                            for ch in input {
                                let lower = Character(String(ch).lowercased(with: locale))
                                let index = try XCTUnwrap(layout.keyIndex(for: lower))
                                let touch = TouchSample(down: layout.keys[index].center)
                                if ch == lower { c.insertLetter(lower, touch: touch, into: doc) }
                                else { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
                            }
                            let oneAbsent = !c.suggestions().contains { $0.surface == target }
                            var both = single
                            both.observe(forgottenRoot, confidence: .strong)
                            c.replacePersonalLexicon(both)
                            let offered = c.suggestions().contains { $0.surface == target }
                            let literal = c.suggestions().first?.surface == input
                            let forgotten = c.forgetPersonal(forgottenRoot)
                            let revoked = !c.suggestions().contains { $0.surface == target }
                            let intact = doc.text == input
                            c.replacePersonalLexicon(both)
                            let pick = c.suggestions().first { $0.surface == target }
                            if let pick {
                                try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                            }
                            let exact = pick != nil && doc.text == target + " "
                            let checks = ["one_absent": oneAbsent, "both_offer": offered, "literal_first": literal,
                                          "forget_changed": forgotten, "revoked": revoked, "text_intact": intact, "restored_pick_exact": exact]
                            for (name, passed) in checks { XCTAssertTrue(passed, "\(input), forget \(forgottenRoot): \(name)") }
                            var row = checks.mapValues(String.init)
                            row["input"] = input; row["target"] = target; row["forgotten_root"] = forgottenRoot
                            rows.append(row)
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
