// Generated diagnostic; real load/save/claim/JSON bodies. Publish omitted; lock single-process.
// Store SHA256: ca0f28abcd6f10cd55053ebeaf4047feef51cb9e3b47a9a619e0a6c227104673
import XCTest
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
    static func claim(_ name: String) -> Data? {
        guard let url = file(name) else { return nil }
        let mine = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".claimed")
        guard (try? FileManager.default.moveItem(at: url, to: mine)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: mine) }
        return try? Data(contentsOf: mine)
    }

}
enum DurabilityJSON {
    static func read<T: Decodable>(_ type: T.Type, at url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `protected`: cihaz ilk açılışta kilit açılana kadar okunamaz (kişisel veri).
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL?, protected: Bool = false) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(value) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        if protected { options.insert(.completeFileProtectionUntilFirstUserAuthentication) }
        return (try? data.write(to: url, options: options)) != nil
    }
}

enum DurabilityStore {
    static var url: URL? { DurabilityLocal.url(DurabilityLocal.Name.history) }

    static func load() -> PersonalHistory {
        var h = DurabilityJSON.read(PersonalHistory.self, at: url) ?? PersonalHistory()
        if let imported = claimImport() {
            h.merge(imported)
            save(h)
        }
        publish(h)
        return h
    }

    static func save(_ h: PersonalHistory) {
        DurabilityJSON.write(h, to: url, protected: true)
        publish(h)
    }

    static func publish(_ h: PersonalHistory) {}

    /// Uygulamanın bıraktığı içe aktarmayı sahiplenir — uygulamanın yazmasıyla
    /// aynı kilit altında (yarıda okunup iki kez katılmasın).
    static func claimImport() -> PersonalHistory? {
        guard DurabilitySettings.sharingAllowed else { return nil }
        let data = DurabilityGroup.withLock(DurabilityGroup.File.historyImport) { DurabilityGroup.claim(DurabilityGroup.File.historyImport) }
        return data.flatMap { $0 }.flatMap { try? JSONDecoder().decode(PersonalHistory.self, from: $0) }
    }
}


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

final class DurabilityTypingHistory {
    /// Bu kadar gözlemde bir diske yazılıyor (her kelimede yazmak pahalı).
    private static let saveEvery = 20

    private lazy var history = DurabilityStore.load()
    private var lastObserved: (token: String, previous: String?, length: Int)?
    private var unsaved = 0

    /// Aynı klavye süreci yeniden görünse de uygulamadaki yeni aktarımı alır.
    func refreshImports() {
        _ = history // Tembel yükleme ilk aktarımı zaten sahiplenebilir.
        if let imported = DurabilityStore.claimImport() {
            history.merge(imported)
            unsaved += 1
            flush()
        }
        DurabilityStore.publish(history)
    }

    /// `before`: imleçten önceki metin; boşlukla bitmiyorsa kelime bitmemiş.
    func observe(before: String) {
        guard let lastChar = before.last, lastChar.isWhitespace else { return }
        let toks = PersonalHistory.tokenize(before)
        guard let token = toks.last else { return }
        let prev = toks.count >= 2 ? toks[toks.count - 2] : nil
        // Aynı sınır birden çok kez bildirilebiliyor; bir kez say.
        if let l = lastObserved, l.token == token, l.previous == prev, l.length == before.count { return }
        lastObserved = (token, prev, before.count)
        history.observe(token: token, previous: prev)
        unsaved += 1
        if unsaved >= Self.saveEvery { flush() }
    }

    /// Bir metnin tamamından öğrenir (alandan içe aktarma).
    func ingest(text: String) {
        history.observe(text: text)
        unsaved += 1
        flush()
    }

    func flush() {
        guard unsaved > 0 else { return }
        DurabilityStore.save(history)
        unsaved = 0
    }

    /// Boşlukla biten metinden sonra gelebilecek kelimeler.
    func nextWords(before: String) -> [String] {
        guard before.last == " ", let prev = PersonalHistory.tokenize(before).last,
              PersonalHistory.isWord(prev) else { return [] }
        return history.nextWords(after: prev)
    }

    /// Yazılan önekle başlayan, daha önce yazılmış tam token (IP, e-posta…).
    /// Önek geçmişin sakladığı biçimde: uç noktalama atılmış ("(192.16" → "192.16").
    func recall(lastToken raw: String) -> (prefix: String, full: String)? {
        guard let last = PersonalHistory.tokenize(raw).last, raw.hasSuffix(last),
              let full = history.recall(prefix: last).first else { return nil }
        return (last, full)
    }
}


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

// Import source SHA256: 04fae67f43ab5d3563a2b8cb139152f5d8da36e703da03c7c3c5224b862d3952
enum DurabilityImporter {
    enum ImportError: LocalizedError {
        case unreadable, noMessages, notShared
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Dosya okunamadı. WhatsApp'ta Sohbeti Dışa Aktar › Medyasız seçip tekrar dene."
            case .noMessages: return "Dosyada mesaj bulunamadı."
            case .notShared: return "Uygulama ile klavye henüz bağlı değil; içe aktarılanı klavyeye iletemiyorum."
            }
        }
    }

    /// Seçilen gönderenin satırlarını sayımlara çevirip bekleyen dosyaya katar.
    /// - Returns: işlenen mesaj sayısı.
    @discardableResult
    static func importMessages(_ m: [ChatExportParser.Message], sender: String, source: String = "Sohbet aktarımı") throws -> Int {
        let url = DurabilityGroup.file(DurabilityGroup.File.historyImport)
        guard url != nil else { throw ImportError.notShared }
        let mine = m.filter { $0.sender == sender }
        // Klavye aynı dosyayı alıp siliyor: oku–kat–yaz kilit altında, yoksa
        // arada alınan sayımlar geri yazılıp iki kez katılırdı.
        // Sayımlar kilit **dışında** çıkarılıyor; kilit altında yalnız bekleyenle
        // birleştirip yazılıyor — klavye açılışı uzun bir içe aktarmayı beklemesin.
        var fresh = PersonalHistory()
        for msg in mine { fresh.observe(text: msg.text) }
        let written = DurabilityGroup.withLock(DurabilityGroup.File.historyImport) { () -> Bool in
            var h = DurabilityJSON.read(PersonalHistory.self, at: url) ?? PersonalHistory()
            h.merge(fresh)
            guard DurabilityJSON.write(h, to: url, protected: true) else { return false }
            // Kaynak bazlı kalıcı görünüm; bekleyen dosya klavye tarafından
            // alınınca listeden kaybolmaz. Mesaj gövdeleri burada tutulmaz.
            var catalog = importedHistories
            var previous = catalog[source] ?? PersonalHistory()
            previous.merge(fresh)
            catalog[source] = previous
            DurabilityJSON.write(catalog, to: catalogURL, protected: true)
            return true
        }
        guard written == true else { throw ImportError.notShared }
        return mine.count
    }

    private static var catalogURL: URL? { CatalogLocal.url("imported-word-catalog.json") }
    static var importedHistories: [String: PersonalHistory] {
        DurabilityJSON.read([String: PersonalHistory].self, at: catalogURL) ?? [:]
    }

    static func importText(_ text: String) throws {
        try importMessages([.init(sender: "", text: text)], sender: "", source: "Metin")
    }
}



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


final class EmptyImportAuditTests: XCTestCase {
    func testNoLearnableContent() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_EMPTY_IMPORT_AUDIT"] else { throw XCTSkip("Set KB_EMPTY_IMPORT_AUDIT") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var rows: [[String:String]] = []
        for (mode, text) in [("empty", ""), ("whitespace", "   \n  "), ("punctuation", ". , ! ?"), ("filtered_number", "1234567890123456"), ("valid_control", "qrmenü qrmenü")] {
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

// LearningView SHA256: 2e94484db6e388ef607ba36d0f97453f2211d024e259d87ff99c8ec7bfc3ffb1

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
                                do { try DurabilityImporter.importText(pasted); note = "Metinden öğrenildi; \(CommonText.keyboardPicksUpNext)." }
                                catch { note = error.localizedDescription }
                                pasted = ""; pasting = false; reloadWords()
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
