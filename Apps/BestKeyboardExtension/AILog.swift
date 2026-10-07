import Foundation
import Network

/// Yapay zeka istek günlüğü (tasarım 36) — klavye, paylaşım eklentisi ve
/// Kestirmeler aynı dosyaya yazıyor; uygulama Geliştirici araçları'nda gösteriyor.
///
/// Telefonda kalıyor, hiçbir yere gönderilmiyor. Anahtar yazılmıyor; mesajın
/// yalnız ilk 120 harfi tutuluyor. Son 200 kayıt.
enum AILog {
    enum Origin: String, Codable { case keyboard, share, shortcut, app, control
        var title: String {
            switch self {
            case .keyboard: return "Klavye"
            case .share: return "Paylaşım"
            case .shortcut: return "Kestirme"
            case .app: return "Uygulama"
            case .control: return "Kontrol Merkezi"
            }
        }
    }

    enum Status: String, Codable {
        case ok
        /// Model cevap verdi ama metinde aranan yok.
        case notFound
        case error
        /// Cevap geldiğinde klavye ekranda değildi (sonuç gösterilemedi).
        case dismissed
    }

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var origin: Origin
        var action: String
        /// "Yazdığın", "Panodan", "Seçili metin", "Paylaşılan mesaj"…
        var source: String
        var textCount: Int
        var textHead: String
        var provider: String
        var model: String
        var network: String
        var status: Status
        var httpCode: Int?
        var durationMs: Int
        /// Sonuç ya da hata, kısa.
        var detail: String
    }

    static let limit = 200
    private static let headLength = 120

    private static var fileURL: URL? {
        AppGroup.file(AppGroup.File.aiLog)
    }

    private static let queue = DispatchQueue(label: "bk.ailog")

    // MARK: Ağ türü

    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "bk.ailog.net"))
        return m
    }()

    /// İlk kayıttan önce çağrılırsa ağ türü "bilinmiyor" kalmaz (izleyici ısınsın).
    static func prepare() { _ = monitor }

    static var network: String {
        let p = monitor.currentPath
        guard p.status == .satisfied else { return p.status == .unsatisfied ? "Bağlantı yok" : "Bilinmiyor" }
        if p.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if p.usesInterfaceType(.cellular) { return "Hücresel" }
        if p.usesInterfaceType(.wiredEthernet) { return "Kablo" }
        return "Diğer"
    }

    // MARK: Okuma / yazma

    static func all() -> [Entry] {
        queue.sync { load() }
    }

    static func clear() {
        queue.sync { save([]) }
    }

    private static func load() -> [Entry] {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Entry].self, from: d)) ?? []
    }

    private static func save(_ list: [Entry]) {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(Array(list.prefix(limit))).write(to: url, options: .atomic)
    }

    /// En yeni başta.
    static func append(_ e: Entry) {
        queue.sync {
            var list = load()
            list.insert(e, at: 0)
            save(list)
        }
    }

    static func update(_ id: UUID, status: Status, detail: String) {
        queue.sync {
            var list = load()
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].status = status
            list[i].detail = detail
            save(list)
        }
    }

    // MARK: Ölçerek çalıştırma

    /// İsteği çalıştırır, süresini ve sonucunu günlüğe yazar; hatayı aynen geri fırlatır.
    /// - Returns: sonuç ve kaydın kimliği (sonradan "klavye kapandı" işaretlemek için).
    static func measure<T>(origin: Origin, action: String, source: String, text: String,
                           summarize: (T) -> String,
                           _ body: () async throws -> T) async throws -> (value: T, id: UUID) {
        prepare()
        let start = Date()
        let p = AIService.provider
        var e = Entry(date: start, origin: origin, action: action, source: source,
                      textCount: text.count, textHead: String(text.prefix(headLength)),
                      provider: p.title, model: AIService.model(p), network: network,
                      status: .ok, httpCode: nil, durationMs: 0, detail: "")
        do {
            let v = try await body()
            // Ağ türü istekten sonra: izleyici ilk anda henüz yol bildirmemiş olabiliyor.
            // İstek başardıysa "bağlantı yok" olamaz — izleyici bilmiyor demek.
            e.network = network == "Bağlantı yok" ? "Bilinmiyor" : network
            e.durationMs = Int(Date().timeIntervalSince(start) * 1000)
            e.httpCode = 200
            e.detail = String(summarize(v).prefix(160))
            append(e)
            return (v, e.id)
        } catch {
            e.network = network
            e.durationMs = Int(Date().timeIntervalSince(start) * 1000)
            switch error {
            case AIService.Failure.nothingFound:
                e.status = .notFound
                e.httpCode = 200
            case let AIService.Failure.http(code, _):
                e.status = .error
                e.httpCode = code
            default:
                e.status = .error
            }
            e.detail = String(error.localizedDescription.prefix(200))
            append(e)
            throw error
        }
    }

    /// Kopyalanacak düz metin (bana yapıştırmak için).
    static func text(_ list: [Entry]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM HH:mm:ss"
        return list.map { e in
            let code = e.httpCode.map { " \($0)" } ?? ""
            return "\(f.string(from: e.date)) · \(e.action) · \(e.origin.title) · \(e.status.rawValue)\(code) · "
                + "\(e.durationMs) ms · \(e.network) · \(e.provider)/\(e.model) · \(e.source) \(e.textCount) harf"
                + " · “\(e.textHead)” → \(e.detail)"
        }.joined(separator: "\n")
    }
}
