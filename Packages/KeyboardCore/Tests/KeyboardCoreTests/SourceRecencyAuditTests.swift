import XCTest
import KBLearning

final class SourceRecencyAuditTests: XCTestCase {
    func testImportOrderVersusSourceNameAndPersistence() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_SOURCE_ORDER_AUDIT"] else {
            throw XCTSkip("Set KB_SOURCE_ORDER_AUDIT for source-order diagnostics")
        }
        var rows: [[String: String]] = []
        for order in [["WhatsApp", "Telegram"], ["Telegram", "WhatsApp"], ["Z", "A"], ["A", "Z"], ["WhatsApp", "Telegram", "Metin"], ["Metin", "Telegram", "WhatsApp"]] {
            var inbox = HistoryImportInbox()
            var archive = HistoryArchive()
            for (index, source) in order.enumerated() {
                let address = "https://example.com/item" + String(index)
                try inbox.appendMessages([.init(sender: "Ben", text: address)], source: source, sender: "Ben")
                try HistoryImportTransaction.consume(&archive, inbox: inbox,
                    writeArchive: { _ in }, writeInbox: { inbox = $0 })
            }
            XCTAssertEqual(archive.history.tokens.count, order.count)
            for mode in ["live", "reloaded", "unrelated_typing"] {
                if mode == "reloaded" {
                    archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
                } else if mode == "unrelated_typing" {
                    archive.observe(token: "merhaba", previous: nil)
                }
                rows.append([
                    "sources_in_import_order": order.joined(separator: ","),
                    "mode": mode,
                    "expected_most_recent": "https://example.com/item" + String(order.count - 1),
                    "visible_two": archive.history.completions(before: "https://example.com/item", after: "", selected: nil).prefix(2).map(\.surface).joined(separator: " | "),
                    "actual_first": archive.history.recall(prefix: "https://example.com/item", limit: 2).first ?? "",
                    "first_count": String(archive.history.tokens["https://example.com/item0"]?.count ?? 0),
                    "second_count": String(archive.history.tokens["https://example.com/item1"]?.count ?? 0)
                ])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
