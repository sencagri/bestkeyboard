import XCTest
import KBLearning

final class HistorySourceRemovalTests: XCTestCase {
    private enum Failure: Error { case acknowledgement }
    private func consume(_ inbox: inout HistoryImportInbox, _ archive: inout HistoryArchive) throws {
        try HistoryImportTransaction.consume(&archive, inbox: inbox,
            writeArchive: { _ in }, writeInbox: { inbox = $0 })
    }

    func testRemovingOneSourcePreservesTypingAndOtherSourceCounts() throws {
        var archive = HistoryArchive()
        archive.observe(text: "ortak canlı")
        var inbox = HistoryImportInbox()
        try inbox.appendMessages([.init(sender: "Ben", text: "ortak whatsapp")], source: "WhatsApp", sender: "Ben")
        try inbox.appendMessages([.init(sender: "Ben", text: "ortak telegram", identity: "tg:1:1")], source: "Telegram", sender: "Ben")
        try consume(&inbox, &archive)
        archive.observe(token: "ortak", previous: nil)
        XCTAssertEqual(archive.history.tokens["ortak"]?.count, 4)
        archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
        inbox.removeSource("WhatsApp")
        try consume(&inbox, &archive)
        XCTAssertEqual(archive.history.tokens["ortak"]?.count, 3)
        XCTAssertNil(archive.history.tokens["whatsapp"])
        XCTAssertNotNil(archive.history.tokens["telegram"])
        XCTAssertNotNil(archive.history.tokens["canlı"])
    }

    func testCancelledPendingBatchCannotReturnButExplicitNewImportCan() throws {
        var archive = HistoryArchive(), inbox = HistoryImportInbox()
        let messages = [ChatExportParser.Message(sender: "Ben", text: "gecikmiş", identity: "tg:1:1")]
        try inbox.appendMessages(messages, source: "Telegram", sender: "Ben")
        let stale = inbox
        inbox.removeSource("Telegram")
        try consume(&inbox, &archive)
        try HistoryImportTransaction.consume(&archive, inbox: stale, writeArchive: { _ in }, writeInbox: { _ in })
        XCTAssertNil(archive.history.tokens["gecikmiş"])
        XCTAssertEqual(try inbox.appendMessages(messages, source: "Telegram", sender: "Ben"), 1)
        try consume(&inbox, &archive)
        XCTAssertEqual(archive.history.tokens["gecikmiş"]?.count, 1)
    }

    func testRemovalRetryDoesNotEraseNewImportFromTheSameSource() throws {
        var archive = HistoryArchive(), inbox = HistoryImportInbox()
        try inbox.appendMessages([.init(sender: "Ben", text: "önceki")], source: "Metin", sender: "Ben")
        try consume(&inbox, &archive)
        inbox.removeSource("Metin")
        try inbox.appendMessages([.init(sender: "Ben", text: "sonraki")], source: "Metin", sender: "Ben")
        XCTAssertThrowsError(try HistoryImportTransaction.consume(&archive, inbox: inbox,
            writeArchive: { _ in }, writeInbox: { _ in throw Failure.acknowledgement }))
        XCTAssertEqual(archive.history.tokens["sonraki"]?.count, 1)
        try consume(&inbox, &archive)
        XCTAssertNil(archive.history.tokens["önceki"])
        XCTAssertEqual(archive.history.tokens["sonraki"]?.count, 1)
    }
}
