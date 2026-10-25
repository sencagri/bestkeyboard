import XCTest
import Foundation
import KBAssembly
import KBGeometry

/// Source inventory and runtime recognition are separate: a compound may be
/// generated correctly without a row containing its complete surface.
final class RootSourceCoverageAuditTests: XCTestCase {
    func testSourceLemmaRecognitionAudit() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["KB_ROOT_SOURCE_AUDIT_INPUT"],
              let output = env["KB_ROOT_SOURCE_AUDIT_OUTPUT"] else {
            throw XCTSkip("Set root-source audit input and output paths")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let inventory = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(inventory["entries"] as? [[String: Any]])
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        let locale = Locale(identifier: "tr_TR")
        var cache: [String: (Bool, Bool)] = [:]
        var rows: [[String: Any]] = []
        for entry in entries {
            let lemma = try XCTUnwrap(entry["lemma"] as? String)
            let surface = lemma.lowercased(with: locale)
            guard !surface.isEmpty, surface.allSatisfy(\.isLetter) else { continue }
            let result: (Bool, Bool)
            if let cached = cache[surface] {
                result = cached
            } else {
                result = (pack.literalChannel.score(surface).isInVocabulary,
                          pack.literalChannel.hasListedSurface(surface))
                cache[surface] = result
            }
            var row = entry
            row["tested_surface"] = surface
            row["recognized"] = result.0
            row["listed"] = result.1
            rows.append(row)
        }
        let report: [String: Any] = [
            "scope": "Pinned source lemmas recognized by production literal channel; does not prove all Turkish roots or all inflections",
            "unique_surfaces": cache.count,
            "recognized_surfaces": cache.values.filter { $0.0 }.count,
            "missing_surfaces": cache.keys.filter { cache[$0]?.0 == false }.sorted(),
            "entries": rows
        ]
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: URL(fileURLWithPath: output))
        print("ROOT SOURCE AUDIT: \(cache.count) surfaces; \(cache.values.filter { !$0.0 }.count) unrecognized")
    }
}
