import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Opt-in evidence exporter: actual geometry, simulated touches, production packs.
final class MissedSpaceAuditTests: XCTestCase {
    func testSpaceEdge() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_MISSED_SPACE_AUDIT"] else {
            throw XCTSkip("Set KB_MISSED_SPACE_AUDIT")
        }
        let metrics = KeyboardMetrics.default
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for globe in [false, true] {
            let space = try XCTUnwrap(KeyboardGeometry.functionSlots(metrics, showsGlobe: globe).first { $0.role == .space }).rect
            for ch in TurkishQ.row3 {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                guard key.center.x >= space.minX, key.center.x < space.maxX else { continue }
                let above = Point(x: key.center.x, y: space.minY - 0.01 * key.height)
                let below = Point(x: key.center.x, y: space.minY + 0.01 * key.height)
                XCTAssertEqual(KeyboardGeometry.surface(at: above, metrics: metrics, showsGlobe: globe), .content)
                XCTAssertEqual(KeyboardGeometry.surface(at: below, metrics: metrics, showsGlobe: globe), .function(.space))
                XCTAssertEqual(layout.nearestKey(to: above), layout.keyIndex(for: ch))
                for pair in [("seni", "seviyorum"), ("yarın", "görüşürüz")] {
                    for mode in ["letter-center", "above-space-edge"] {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        let doc = FakeDocument()
                        func insert(_ text: String) throws {
                            for letter in text {
                                let k = layout.keys[try XCTUnwrap(layout.keyIndex(for: letter))]
                                c.insertLetter(letter, touch: .init(down: k.center), into: doc)
                            }
                        }
                        try insert(pair.0)
                        c.insertLetter(ch, touch: .init(down: mode == "letter-center" ? key.center : above), into: doc)
                        try insert(pair.1)
                        let expected = pair.0 + " " + pair.1
                        let offered = c.suggestions().map(\.surface)
                        let report = c.space(into: doc)
                        rows.append(["globe": String(globe), "mode": mode,
                            "letter": String(ch), "input": pair.0 + String(ch) + pair.1,
                            "expected": expected, "suggestions": offered.joined(separator: " | "),
                            "expected_offered": String(offered.contains(expected)),
                            "output": String(doc.text.dropLast()), "committed": report.committed,
                            "touch_x": String(key.center.x), "edge_y": String(space.minY),
                            "touch_y": String(mode == "letter-center" ? key.center.y : above.y)])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("MISSED SPACE AUDIT: \(rows.count) probes")
    }
}
