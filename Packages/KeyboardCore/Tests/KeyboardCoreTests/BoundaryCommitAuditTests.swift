import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Opt-in observation: exported decisions are evidence, not correctness assertions.
final class BoundaryCommitAuditTests: XCTestCase {
    func testBoundaryDecisions() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_BOUNDARY_COMMIT_AUDIT"] else {
            throw XCTSkip("Set KB_BOUNDARY_COMMIT_AUDIT")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["qrmenü", "evdenmişiz", "yapabilirseniz", "geliyprum", "kitap"] {
            for mode in ["space", "period", "comma", "newline", "period_space"] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for occurrence in 1...3 {
                    for ch in word {
                        let i = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                    }
                    let report: InputCoordinator.TokenCommitReport
                    switch mode {
                    case "space": report = c.space(into: doc)
                    case "newline": report = c.newline(into: doc)
                    case "comma": report = c.insertSymbol(",", into: doc)
                    default: report = c.insertSymbol(".", into: doc)
                    }
                    if mode == "period_space" { c.space(into: doc) }
                    rows.append(["input": word, "mode": mode, "occurrence": String(occurrence),
                        "document": doc.text, "committed": report.committed,
                        "decision": report.kind.rawValue,
                        "theta": report.theta.map { String($0) } ?? "not_asked",
                        "points": String(c.personal.entries[word]?.points ?? 0),
                        "admitted": String(c.personal.isAdmitted(word))])
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        print("BOUNDARY COMMIT AUDIT: 25 sequences, \(rows.count) observations")
    }
}
