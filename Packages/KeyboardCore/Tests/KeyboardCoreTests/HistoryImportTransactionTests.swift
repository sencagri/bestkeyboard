import XCTest
import Foundation
import KBLearning

final class HistoryImportTransactionTests: XCTestCase {
    private func inbox() -> HistoryImportInbox {
        var h = PersonalHistory(); h.observe(text: "qrmenü qrmenü qrmenü")
        var inbox = HistoryImportInbox(); inbox.append(h, source: "WhatsApp")
        return inbox
    }
    func testFailedDestinationPreservesLiveStateAndInbox() throws {
        var archive = HistoryArchive()
        let pending = inbox()
        var acknowledged = false
        XCTAssertThrowsError(try HistoryImportTransaction.consume(&archive, inbox: pending,
            writeArchive: { _ in throw CocoaError(.fileWriteNoPermission) },
            writeInbox: { _ in acknowledged = true }))
        XCTAssertTrue(archive.history.tokens.isEmpty)
        XCTAssertTrue(archive.appliedImports.isEmpty)
        XCTAssertFalse(acknowledged)
        XCTAssertEqual(pending.batches.count, 1)
    }
    func testCrashAfterCommitDoesNotDoubleApplyOnRestart() throws {
        var archive = HistoryArchive()
        let pending = inbox()
        var disk: Data?
        XCTAssertThrowsError(try HistoryImportTransaction.consume(&archive, inbox: pending,
            writeArchive: { disk = try JSONEncoder().encode($0) },
            writeInbox: { _ in throw CocoaError(.fileWriteNoPermission) }))
        var reloaded = try HistoryArchive.decode(XCTUnwrap(disk))
        var acknowledged: HistoryImportInbox?
        try HistoryImportTransaction.consume(&reloaded, inbox: pending,
            writeArchive: { disk = try JSONEncoder().encode($0) },
            writeInbox: { acknowledged = $0 })
        XCTAssertEqual(reloaded.history.tokens["qrmenü"]?.count, 3)
        XCTAssertEqual(acknowledged?.batches.count, 0)
        XCTAssertEqual(acknowledged?.sources["WhatsApp"]?.tokens["qrmenü"]?.count, 3)
    }
    func testNewBatchAfterFailedAcknowledgementAndLiveTyping() throws {
        var archive = HistoryArchive()
        var pending = inbox()
        try? HistoryImportTransaction.consume(&archive, inbox: pending,
            writeArchive: { _ in }, writeInbox: { _ in throw CocoaError(.fileWriteUnknown) })
        archive.observe(text: "canlı")
        var fresh = PersonalHistory(); fresh.observe(text: "cepmenü")
        pending.append(fresh, source: "Metin")
        try HistoryImportTransaction.consume(&archive, inbox: pending,
            writeArchive: { _ in }, writeInbox: { _ in })
        XCTAssertEqual(archive.history.tokens["qrmenü"]?.count, 3)
        XCTAssertEqual(archive.history.tokens["cepmenü"]?.count, 1)
        XCTAssertEqual(archive.history.tokens["canlı"]?.count, 1)
    }
    func testLegacyMigrationAndCorruptInput() throws {
        var old = PersonalHistory(); old.observe(text: "eski")
        let data = try JSONEncoder().encode(old)
        XCTAssertEqual(try HistoryArchive.decode(data).history, old)
        let migrated = try HistoryImportInbox.decode(data)
        let reloaded = try HistoryImportInbox.decode(JSONEncoder().encode(migrated))
        XCTAssertEqual(migrated.batches.first?.id, reloaded.batches.first?.id)
        XCTAssertEqual(reloaded.batches.first?.history, old)
        XCTAssertThrowsError(try HistoryImportInbox.decode(Data("broken".utf8)))
    }
    func testActualAtomicFilesRecoverFromDestinationFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("history.json")
        let queue = dir.appendingPathComponent("inbox.json")
        let pending = inbox()
        try JSONEncoder().encode(pending).write(to: queue, options: .atomic)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var archive = HistoryArchive()
        func consume() throws {
            try HistoryImportTransaction.consume(&archive, inbox: HistoryImportInbox.decode(Data(contentsOf: queue)),
                writeArchive: { try JSONEncoder().encode($0).write(to: target, options: .atomic) },
                writeInbox: { try JSONEncoder().encode($0).write(to: queue, options: .atomic) })
        }
        XCTAssertThrowsError(try consume())
        XCTAssertEqual(try HistoryImportInbox.decode(Data(contentsOf: queue)).batches.count, 1)
        try FileManager.default.removeItem(at: target)
        try consume()
        XCTAssertEqual(try HistoryArchive.decode(Data(contentsOf: target)).history.tokens["qrmenü"]?.count, 3)
        XCTAssertTrue(try HistoryImportInbox.decode(Data(contentsOf: queue)).batches.isEmpty)
    }
}

extension HistoryImportTransactionTests {
    func testForgetSurvivesPendingImportAndRemovesSourceSuggestions() throws {
        var imported = PersonalHistory()
        imported.observe(text: "önce qrmenü\nqrmenü sonra")
        var archive = HistoryArchive(history: imported)
        archive.forget("qrmenü")
        archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
        var inbox = HistoryImportInbox()
        inbox.append(imported, source: "WhatsApp")
        var acknowledged: HistoryImportInbox?
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { acknowledged = $0 })
        XCTAssertNil(archive.history.tokens["qrmenü"])
        XCTAssertTrue(archive.history.nextWords(after: "önce").isEmpty)
        XCTAssertTrue(archive.history.nextWords(after: "qrmenü").isEmpty)
        XCTAssertNil(acknowledged?.sources["WhatsApp"]?.tokens["qrmenü"])
    }
}

extension HistoryImportTransactionTests {
    func testIdenticalContentBatchDoesNotReenterQueueOrInflateCatalog() throws {
        var history = PersonalHistory()
        history.observe(text: "qrmenü")
        let id = try HistoryImportInbox.contentID(source: "WhatsApp", sender: "Ben", messages: ["qrmenü"])
        var inbox = HistoryImportInbox()
        XCTAssertTrue(inbox.append(history, source: "WhatsApp", id: id))
        var archive = HistoryArchive()
        var acknowledged = inbox
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { acknowledged = $0 })
        inbox = try HistoryImportInbox.decode(JSONEncoder().encode(acknowledged))
        XCTAssertFalse(inbox.append(history, source: "WhatsApp", id: id))
        XCTAssertTrue(inbox.batches.isEmpty)
        XCTAssertEqual(inbox.sources["WhatsApp"]?.tokens["qrmenü"]?.count, 1)
        XCTAssertNotEqual(id, try HistoryImportInbox.contentID(source: "WhatsApp", sender: "Ben", messages: ["qrmenü", "qrmenü"]))
    }
}
