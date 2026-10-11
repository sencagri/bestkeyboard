import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Observational audit: successful export does not mean observed behavior is correct.
final class PersonalRecommitAuditTests: XCTestCase {
    func testPersonalRecommitEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_RECOMMIT_AUDIT"] else {
            throw XCTSkip("Set KB_RECOMMIT_AUDIT")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["yapabilirseniz", "gelebilirseniz", "yazılmadı", "okunmamış", "qrmenü", "kitap"] {
            for mode in ["reopen", "three_occurrences", "extra_spaces", "protected_reopen"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                func type() throws {
                    for ch in word {
                        let i = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                    }
                }
                try type()
                for round in 1...4 {
                    let tokenID = String(describing: c.session.pendingTokenID)
                    let report = c.space(into: doc, fieldProtectsLiteral: mode == "protected_reopen")
                    rows.append(["input": word, "mode": mode, "round": String(round),
                        "token_id": tokenID, "document": doc.text, "decision": report.kind.rawValue,
                        "points": String(c.personal.entries[word]?.points ?? 0),
                        "admitted": String(c.personal.isAdmitted(word)),
                        "calibration_samples": String(c.calibration.sampleCount)])
                    if round == 4 { break }
                    if mode == "three_occurrences" { try type() }
                    else if mode != "extra_spaces" { c.backspaceTap(into: doc) }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        print("RECOMMIT AUDIT: 24 sequences, \(rows.count) snapshots")
    }
}
