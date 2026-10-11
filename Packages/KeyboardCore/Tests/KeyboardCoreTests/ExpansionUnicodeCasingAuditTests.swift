import XCTest
import Foundation
import KBFoundation
import KBGeometry
import KBLexicon
@testable import KBRuntime

final class ExpansionUnicodeCasingAuditTests: XCTestCase {
    func testExpansionUnicodeCasingAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_EXPANSION_UNICODE_CASING_AUDIT"] else {
            throw XCTSkip("Opt-in expansion Unicode casing audit")
        }
        let layout = TurkishQ.layout(), pack = RecordingTestSupport.loaded
        let words = [("îman", "Îman", "ÎMAN"), ("resmî", "Resmî", "RESMÎ"),
                     ("millî", "Millî", "MİLLÎ"), ("fiilî", "Fiilî", "FİİLÎ"),
                     ("kâğıt", "Kâğıt", "KÂĞIT"), ("sükûn", "Sükûn", "SÜKÛN"),
                     ("istanbul", "İstanbul", "İSTANBUL"), ("ılık", "Ilık", "ILIK")]
        var rows: [[String: String]] = []
        for (lower, title, upper) in words {
            for nfd in [false, true] {
                let value = nfd ? lower.decomposedStringWithCanonicalMapping : lower
                for (trigger, expected, style) in [("slm", lower, TurkishText.Casing.none),
                    ("Slm", title, .capitalized), ("SLM", upper, .allCaps)] {
                    for prefix in ["", "önce ", "👩🏽‍💻 önce "] {
                        let map = ExpansionMap(entries: [("slm", value)])
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel, expansions: map))
                        let doc = FakeDocument(); doc.hostRewrites(to: prefix)
                        for ch in trigger {
                            let base = TurkishText.key(String(ch)).first!
                            let key = try XCTUnwrap(layout.keyIndex(for: base))
                            c.insertUppercaseLetter(base, uppercase: String(ch), touch: .init(down: layout.keys[key].center), into: doc)
                        }
                        let untouched = doc.text == prefix + trigger
                        let originalAvailable = c.suggestions().first?.surface == trigger
                        let expansion = try XCTUnwrap(c.suggestions().first { $0.surface == lower })
                        let normalizedAtEntry = Array(expansion.surface.utf8) == Array(lower.utf8)
                        try c.perform(.suggestionPick(id: expansion.id, surface: expansion.surface, origin: expansion.origin), touch: nil, into: doc)
                        let committed = doc.text == prefix + expected + " "
                        let noCalibration = c.calibration.sampleCount == 0
                        let checks = ["typed_unchanged": untouched, "original_available": originalAvailable,
                            "entry_normalized": normalizedAtEntry, "commit_exact": committed,
                            "no_synthetic_calibration": noCalibration]
                        for (name, passed) in checks { XCTAssertTrue(passed, "\(lower) NFD=\(nfd) \(trigger): \(name)") }
                        var row = checks.mapValues(String.init)
                        // Raw format helpers currently receive no identity
                        // normalization. Record divergence separately from the
                        // actual expansion entry point, rather than calling a
                        // helper-only result a demonstrated user-facing failure.
                        row["raw_format_equivalent"] = String(TurkishText.applying(style, to: value) == expected)
                        row["word"] = lower; row["nfd"] = String(nfd)
                        row["trigger"] = trigger; row["prefix"] = prefix
                        rows.append(row)
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
