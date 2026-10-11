import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime

final class TechnicalProtectionAuditTests: XCTestCase {
    func testProtectionSurvivesInputPipeline() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_TECH_PROTECTION_AUDIT"] else {
            throw XCTSkip("Set KB_TECH_PROTECTION_AUDIT")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for base in ["http", "mqtt", "amqp", "csrf", "graphql", "tsx", "https"] {
            let variants = [base, base.uppercased(), String(base.prefix(1)).uppercased() + base.dropFirst(),
                            "@" + base, "#" + base, "test_" + base, "v2" + base, "api/" + base]
            for input in variants {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in input {
                    let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR"))
                    if let keyChar = lower.first, let index = layout.keyIndex(for: keyChar) {
                        let touch = TouchSample(down: layout.keys[index].center)
                        if ch.isUppercase { c.insertUppercaseLetter(keyChar, uppercase: String(ch), touch: touch, synthetic: false, into: doc) }
                        else { c.insertLetter(ch, touch: touch, into: doc) }
                    } else { c.insertSymbol(ch, into: doc) }
                }
                let literal = c.session.literal
                let display = c.session.display
                let report = c.space(into: doc)
                rows.append(["input": input, "literal": literal, "display": display,
                    "whole_input_protected": String(CorrectionPolicy.isProtectedToken(input)),
                    "actual_literal_protected": String(CorrectionPolicy.isProtectedToken(literal)),
                    "output": String(doc.text.dropLast()), "changed": String(String(doc.text.dropLast()) != input),
                    "theta": String(describing: report.theta)])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
