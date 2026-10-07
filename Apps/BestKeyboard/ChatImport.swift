import SwiftUI
import UniformTypeIdentifiers
import Compression
import KBLearning

/// WhatsApp / Telegram dışa aktarımından kullanıcının **kendi** satırlarını
/// yazma geçmişine katar.
///
/// Mesajların kendisi saklanmıyor: dosya bellekte okunup sayımlara
/// (`PersonalHistory`) çevriliyor ve yalnız sayımlar ortak klasöre
/// "bekleyen" olarak yazılıyor. Klavye bir sonraki açılışta katıp siliyor —
/// geçmişin tek yazarı klavye.
enum ChatImporter {
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

    static func messages(from url: URL) throws -> [ChatExportParser.Message] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
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
    /// - Returns: işlenen mesaj sayısı.
    @discardableResult
    static func importMessages(_ m: [ChatExportParser.Message], sender: String) throws -> Int {
        guard let url = AppGroup.file(AppGroup.File.historyImport) else { throw ImportError.notShared }
        var h = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PersonalHistory.self, from: $0) }
            ?? PersonalHistory()
        let mine = m.filter { $0.sender == sender }
        for msg in mine { h.observe(text: msg.text) }
        try JSONEncoder().encode(h).write(to: url, options: .atomic)
        return mine.count
    }

    static func importText(_ text: String) throws {
        try importMessages([.init(sender: "", text: text)], sender: "")
    }
}

/// En küçük zip okuyucu: yerel başlıkları sırayla gezer, "stored" ve
/// "deflate" girdileri açar. WhatsApp dışa aktarımı için yeterli; şifreli
/// ya da zip64 arşiv desteklenmiyor.
enum ZipReader {
    static func firstEntry(in data: Data, matching: (String) -> Bool) -> Data? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // Merkezi dizin boyutları daha güvenilir (veri tanımlayıcılı girdiler
        // yerel başlıkta boyut taşımıyor) — sondaki kayıttan başla.
        guard b.count > 22 else { return nil }
        var eocd = b.count - 22
        while eocd >= 0, u32(eocd) != 0x06054B50 { eocd -= 1 }
        guard eocd >= 0 else { return nil }
        var p = u32(eocd + 16)
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { return nil }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen
            guard matching(name), local + 30 <= b.count else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { return nil }
            let comp = Data(b[start..<(start + csize)])
            if method == 0 { return comp }
            guard method == 8 else { return nil }
            var out = Data(count: usize)
            let n = out.withUnsafeMutableBytes { dst in
                comp.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, usize,
                                              src.bindMemory(to: UInt8.self).baseAddress!, csize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            return n == usize ? out : nil
        }
        return nil
    }
}

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
                                    let n = try ChatImporter.importMessages(messages, sender: s)
                                    result = "\(n) mesajından öğrenildi. Klavye bir sonraki açılışta alacak."
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
