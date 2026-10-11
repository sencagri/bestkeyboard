import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBFoundation
@testable import KBRuntime

final class LongPhraseAuditTests: XCTestCase {
    func testTwoMaximumLengthWordsAndOverLimitControls() throws {
        let left = String(repeating: "a", count: LexiconLimits.maxSurfaceLength)
        let right = String(repeating: "e", count: LexiconLimits.maxSurfaceLength)
        let engine = try TestLexicon.engine([left: 500, right: 500], layout: TurkishQ.layout())
        for separator in ["", "b"] {
            XCTAssertEqual(WordBoundaryRepair.suggestions(for: left + separator + right, channel: engine.literalChannel), [left + " " + right])
        }
        for input in [left + "bb" + right, left + "q" + right, left + "1" + right, left + " " + right] {
            XCTAssertTrue(WordBoundaryRepair.suggestions(for: input, channel: engine.literalChannel).isEmpty)
        }
        // A permissive personal provider must not bypass per-component limits.
        let tooLongPart = left + "a"
        XCTAssertTrue(WordBoundaryRepair.suggestions(for: tooLongPart + "bu", channel: engine.literalChannel,
            personalCost: { $0 == tooLongPart || $0 == "bu" ? 1 : nil }).isEmpty)
    }

    func testLongPhraseLatency() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_LONG_PHRASE_LATENCY"] else {
            throw XCTSkip("Set KB_LONG_PHRASE_LATENCY")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var samples: [Double] = []
        for _ in 0..<8 {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in "kitaplarımızdakilerdenbevdekilerimizdekilerden" {
                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                let start = DispatchTime.now().uptimeNanoseconds
                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                _ = c.suggestions()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            XCTAssertTrue(c.suggestions().contains { $0.surface == "kitaplarımızdakilerden evdekilerimizdekilerden" })
        }
        samples.sort()
        let report: [String: Any] = ["samples": samples.count,
            "p95_ms": samples[Int(Double(samples.count - 1) * 0.95)], "max_ms": samples.last!,
            "scope": "Mac Release production46character inflected phrase typing+suggestions;not phone or all81character inputs"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    func testInflectedPhraseLengthBoundary() throws {
        let output = ProcessInfo.processInfo.environment["KB_LONG_PHRASE_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let pairs = [("evdekilerimizden", "bahsediyordunuz"),
                     ("arkadaşlarımızdan", "bahsediyordunuz"),
                     ("kitaplarımızdakilerden", "bahsediyordunuz"),
                     ("bilgisayarlarımızdan", "bahsediyordunuz"),
                     ("yapabileceklerimizden", "konuşuyordunuz"),
                     ("çocuklarımızdakilerden", "konuşuyordunuz"),
                     ("evdekilerimizdekilerden", "bahsediyordunuz"),
                     ("kitaplarımızdakilerden", "evdekilerimizdekilerden")]
        var rows: [[String: String]] = []
        for (left, right) in pairs {
            for separator in ["", "b", "n"] {
                for mode in ["typing", "selection"] {
                    let input = left + separator + right
                    let expected = left + " " + right
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    if mode == "typing" {
                        for ch in input {
                            let key = try XCTUnwrap(layout.keyIndex(for: ch))
                            c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                        }
                    } else {
                        doc.hostRewrites(to: input)
                        doc.hostSelects(input)
                        XCTAssertNotNil(c.handleSelection(input, into: doc))
                    }
                    let offers = c.suggestions()
                    XCTAssertEqual(doc.text, input)
                    let pick = try XCTUnwrap(offers.first { $0.surface == expected }, "\(mode): \(input)")
                    try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                    XCTAssertEqual(doc.text, expected + (mode == "typing" ? " " : ""))
                    rows.append(["input": input, "length": String(input.count), "mode": mode,
                                 "expected": expected,
                                 "left_known": String(pack.literalChannel.score(left).isInVocabulary),
                                 "right_known": String(pack.literalChannel.score(right).isInVocabulary),
                                 "joined_known": String(pack.literalChannel.score(input).isInVocabulary),
                                 "picked_text": doc.text,
                                 "offered": String(offers.contains { $0.surface == expected }),
                                 "suggestions": offers.map(\.surface).joined(separator: " | ")])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("LONG PHRASE AUDIT: \(rows.count) observations")
    }
}
