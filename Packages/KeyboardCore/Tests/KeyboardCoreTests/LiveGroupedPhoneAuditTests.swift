import XCTest
import KBLearning

final class LiveGroupedPhoneAuditTests: XCTestCase {
    func testLiveBoundariesVersusBulkPhoneLearning() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_LIVE_PHONE_AUDIT"] else {
            throw XCTSkip("Set KB_LIVE_PHONE_AUDIT")
        }
        var rows: [[String: String]] = []
        for phone in ["+90 532 123 45 67", "+90 (532) 123 45 67",
                      "0532 123 45 67", "0212 123 45 67",
                      "+905321234567", "05321234567", "(0532)1234567"] {
            for leading in ["", "numaram "] {
                let text = leading + phone + " ara "
                var observation = HistoryObservation()
                var live = PersonalHistory()
                let document = UUID()
                var before = ""
                observation.changed(before: before, documentID: document)
                var emitted: [String] = []
                for ch in text {
                    before.append(ch)
                    observation.changed(before: before, documentID: document)
                    if ch.isWhitespace, let event = observation.completed(before: before, documentID: document) {
                        emitted.append(event.token)
                        live.observe(event)
                    }
                }
                var bulk = PersonalHistory()
                bulk.observe(text: text)
                live = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(live))
                let extra = live.tokens.values.map(\.surface).filter { value in
                    !bulk.tokens.values.contains { $0.surface == value }
                }.sorted()
                let prefix = phone.hasPrefix("+") ? "+90 532" : "05"
                rows.append([
                    "phone": phone, "leading": leading, "emitted": emitted.joined(separator: " | "),
                    "extra_live_surfaces": extra.joined(separator: " | "),
                    "extra_live_count": String(extra.count),
                    "full_phone_preserved": String(live.tokens.values.contains { $0.surface == phone }),
                    "completion_prefix": prefix,
                    "visible_two": live.completions(before: prefix, after: "", selected: nil).prefix(2).map(\.surface).joined(separator: " | ")
                ])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
