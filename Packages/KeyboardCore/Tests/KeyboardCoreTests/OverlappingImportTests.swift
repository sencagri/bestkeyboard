import XCTest
import KBLearning

final class OverlappingImportTests: XCTestCase {
    func testReceiptLimitRejectsBeforeChangingPendingCounts() throws {
        var inbox = HistoryImportInbox()
        inbox.receivedBatches = Set((0..<HistoryImportInbox.maximumBatchReceipts).map { _ in UUID() })
        XCTAssertThrowsError(try inbox.appendMessages([.init(sender: "Ben", text: "merhaba", identity: "new")], source: "Telegram", sender: "Ben"))
        XCTAssertTrue(inbox.batches.isEmpty)
        XCTAssertTrue(inbox.sources.isEmpty)
        XCTAssertTrue(inbox.receivedMessages.isEmpty)
        XCTAssertEqual(inbox.receivedBatches.count, HistoryImportInbox.maximumBatchReceipts)
    }
    func testOverlappingExportsCountOnlyNewMessageIdentities() throws {
        var inbox = HistoryImportInbox()
        let first = ChatExportParser.Message(sender: "Ben", text: "merhaba", identity: "telegram:10:1")
        let second = ChatExportParser.Message(sender: "Ben", text: "merhaba", identity: "telegram:10:2")
        XCTAssertEqual(try inbox.appendMessages([first], source: "Telegram", sender: "Ben"), 1)
        XCTAssertEqual(try inbox.appendMessages([first, second], source: "Telegram", sender: "Ben"), 1)
        XCTAssertEqual(inbox.sources["Telegram"]?.tokens["merhaba"]?.count, 2)
        let decoded = try HistoryImportInbox.decode(JSONEncoder().encode(inbox))
        inbox = decoded
        XCTAssertEqual(try inbox.appendMessages([second], source: "Telegram", sender: "Ben"), 0)
        let otherChat = ChatExportParser.Message(sender: "Ben", text: "merhaba", identity: "telegram:20:1")
        XCTAssertEqual(try inbox.appendMessages([otherChat], source: "Telegram", sender: "Ben"), 1)
    }

    func testTelegramParserRetainsChatAndMessageIdentity() throws {
        let data = Data(#"{"chats":{"list":[{"id":10,"messages":[{"id":1,"type":"message","from":"Ben","text":"selam"}]},{"id":20,"messages":[{"id":1,"type":"message","from":"Ben","text":"selam"}]}]}}"#.utf8)
        let messages = ChatExportParser.telegram(data)
        XCTAssertEqual(messages.map(\.identity), ["telegram:10:1", "telegram:20:1"])
    }

    func testLegacyBatchReceiptStillPreventsReimport() throws {
        var inbox = HistoryImportInbox()
        inbox.receivedBatches.insert(try HistoryImportInbox.contentID(source: "Metin", sender: "", messages: ["merhaba"]))
        XCTAssertEqual(try inbox.appendMessages([.init(sender: "", text: "merhaba")], source: "Metin", sender: ""), 0)
    }
}
