import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial

final class CircumflexDecodeAuditTests: XCTestCase {
    func testCandidateAvailability() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_CIRCUMFLEX_AUDIT"] else { throw XCTSkip("Set KB_CIRCUMFLEX_AUDIT") }
        let base = TurkishQ.layout()
        var mapping = base.asciiBase
        mapping["â"] = "a"; mapping["î"] = "i"; mapping["û"] = "u"
        let enhanced = KeyLayout(id: "audit-circumflex", keys: base.keys, asciiBase: mapping)
        var rows: [[String: String]] = []
        for (name, layout) in [("production", base), ("test_only_mapping", enhanced)] {
            let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
            for target in ["hâl", "imkân", "kâr", "kâğıt", "rüzgâr", "hikâye", "millî", "resmî"] {
                let input = target.replacingOccurrences(of: "â", with: "a").replacingOccurrences(of: "î", with: "i")
                let touches = try input.map { ch -> TouchSample in
                    .init(down: layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))].center)
                }
                let results = pack.decoder.decode(touches: touches, topK: 20)
                let hit = results.firstIndex { $0.word == target }
                rows.append(["configuration": name, "input": input, "target": target,
                    "rank_in_top20": hit.map { String($0 + 1) } ?? "absent",
                    "target_cost": results.first { $0.word == target }.map { String($0.cost) } ?? "absent",
                    "top3": results.prefix(3).map(\.word).joined(separator: " | ")])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
