import XCTest
import KBLearning

final class EditedQuotedEmailAuditTests: XCTestCase {
    func testSuffixBackspaceKeepsEarlierOccurrenceEvidence() throws {
        let path = ProcessInfo.processInfo.environment["KB_EDITED_QUOTED_EMAIL_AUDIT"]
        var rows: [[String: String]] = []
        let examples = ["\"First Last\"@example.com", "\"First Middle Last\"@example.com",
                        "\"First Second Third Last\"@example.com", "+90 532 123 45 67"]
        for sample in examples {
            for leading in ["", "mail ", "selam\nmail "] {
                for seeded in (sample.hasPrefix("+") ? [false] : [false, true]) {
                    for suffix in ["", "x", "xy"] {
                        var live = HistoryArchive(), observation = HistoryObservation(), before = ""
                        if seeded { live.observe(text: "mail first\nmail sonra") }
                        var expected = live
                        let id = UUID(); observation.changed(before: "", documentID: id)
                        func append(_ text: String) {
                            for ch in text {
                                before.append(ch); observation.changed(before: before, documentID: id)
                                if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                            }
                        }
                        let cut = sample.hasPrefix("+") ? sample.endIndex : sample.range(of: "\"@")!.lowerBound
                        append(leading + sample[..<cut] + suffix)
                        for _ in suffix {
                            observation.expectBackwardDeletion(before: before, after: "", documentID: id)
                            before.removeLast(); observation.changed(before: before, documentID: id, after: "")
                        }
                        append(String(sample[cut...]) + " ")
                        XCTAssertEqual(before, leading + sample + " ")
                        expected.observe(text: before)
                        live = try HistoryArchive.decode(JSONEncoder().encode(live))
                        let extra = live.history.tokens.keys.filter { expected.history.tokens[$0] == nil }.sorted()
                        rows.append([
                            "sample": sample, "leading": leading, "seeded_prior_words": String(seeded),
                            "deleted_suffix": suffix, "final_text": before,
                            "token_counts_equal": String(live.history.tokens.mapValues(\.count) == expected.history.tokens.mapValues(\.count)),
                            "pair_counts_equal": String(live.history.pairs.mapValues { $0.mapValues(\.count) } == expected.history.pairs.mapValues { $0.mapValues(\.count) }),
                            "extra_surfaces": extra.compactMap { live.history.tokens[$0]?.surface }.joined(separator: " | "),
                            "actual_next_words": live.history.nextWords(after: "mail").joined(separator: " | "),
                            "expected_next_words": expected.history.nextWords(after: "mail").joined(separator: " | "),
                            "full_preserved": String(live.history.tokens.values.contains { $0.surface == sample })
                        ])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let path { try encoder.encode(rows).write(to: URL(fileURLWithPath: path)) }
        XCTAssertEqual(rows.count, 63)
        XCTAssertTrue(rows.allSatisfy { $0["token_counts_equal"] == "true" && $0["pair_counts_equal"] == "true" && $0["full_preserved"] == "true" }, "Every modeled local deletion must preserve final-token learning")
    }
}
