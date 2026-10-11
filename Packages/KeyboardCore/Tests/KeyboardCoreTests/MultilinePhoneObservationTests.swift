import XCTest
import KBLearning

final class MultilinePhoneObservationTests: XCTestCase {
    func testEarlierNewlinesDoNotDisableProvisionalPhoneReplacement() throws {
        var rows: [[String: String]] = []
        for leading in ["", "numaram ", "selam\n", "selam\r\n", "selam\nnumaram ", "selam\n\n"] {
            for phone in ["+90 532 123 45 67", "+90 (532) 123 45 67", "0532 123 45 67", "+905321234567"] {
                for ending in [" ", "\n"] {
                    let text = leading + phone + ending
                    var observation = HistoryObservation(), live = HistoryArchive(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for ch in text {
                        before.append(ch)
                        observation.changed(before: before, documentID: id)
                        if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    live = try HistoryArchive.decode(JSONEncoder().encode(live))
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    let extra = live.history.tokens.keys.filter { bulk.tokens[$0] == nil }.sorted()
                    let countsMatch = bulk.tokens.allSatisfy { live.history.tokens[$0.key]?.count == $0.value.count }
                    rows.append(["leading": leading, "phone": phone, "ending": ending,
                                 "extra": extra.joined(separator: " | "), "extra_count": String(extra.count),
                                 "expected_counts_match": String(countsMatch)])
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["KB_MULTILINE_PHONE_AUDIT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
        }
        let failed = rows.filter { $0["extra_count"] != "0" || $0["expected_counts_match"] != "true" }
        XCTAssertTrue(failed.isEmpty, "Live/bulk mismatch: \(failed)")
    }
}
