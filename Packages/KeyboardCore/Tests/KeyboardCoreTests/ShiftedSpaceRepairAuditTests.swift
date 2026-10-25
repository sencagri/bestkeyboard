import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime

/// Production-pack regression for missing/mistapped spaces across Turkish casing.
final class ShiftedSpaceRepairAuditTests: XCTestCase {
    func testSourceJoinedArtifactsDoNotBlockSeparateWordRepairs() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for (left, right) in [("boru", "hattı"), ("maden", "suyu"), ("içme", "suyu"),
                              ("cam", "suyu"), ("hava", "üssü"), ("söz", "varlığı"),
                              ("her", "biri"), ("orta", "parmak"), ("göz", "yummak"),
                              ("düş", "kırıklığı"), ("güven", "oylaması"), ("yanı", "başı")] {
            XCTAssertTrue(pack.literalChannel.score(left).isInVocabulary, left)
            XCTAssertTrue(pack.literalChannel.score(right).isInVocabulary, right)
            XCTAssertFalse(pack.literalChannel.score(left + right).isInVocabulary,
                           "A joined source artifact must not suppress repair: \(left) \(right)")
        }
    }

    func testShiftedSpaceRepairs() throws {
        let output = ProcessInfo.processInfo.environment["KB_SHIFTED_SPACE_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        let defaultPairs = [("bu", "da"), ("ne", "ki"), ("az", "ye"), ("su", "iç"),
                     ("o", "gün"), ("o", "zaman"), ("ben", "o"), ("iyi", "ki"),
                     ("bu", "ev"), ("bir", "ev"), ("merhaba", "dünya"), ("seni", "seviyorum")]
        let requestedPairs = try ProcessInfo.processInfo.environment["KB_SHIFTED_SPACE_PAIRS"]?.split(separator: ",").map { entry -> (String, String) in
            let words = entry.split(separator: ":")
            guard words.count == 2 else { throw NSError(domain: "Invalid audit pair", code: 1) }
            return (String(words[0]), String(words[1]))
        }
        for pair in requestedPairs ?? defaultPairs {
            for separator in [""] + "zxcvbnmçö".map(String.init) {
                for casing in ["lower", "title", "caps"] {
                    let left = casing == "title" ? pair.0.prefix(1).uppercased(with: Locale(identifier: "tr_TR")) + pair.0.dropFirst() : pair.0
                    let raw = left + separator + pair.1
                    let input = casing == "caps" ? raw.uppercased(with: Locale(identifier: "tr_TR")) : raw
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    for ch in input {
                        let key = try XCTUnwrap(layout.keyIndex(for: Character(String(ch).lowercased(with: Locale(identifier: "tr_TR")))))
                        let lower = Character(String(ch).lowercased(with: Locale(identifier: "tr_TR")))
                        let touch = TouchSample(down: layout.keys[key].center)
                        if lower == ch { c.insertLetter(lower, touch: touch, into: doc) }
                        else { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
                    }
                    let phrase = left + " " + pair.1
                    let expected = casing == "caps" ? phrase.uppercased(with: Locale(identifier: "tr_TR")) : phrase
                    let offered = c.suggestions().map(\.surface)
                    let joinedKnown = pack.literalChannel.score(input.lowercased(with: Locale(identifier: "tr_TR"))).isInVocabulary
                    // These explicit controls also explain the input as a
                    // repeated key inside an ordinary recognized compound. Preserve
                    // the existing duplicate-first policy, rather than weakening
                    // it to force an ambiguous space repair into every probe.
                    let duplicateControls = ["cırccır": "cırcır", "mırmmır": "mırmır", "çerççöp": "çerçöp"]
                    let duplicateControl = duplicateControls[input.lowercased(with: Locale(identifier: "tr_TR"))]
                    let literalFirst = offered.first == input
                    var pickedExact = false
                    if !joinedKnown, let pick = c.suggestions().first(where: { $0.surface == expected }) {
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        pickedExact = doc.text == expected + " "
                    }
                    XCTAssertTrue(literalFirst, "Original input must remain available: \(input)")
                    if joinedKnown {
                        XCTAssertFalse(offered.contains(expected), "Do not split a known word: \(input)")
                    } else if let compound = duplicateControl {
                        XCTAssertTrue(pack.literalChannel.score(compound).isInVocabulary)
                        XCTAssertTrue(offered.contains { $0.lowercased(with: Locale(identifier: "tr_TR")) == compound }, input)
                    } else {
                        XCTAssertTrue(offered.contains(expected), "Missing repair for \(input): \(expected)")
                        XCTAssertTrue(pickedExact, "Repair must insert the exact phrase: \(input)")
                    }
                    rows.append(["duplicate_control": duplicateControl ?? "", "input": input, "expected": expected, "casing": casing, "literal_first": String(literalFirst), "picked_exact": String(pickedExact),
                                 "left_known": String(pack.literalChannel.score(pair.0).isInVocabulary),
                                 "right_known": String(pack.literalChannel.score(pair.1).isInVocabulary),
                                 "joined_known": String(pack.literalChannel.score(input.lowercased(with: Locale(identifier: "tr_TR"))).isInVocabulary),
                                 "offered": String(offered.contains(expected)),
                                 "suggestions": offered.joined(separator: " | ")])
                }
            }
        }
        if let output {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        }
        print("SHIFTED SPACE AUDIT: \(rows.count) observations")
    }
}
