import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class PersonalSpaceAuditTests: XCTestCase {
    func testCapacityProfileRepairLatency() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_PERSONAL_SPACE_LATENCY"] else {
            throw XCTSkip("Set KB_PERSONAL_SPACE_LATENCY")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var personal = PersonalLexicon()
        let letters = Array("abcçdefgğhıijklmnoöprsştuüvyz")
        for i in 0..<(PersonalLexicon.capacity - 1) {
            personal.observe("qr" + String(letters[i / letters.count]) + String(letters[i % letters.count]) + "o", confidence: .strong)
        }
        personal.observe("qrmenü", confidence: .strong)
        XCTAssertEqual(personal.admitted.count, PersonalLexicon.capacity)
        var base = InputCoordinator(layout: layout)
        base.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
        base.replacePersonalLexicon(personal)
        var samples: [Double] = []
        for _ in 0..<12 {
            var c = base
            let doc = FakeDocument()
            for ch in "qrmenüdenbaç" {
                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                let start = DispatchTime.now().uptimeNanoseconds
                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                _ = c.suggestions()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            XCTAssertTrue(c.suggestions().contains { $0.surface == "qrmenüden aç" })
        }
        samples.sort()
        let report: [String: Any] = ["samples": samples.count, "personal_words": personal.admitted.count,
            "p95_ms": samples[Int(Double(samples.count - 1) * 0.95)], "max_ms": samples.last!,
            "scope": "Mac Release typing plus suggestions,512 admitted roots sharing qr prefix;not phone latency"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    func testLearnedPhraseBoundaries() throws {
        let output = ProcessInfo.processInfo.environment["KB_PERSONAL_SPACE_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for (root, forms) in [("qrmenü", ["qrmenü", "qrmenüden", "qrmenüler", "qrmenümüzde"]),
                              ("mavilo", ["mavilo", "mavilodan", "mavilolar", "mavilomuzda"]),
                              ("zepnuk", ["zepnuk", "zepnuktan", "zepnuklar", "zepnukumuzda"])] {
            for profile in ["none", "accepted", "imported"] {
                var base = InputCoordinator(layout: layout)
                base.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                if profile == "accepted" {
                    var personal = PersonalLexicon()
                    personal.observe(root, confidence: .strong)
                    base.replacePersonalLexicon(personal)
                } else if profile == "imported" {
                    _ = base.ingestPersonal(tokens: [root, root, root])
                }
                for form in forms {
                    for order in ["left", "right"] {
                        for separator in ["", "b", "n"] {
                            var c = base
                            let left = order == "left" ? form : "bu"
                            let right = order == "left" ? "aç" : form
                            let input = left + separator + right
                            let doc = FakeDocument()
                            for ch in input {
                                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                            }
                            let expected = left + " " + right
                            let offered = c.suggestions().map(\.surface)
                            if profile == "none" {
                                XCTAssertFalse(offered.contains(expected), input)
                            } else {
                                XCTAssertTrue(offered.contains(expected), "\(profile): \(input): \(offered)")
                                XCTAssertEqual(offered.first, input)
                                let pick = try XCTUnwrap(c.suggestions().first { $0.surface == expected })
                                try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                                XCTAssertEqual(doc.text, expected + " ")
                            }
                            rows.append(["root": root, "form": form, "profile": profile,
                                         "input": input, "expected": expected,
                                         "root_admitted": String(c.personal.admitted.contains(root)),
                                         "personal_form_known": String(c.isKnownPersonalInflection(form)),
                                         "offered": String(offered.contains(expected)),
                                         "suggestions": offered.joined(separator: " | ")])
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("PERSONAL SPACE AUDIT: \(rows.count) observations")
    }
}
