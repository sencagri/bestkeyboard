from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
src=(root/'Apps/BestKeyboardExtension/PersonalHistoryStore.swift').read_text()
shared=(root/'Apps/BestKeyboardExtension/Shared.swift').read_text()
body=src[src.index('enum PersonalHistoryStore {'):src.index('/// Yazma geçmişi (sonraki kelime')]
start=body.index('    static func publish(');end=body.index('    /// Uygulamanın bıraktığı',start)
body=body[:start]+'    static func publish(_ h: PersonalHistory) {}\n\n'+body[end:]
for a,b in [('PersonalHistoryStore','DurabilityStore'),('LocalStore','DurabilityLocal'),('JSONFile','DurabilityJSON'),('AppGroup','DurabilityGroup'),('KeyboardSettingsStore','DurabilitySettings')]:body=body.replace(a,b)
claim=shared[shared.index('    static func claim(_ name: String)'):shared.index('    /// Süreçler arası kilit:')]
jsoncode=shared[shared.index('enum JSONFile {'):shared.index('/// `bestkeyboard://`')].replace('JSONFile','DurabilityJSON')
header='''import XCTest
import Foundation
import KBLearning
private enum DurabilitySettings { static let sharingAllowed = true }
private enum DurabilityLocal {
    enum Name { static let history = "history.json" }
    nonisolated(unsafe) static var destination: URL?
    static func url(_ name: String) -> URL? { destination }
}
private enum DurabilityGroup {
    enum File { static let historyImport = "history-import.json" }
    nonisolated(unsafe) static var directory: URL?
    static func file(_ name: String) -> URL? { directory?.appendingPathComponent(name) }
    // Single-process fault injection; lock acquisition/races are not tested.
    static func withLock<T>(_ name: String, _ body: () -> T) -> T? { body() }
'''
test='''
final class ImportDurabilityAuditTests: XCTestCase {
    func testClaimBeforeFailedSave() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_IMPORT_DURABILITY_AUDIT"] else { throw XCTSkip("Set KB_IMPORT_DURABILITY_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for mode in ["success", "destination_is_directory"] {
            let dir = temp.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DurabilityGroup.directory = dir
            let destination = dir.appendingPathComponent("history.json")
            DurabilityLocal.destination = destination
            if mode != "success" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            var imported = PersonalHistory()
            imported.observe(text: "qrmenü qrmenü qrmenü")
            let pending = try XCTUnwrap(DurabilityGroup.file(DurabilityGroup.File.historyImport))
            XCTAssertTrue(DurabilityJSON.write(imported, to: pending))
            let loaded = DurabilityStore.load()
            let existsAfterLoad = FileManager.default.fileExists(atPath: pending.path)
            let persisted = DurabilityJSON.read(PersonalHistory.self, at: destination)
            let reloaded = DurabilityStore.load()
            rows.append(["case": mode, "loaded_count": String(loaded.tokens["qrmenü"]?.count ?? 0),
                "pending_exists_after_load": String(existsAfterLoad),
                "persisted_count": String(persisted?.tokens["qrmenü"]?.count ?? 0),
                "reload_count": String(reloaded.tokens["qrmenü"]?.count ?? 0)])
            XCTAssertEqual(loaded.tokens["qrmenü"]?.count, 3)
            XCTAssertFalse(existsAfterLoad)
            XCTAssertEqual(reloaded.tokens["qrmenü"]?.count ?? 0, mode == "success" ? 3 : 0)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
'''
out=root/'Packages/KeyboardCore/Tests/KeyboardCoreTests/ImportDurabilityAuditTests.swift'
out.write_text('// Generated diagnostic; real load/save/claim/JSON bodies. Publish omitted; lock single-process.\n// Store SHA256: '+hashlib.sha256(src.encode()).hexdigest()+'\n'+header+claim+'}\n'+jsoncode+body+test)
# Exercise actual TypingHistory flush lifecycle against the same temporary store.
lifecycle=src[src.index('final class TypingHistory {'):].replace('TypingHistory','DurabilityTypingHistory').replace('PersonalHistoryStore','DurabilityStore')
retry='''
final class HistoryWriteRetryAuditTests: XCTestCase {
    func testRetryAfterWriteFailure() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_HISTORY_RETRY_AUDIT"] else { throw XCTSkip("Set KB_HISTORY_RETRY_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for mode in ["success", "failed_then_flush", "failed_then_new_observation"] {
            let dir = temp.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DurabilityGroup.directory = dir
            let destination = dir.appendingPathComponent("history.json")
            DurabilityLocal.destination = destination
            if mode != "success" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            let history = DurabilityTypingHistory()
            history.observe(before: "qrmenü ")
            history.flush()
            let first = DurabilityJSON.read(PersonalHistory.self, at: destination)?.tokens["qrmenü"]?.count ?? 0
            if mode != "success" { try FileManager.default.removeItem(at: destination) }
            if mode == "failed_then_new_observation" { history.observe(before: "qrmenü merhaba ") }
            history.flush()
            let final = DurabilityJSON.read(PersonalHistory.self, at: destination)?.tokens["qrmenü"]?.count ?? 0
            rows.append(["case": mode, "count_after_first_flush": String(first), "count_after_recovered_flush": String(final)])
            XCTAssertEqual(final, mode == "failed_then_flush" ? 0 : 1)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
'''
with out.open('a') as f:f.write('\n'+lifecycle+'\n'+retry)
chat=(root/'Apps/BestKeyboard/ChatImport.swift').read_text()
importer=chat[chat.index('enum ChatImporter {'):chat.index('/// En küçük zip okuyucu:')]
a=importer.index('    static func messages(');b=importer.index('    /// Seçilen gönderenin',a)
importer=importer[:a]+importer[b:]
for a,b in [('ChatImporter','DurabilityImporter'),('AppGroup','DurabilityGroup'),('JSONFile','DurabilityJSON'),('LocalStore','CatalogLocal')]:importer=importer.replace(a,b)
catalog='''
private enum CatalogLocal {
    static func url(_ name: String) -> URL? { DurabilityGroup.directory?.appendingPathComponent(name) }
}
final class ImportCatalogFailureAuditTests: XCTestCase {
    func testCatalogWriteFailure() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_IMPORT_CATALOG_AUDIT"] else { throw XCTSkip("Set KB_IMPORT_CATALOG_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for mode in ["success", "catalog_blocked", "pending_blocked"] {
            let dir = temp.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DurabilityGroup.directory = dir
            let pending = try XCTUnwrap(DurabilityGroup.file(DurabilityGroup.File.historyImport))
            let catalog = try XCTUnwrap(CatalogLocal.url("imported-word-catalog.json"))
            if mode != "success" { try FileManager.default.createDirectory(at: mode == "catalog_blocked" ? catalog : pending, withIntermediateDirectories: true) }
            var status = "success"
            do { try DurabilityImporter.importText("qrmenü qrmenü qrmenü") }
            catch { status = "error" }
            let pendingCount = DurabilityJSON.read(PersonalHistory.self, at: pending)?.tokens["qrmenü"]?.count ?? 0
            let catalogCount = DurabilityImporter.importedHistories["Metin"]?.tokens["qrmenü"]?.count ?? 0
            rows.append(["case": mode, "reported": status, "pending_count": String(pendingCount), "catalog_count": String(catalogCount)])
            XCTAssertEqual(status, mode == "pending_blocked" ? "error" : "success")
            XCTAssertEqual(catalogCount, mode == "success" ? 3 : 0)
            XCTAssertEqual(pendingCount, mode == "pending_blocked" ? 0 : 3)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
'''
with out.open('a') as f:f.write('\n// Import source SHA256: '+hashlib.sha256(chat.encode()).hexdigest()+'\n'+importer+'\n'+catalog)
empty_test='''
final class EmptyImportAuditTests: XCTestCase {
    func testNoLearnableContent() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_EMPTY_IMPORT_AUDIT"] else { throw XCTSkip("Set KB_EMPTY_IMPORT_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for (mode, text) in [("empty", ""), ("whitespace", "   \\n  "), ("punctuation", ". , ! ?"), ("filtered_number", "1234567890123456"), ("valid_control", "qrmenü qrmenü")] {
            let dir = temp.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DurabilityGroup.directory = dir
            var reported = "success"
            do { try DurabilityImporter.importText(text) } catch { reported = "error" }
            let pending = DurabilityJSON.read(PersonalHistory.self, at: DurabilityGroup.file(DurabilityGroup.File.historyImport))
            let catalog = DurabilityImporter.importedHistories["Metin"]
            rows.append(["case": mode, "reported": reported, "pending_tokens": String(pending?.tokens.count ?? 0), "catalog_tokens": String(catalog?.tokens.count ?? 0)])
            XCTAssertEqual(reported, "success")
            XCTAssertEqual(pending?.tokens.count, mode == "valid_control" ? 1 : 0)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
'''
with out.open('a') as f:f.write('\n'+empty_test)
learning=(root/'Apps/BestKeyboard/LearningView.swift').read_text()
a=learning.index('                                do { try ChatImporter.importText(pasted)')
b=learning.index('\n                            }',a)
action=learning[a:b].replace('ChatImporter','DurabilityImporter')
ui_test='''
private enum CommonText { static let keyboardPicksUpNext = "test" }
final class PasteFailureRecoveryAuditTests: XCTestCase {
    func testFailedPasteRetainsDraft() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_PASTE_RECOVERY_AUDIT"] else { throw XCTSkip("Set KB_PASTE_RECOVERY_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for mode in ["success", "pending_write_failure"] {
            let dir = temp.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DurabilityGroup.directory = dir
            let pending = try XCTUnwrap(DurabilityGroup.file(DurabilityGroup.File.historyImport))
            if mode != "success" { try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true) }
            var pasted = "elle düzenlenmiş qrmenü metni"
            var pasting = true
            var note: String?
            var reloadCount = 0
            func reloadWords() { reloadCount += 1 }
            // Exact LearningView button action, importer namespace substituted.
__ACTION__
            let stored = DurabilityJSON.read(PersonalHistory.self, at: pending)
            rows.append(["case": mode, "draft_after": pasted, "sheet_open": String(pasting),
                "message": note ?? "", "pending_tokens": String(stored?.tokens.count ?? 0), "reload_calls": String(reloadCount)])
            XCTAssertTrue(pasted.isEmpty)
            XCTAssertFalse(pasting)
            if mode != "success" { XCTAssertNil(stored); XCTAssertFalse(note?.contains("Metinden öğrenildi") ?? true) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
'''.replace('__ACTION__',action)
with out.open('a') as f:f.write('\n// LearningView SHA256: '+hashlib.sha256(learning.encode()).hexdigest()+'\n'+ui_test)
