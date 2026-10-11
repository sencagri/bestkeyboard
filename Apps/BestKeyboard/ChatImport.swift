import SwiftUI
import UniformTypeIdentifiers
import KBFoundation
import KBLearning

/// WhatsApp / Telegram dışa aktarımından kullanıcının **kendi** satırlarını
/// yazma geçmişine katar.
///
/// Mesajların kendisi saklanmıyor: dosya bellekte okunup sayımlara
/// (`PersonalHistory`) çevriliyor ve yalnız sayımlar ortak klasöre
/// "bekleyen" olarak yazılıyor. Klavye kalıcı kayıttan sonra aktarımı onaylıyor —
/// geçmişin tek yazarı klavye.
enum ChatImporter {
    enum ImportError: LocalizedError {
        case unreadable, noMessages, noLearnableContent, notShared
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Dosya okunamadı. WhatsApp'ta Sohbeti Dışa Aktar › Medyasız seçip tekrar dene."
            case .noMessages: return "Dosyada mesaj bulunamadı."
            case .noLearnableContent: return "Bu metinde öğrenilebilecek sözcük veya adres bulunamadı."
            case .notShared: return "Uygulama ile klavye henüz bağlı değil; içe aktarılanı klavyeye iletemiyorum."
            }
        }
    }

    static func messages(from url: URL) throws -> [ChatExportParser.Message] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= BoundedZIPReader.maximumArchiveBytes,
              let data = try? Data(contentsOf: url),
              data.count <= BoundedZIPReader.maximumArchiveBytes else { throw ImportError.unreadable }
        let m: [ChatExportParser.Message]
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard let txt = ZipReader.firstEntry(in: data, matching: { $0.hasSuffix(".txt") }),
                  let s = String(data: txt, encoding: .utf8) else { throw ImportError.unreadable }
            m = ChatExportParser.whatsApp(s)
        } else if url.pathExtension.lowercased() == "json" {
            m = ChatExportParser.telegram(data)
        } else if let s = String(data: data, encoding: .utf8) {
            m = ChatExportParser.whatsApp(s)
        } else { throw ImportError.unreadable }
        guard !m.isEmpty else { throw ImportError.noMessages }
        return m
    }

    /// Seçilen gönderenin satırlarını sayımlara çevirip bekleyen dosyaya katar.
    /// - Returns: yeni eklenen mesaj sayısı; aynı aktarım daha önce alındıysa 0.
    @discardableResult
    static func importMessages(_ m: [ChatExportParser.Message], sender: String, source: String = "Sohbet aktarımı") throws -> Int {
        guard let url = AppGroup.file(AppGroup.File.historyImport) else { throw ImportError.notShared }
        let mine = m.filter { $0.sender == sender }
        // Klavye bekleyen batch listesini onaylıyor: oku–kat–yaz kilit altında, yoksa
        // arada alınan sayımlar geri yazılıp iki kez katılırdı.
        // Sayımlar kilit **dışında** çıkarılıyor; kilit altında yalnız bekleyenle
        // birleştirip yazılıyor — klavye açılışı uzun bir içe aktarmayı beklemesin.
        var fresh = PersonalHistory()
        for msg in mine { fresh.observe(text: msg.text) }
        guard !fresh.tokens.isEmpty else { throw ImportError.noLearnableContent }
        var appended = 0
        var importFailure: Error?
        let written = AppGroup.withLock(AppGroup.File.historyImport) { () -> Bool in
            let inboxURL = url
            var inbox: HistoryImportInbox
            if FileManager.default.fileExists(atPath: inboxURL.path) {
                guard let data = try? Data(contentsOf: inboxURL),
                      let decoded = try? HistoryImportInbox.decode(data) else { return false }
                inbox = decoded
            } else { inbox = HistoryImportInbox() }
            if !inbox.legacyCatalogMigrated {
                let legacy = JSONFile.read([String: PersonalHistory].self, at: catalogURL) ?? [:]
                for (source, history) in legacy where inbox.sources[source] == nil {
                    inbox.sources[source] = history
                }
                inbox.legacyCatalogMigrated = true
            }
            do { appended = try inbox.appendMessages(mine, source: source, sender: sender) }
            catch { importFailure = error; return false }
            guard JSONFile.write(inbox, to: inboxURL, protected: true) else { return false }
            return true
        }
        if let importFailure { throw importFailure }
        guard written == true else { throw ImportError.notShared }
        return appended
    }

    private static var catalogURL: URL? { LocalStore.url("imported-word-catalog.json") }
    static func removeSource(_ source: String) throws {
        guard let url = AppGroup.file(AppGroup.File.historyImport) else { throw ImportError.notShared }
        let written = AppGroup.withLock(AppGroup.File.historyImport) { () -> Bool in
            guard let data = try? Data(contentsOf: url), var inbox = try? HistoryImportInbox.decode(data) else { return false }
            if !inbox.legacyCatalogMigrated {
                let legacy = JSONFile.read([String: PersonalHistory].self, at: catalogURL) ?? [:]
                for (name, history) in legacy where inbox.sources[name] == nil { inbox.sources[name] = history }
                inbox.legacyCatalogMigrated = true
            }
            inbox.removeSource(source)
            return JSONFile.write(inbox, to: url, protected: true)
        }
        guard written == true else { throw ImportError.notShared }
    }
    static var importedHistories: [String: PersonalHistory] {
        if let url = AppGroup.file(AppGroup.File.historyImport),
           let data = try? Data(contentsOf: url),
           let inbox = try? HistoryImportInbox.decode(data), inbox.legacyCatalogMigrated {
            return inbox.sources
        }
        return JSONFile.read([String: PersonalHistory].self, at: catalogURL) ?? [:]
    }

    @discardableResult
    static func importText(_ text: String) throws -> Int {
        try importMessages([.init(sender: "", text: text)], sender: "", source: "Metin")
    }
}

/// Sınır ve CRC doğrulamalı ZIP okuyucu; stored/deflate girdileri destekler.
/// Şifreli, çok diskli ve ZIP64 arşivler reddedilir.
typealias ZipReader = BoundedZIPReader

/// İçe aktarma akışı: dosya → gönderen seçimi → sonuç.
struct ChatImportFlow: View {
    @Binding var pendingURL: URL?
    @State private var messages: [ChatExportParser.Message] = []
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(BK.orange.ink)
                } else if let result {
                    Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(BK.green.ink)
                } else {
                    Section {
                        ForEach(ChatExportParser.senders(messages), id: \.self) { s in
                            Button {
                                do {
                                    let n = try ChatImporter.importMessages(messages, sender: s,
                                        source: pendingURL?.pathExtension.lowercased() == "json" ? "Telegram" : "WhatsApp")
                                    result = n == 0 ? "Bu aktarım daha önce alındı; tekrar sayılmadı."
                                        : "\(n) mesaj aktarım için kaydedildi; \(CommonText.keyboardPicksUpNext)."
                                } catch { self.error = error.localizedDescription }
                            } label: {
                                HStack {
                                    Text(s).foregroundStyle(BK.ink)
                                    Spacer()
                                    Text("\(messages.filter { $0.sender == s }.count) mesaj").foregroundStyle(BK.sub)
                                }
                            }
                        }
                    } header: { Text("Bu sohbette sen hangisisin?") }
                      footer: { Text("Yalnız seçtiğin kişinin satırları okunur. Mesajlar saklanmaz; yalnız kelime sayımları.") }
                }
            }
            .navigationTitle("Sohbetten öğren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { pendingURL = nil } } }
            .task {
                guard let url = pendingURL else { return }
                do { messages = try ChatImporter.messages(from: url) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
