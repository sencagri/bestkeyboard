import Foundation
import KBRuntime

/// Kayıt dizininin **tek** okuyucusu — plan v8 §2.7.
///
/// ## Neden karışık okuyucu
///
/// Yeni konteyner uzantısına (`.bkj`) geçmek, diskte duran `*.json`
/// kayıtlarını **görünmez** bırakırdı: liste ekranı onları göstermez, çekme
/// aracı paketlemez, analiz onları hiç görmez. Kullanıcının bugüne kadar
/// topladığı veri sessizce yok olurdu.
///
/// Bu yüzden tek okuyucu iki biçimi de tanıyor ve **kanonik** tipe çeviriyor.
/// Tüketicilerin (liste UI'ı, çekme aracı, replay) biçim ayrımı görmesi
/// gerekmiyor — gördükleri anda ikisinden birini unutmak mümkün oluyor.
public enum RecordingLibrary {

    /// Diskteki bir kaydın kaynağı.
    public enum Origin: String, Equatable, Sendable {
        /// v2 JSON — `SessionStore`'un yazdığı biçim.
        case legacyJSON
        /// v3 append-only konteyner.
        case journal
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let origin: Origin
        public let session: CanonicalSession
        /// Günlüğün son frame'i yarım kalmıştı ve atıldı.
        ///
        /// Ayrı bir olgu: sessizce kırpmak, güç kaybında kaybolan bir action'ı
        /// hiç olmamış gibi gösterirdi.
        public let truncatedTail: Bool
    }

    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let url: URL
        public let reason: String
        public var description: String { "\(url.lastPathComponent): \(reason)" }
    }

    public struct Listing: Equatable, Sendable {
        public var entries: [Entry]
        /// Okunamayan dosyalar — **atlanmıyor, raporlanıyor**.
        ///
        /// Sessizce atlamak, bozuk bir kaydı hiç var olmamış gibi gösterip
        /// abort oranını bozardı.
        public var failures: [Failure]
    }

    public static let journalExtension = "bkj"
    public static let legacyExtension = "json"

    /// Dizini okur; iki biçimi de kanonik tipe çevirir.
    public static func list(in directory: URL) -> Listing {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            return Listing(entries: [], failures: [])
        }
        var entries: [Entry] = []
        var failures: [Failure] = []

        for url in items.sorted(by: { $0.path < $1.path }) {
            switch url.pathExtension {
            case journalExtension:
                switch readJournal(at: url) {
                case let .success(e): entries.append(e)
                case let .failure(f): failures.append(f)
                }
            case legacyExtension:
                switch readLegacy(at: url) {
                case let .success(e): entries.append(e)
                case let .failure(f): failures.append(f)
                }
            default:
                continue        // geçici dosyalar, gizli dosyalar
            }
        }
        entries.sort { $0.session.startedAt > $1.session.startedAt }
        return Listing(entries: entries, failures: failures)
    }

    // MARK: - Biçimler

    private static func readLegacy(at url: URL) -> Result<Entry, Failure> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.init(url: url, reason: "okunamadı"))
        }
        switch SessionReader.read(data) {
        case let .success(s):
            return .success(.init(url: url, origin: .legacyJSON, session: s,
                                  truncatedTail: false))
        case let .failure(e):
            return .failure(.init(url: url, reason: e.description))
        }
    }

    /// Günlüğü kanonik oturuma katlar.
    ///
    /// `attemptStarted` **zorunlu**: onsuz denemenin kimliği, hedefi ve
    /// koşulları yok — geri kalan frame'ler bağlamsız veri olur.
    private static func readJournal(at url: URL) -> Result<Entry, Failure> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.init(url: url, reason: "okunamadı"))
        }
        let loaded: SessionJournal.Loaded
        switch SessionJournal.load(data) {
        case let .success(l): loaded = l
        case let .failure(e): return .failure(.init(url: url,
                                                    reason: e.description))
        }

        let d = SessionCodec.decoder
        guard let head = loaded.frames.first,
              head.type == .attemptStarted,
              var session = try? d.decode(CanonicalSession.self,
                                          from: head.payload) else {
            return .failure(.init(url: url, reason: "attemptStarted yok"))
        }

        do {
            for frame in loaded.frames.dropFirst() {
                switch frame.type {
                case .attemptStarted:
                    // İkinci bir başlangıç, iki denemenin aynı dosyaya
                    // yazıldığı anlamına gelir; hangisinin olduğu bilinemez.
                    return .failure(.init(url: url,
                                          reason: "ikinci attemptStarted"))
                case .engineConfigured:
                    session.engine = try d.decode(
                        CanonicalSession.EngineSnapshot.self, from: frame.payload)
                case .touch:
                    session.touches.append(try d.decode(
                        CanonicalSession.Touch.self, from: frame.payload))
                case .action:
                    session.actions.append(try d.decode(
                        CanonicalSession.Action.self, from: frame.payload))
                case .terminal:
                    let t = try d.decode(TerminalFrame.self, from: frame.payload)
                    session.status = CanonicalSession.Status(rawValue: t.reason)
                        ?? .invalid
                    session.endedAt = session.startedAt.addingTimeInterval(t.at)
                    session.finalText = t.finalText
                }
            }
        } catch {
            return .failure(.init(url: url, reason: "frame çözülemedi: \(error)"))
        }

        return .success(.init(url: url, origin: .journal, session: session,
                              truncatedTail: loaded.truncatedTail))
    }

    /// `RecordingEngine`'in yazdığı terminal yükü.
    private struct TerminalFrame: Decodable {
        let reason: String
        let at: TimeInterval
        let finalText: String
    }

    // MARK: - Bakım

    /// Yarım kalmış kayıtları bulur.
    ///
    /// **İşaretlemiyor, döndürüyor.** v2'de `markStaleAsInterrupted` dosyayı
    /// yerinde değiştiriyordu; append-only bir günlükte bu mümkün değil ve
    /// olmamalı da: kurtarma kararı zaman ve bağlam gerektiriyor
    /// (`RecordingEngine.recover`), okuma sırasında verilecek bir karar değil.
    public static func stale(in directory: URL) -> [Entry] {
        list(in: directory).entries.filter { $0.session.status == .recording }
    }
}
