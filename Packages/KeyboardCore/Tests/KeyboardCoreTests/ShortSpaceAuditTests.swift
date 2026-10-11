import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Production-pack regression for short and single-letter word boundaries.
final class ShortSpaceAuditTests: XCTestCase {
    func testShortPairs() throws {
        let output = ProcessInfo.processInfo.environment["KB_SHORT_SPACE_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for pair in [("bu", "da"), ("ne", "ki"), ("az", "ye"), ("su", "iç"),
                     ("o", "gün"), ("o", "zaman"), ("ben", "o"), ("iyi", "ki"),
                     ("bu", "ev"), ("bir", "ev"), ("merhaba", "dünya")] {
            for separator in ["", "b", "n", "m"] {
                for title in [false, true] {
                    let left = title ? pair.0.prefix(1).uppercased(with: Locale(identifier: "tr_TR")) + pair.0.dropFirst() : pair.0
                    let input = left + separator + pair.1
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    for ch in input {
                        let key = try XCTUnwrap(layout.keyIndex(for: Character(String(ch).lowercased(with: Locale(identifier: "tr_TR")))))
                        c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                    }
                    let expected = left + " " + pair.1
                    let offered = c.suggestions().map(\.surface)
                    let joinedKnown = pack.literalChannel.score(input.lowercased(with: Locale(identifier: "tr_TR"))).isInVocabulary
                    if !joinedKnown {
                        XCTAssertTrue(offered.contains(expected), "\(input): \(offered)")
                        XCTAssertEqual(offered.first, input)
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == expected })
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        XCTAssertEqual(doc.text, expected + " ")
                    }
                    rows.append(["input": input, "expected": expected,
                                 "left_known": String(pack.literalChannel.score(pair.0).isInVocabulary),
                                 "right_known": String(pack.literalChannel.score(pair.1).isInVocabulary),
                                 "joined_known": String(pack.literalChannel.score(input.lowercased(with: Locale(identifier: "tr_TR"))).isInVocabulary),
                                 "offered": String(offered.contains(expected)),
                                 "suggestions": offered.joined(separator: " | ")])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("SHORT SPACE AUDIT: \(rows.count) observations")
    }
}
