import XCTest
import KBLearning

final class LiveQuotedEmailAuditTests: XCTestCase {
    func testQuotedAddressIntermediateWordsAndPairs() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_LIVE_QUOTED_EMAIL_AUDIT"] else {
            throw XCTSkip("Set KB_LIVE_QUOTED_EMAIL_AUDIT")
        }
        let samples = ["dev@example.com", "\"First.Last\"@example.com", "\"First@Last\"@example.com",
                       "\"First Last\"@example.com", "\"First Middle Last\"@example.com",
                       "\"First Last@Work\"@example.com", "\"First\\\" Last\"@example.com",
                       "\"merhaba dünya\"", "\"First Last\""]
        var rows: [[String: String]] = []
        for sample in samples {
            for leading in ["", "mail ", "selam\nmail "] {
                for ending in [" ", ", "] {
                    let text = leading + sample + ending
                    var observation = HistoryObservation(), live = HistoryArchive(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    var events: [String] = []
                    for ch in text {
                        before.append(ch); observation.changed(before: before, documentID: id)
                        if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) {
                            live.observe(event); events.append(event.token)
                        }
                    }
                    live = try HistoryArchive.decode(JSONEncoder().encode(live))
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    let extra = live.history.tokens.keys.filter { bulk.tokens[$0] == nil }.sorted()
                    let extraPairs = live.history.pairs.flatMap { previous, row in
                        row.keys.filter { bulk.pairs[previous]?[$0] == nil }.map { previous + " → " + $0 }
                    }.sorted()
                    rows.append([
                        "sample": sample, "leading": leading, "ending": ending,
                        "is_email": String(TechnicalTokenKind.classify(sample) == .email),
                        "full_sample_preserved": String(live.history.tokens.values.contains { $0.surface == sample }),
                        "events": events.joined(separator: " | "),
                        "extra_surfaces": extra.compactMap { live.history.tokens[$0]?.surface }.joined(separator: " | "),
                        "extra_count": String(extra.count), "extra_pairs": extraPairs.joined(separator: " | "),
                        "extra_pair_count": String(extraPairs.count),
                        "next_after_mail": live.history.nextWords(after: "mail").joined(separator: " | "),
                        "expected_counts_match": String(bulk.tokens.allSatisfy { live.history.tokens[$0.key]?.count == $0.value.count })
                    ])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(rows.count, 54)
    }
}
