import XCTest
import KBLearning

final class HistoryRecoveryTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testBackupPrecedesWriteAndFailurePreventsReplacement() throws {
        let damaged = Data("incomplete archive".utf8)
        var steps: [String] = []
        var live = HistoryArchive()
        live.observe(text: "yeni öğrenme")
        try HistoryArchiveRecovery.recover(unreadable: damaged, current: live,
            backup: { bytes in XCTAssertEqual(bytes, damaged); steps.append("backup") },
            writeArchive: { value in XCTAssertEqual(value.history, live.history); steps.append("write") })
        XCTAssertEqual(steps, ["backup", "write"])
        var wrote = false
        XCTAssertThrowsError(try HistoryArchiveRecovery.recover(unreadable: damaged, current: live,
            backup: { _ in throw Failure.injected }, writeArchive: { _ in wrote = true }))
        XCTAssertFalse(wrote)
    }

    func testReadableArchiveCannotBeResetThroughRecovery() throws {
        var touched = false
        let bytes = try JSONEncoder().encode(HistoryArchive())
        XCTAssertThrowsError(try HistoryArchiveRecovery.recover(unreadable: bytes, current: HistoryArchive(),
            backup: { _ in touched = true }, writeArchive: { _ in touched = true }))
        XCTAssertFalse(touched)
    }
}
