import XCTest
import KBLearning

final class RetractionRecencyAuditTests: XCTestCase {
    private func seeded(_ text: String, origin: String) throws -> HistoryArchive {
        var archive = HistoryArchive()
        if origin != "source_only" { archive.observe(text: text) }
        if origin != "typed_only" {
            var h = PersonalHistory(), inbox = HistoryImportInbox()
            h.observe(text: text); inbox.append(h, source: "Metin")
            try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { _ in })
        }
        return archive
    }
    private func type(_ text: String, into archive: inout HistoryArchive) {
        var observation = HistoryObservation(), before = ""
        let id = UUID(); observation.changed(before: "", documentID: id)
        for ch in text {
            before.append(ch); observation.changed(before: before, documentID: id)
            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { archive.observe(event) }
        }
    }
    func testRetractionRestoresCountsVersusOrderingAndDisplay() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_RETRACTION_RECENCY_AUDIT"] else {
            throw XCTSkip("Set KB_RETRACTION_RECENCY_AUDIT")
        }
        var rows: [[String: String]] = []
        for origin in ["typed_only", "source_only", "mixed"] {
            for local in ["first Last", "First Last", "FIRST Last", "first middle Last"] {
                var live = try seeded("mail first\nmail sonra", origin: origin), expected = live
                let text = "mail \"" + local + "\"@example.com "
                type(text, into: &live); expected.observe(text: text)
                for mode in ["live", "reloaded"] {
                    if mode == "reloaded" {
                        live = try HistoryArchive.decode(JSONEncoder().encode(live))
                        expected = try HistoryArchive.decode(JSONEncoder().encode(expected))
                    }
                    rows.append([
                        "kind": "quoted_email", "origin": origin, "input": text, "mode": mode,
                        "counts_equal": String(live.history.tokens.mapValues(\.count) == expected.history.tokens.mapValues(\.count)),
                        "pair_counts_equal": String(live.history.pairs.mapValues { $0.mapValues(\.count) } == expected.history.pairs.mapValues { $0.mapValues(\.count) }),
                        "actual_offers": live.history.nextWords(after: "mail").joined(separator: " | "),
                        "expected_offers": expected.history.nextWords(after: "mail").joined(separator: " | "),
                        "actual_first_surface": live.history.tokens["first"]?.surface ?? "",
                        "expected_first_surface": expected.history.tokens["first"]?.surface ?? ""
                    ])
                }
            }
            for phone in ["+90 532 123 45 67", "+905321234567"] {
                var live = try seeded("+90 532 123\n+90 532 999", origin: origin), expected = live
                type(phone + " ", into: &live); expected.observe(text: phone + " ")
                for mode in ["live", "reloaded"] {
                    if mode == "reloaded" {
                        live = try HistoryArchive.decode(JSONEncoder().encode(live))
                        expected = try HistoryArchive.decode(JSONEncoder().encode(expected))
                    }
                    rows.append([
                        "kind": "phone", "origin": origin, "input": phone, "mode": mode,
                        "counts_equal": String(live.history.tokens.mapValues(\.count) == expected.history.tokens.mapValues(\.count)),
                        "pair_counts_equal": "true",
                        "actual_offers": live.history.completions(before: "+90 532", after: "", selected: nil).prefix(2).map(\.surface).joined(separator: " | "),
                        "expected_offers": expected.history.completions(before: "+90 532", after: "", selected: nil).prefix(2).map(\.surface).joined(separator: " | ")
                    ])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(rows.count, 36)
    }
}
