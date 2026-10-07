import Foundation
import KBGeometry
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
        /// v2 JSON — eski kayıt deposunun yazdığı biçim (yalnız okunuyor).
        case legacyJSON
        /// v3 append-only konteyner.
        case journal
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        /// Dosya yolu kimlik: dizinde tekil ve kararlı.
        public var id: URL { url }

        public let url: URL
        public let origin: Origin
        public let session: CanonicalSession
        /// **Sonradan** eklenen not — kayda değil, dosyanın yanına yazılıyor.
        ///
        /// `session.note` denemeyi kapatırken yazılan; bu ise kayıt kapandıktan
        /// sonra, listeye bakarken eklenen. İkisi ayrı olgular ve ayrı duruyor:
        /// tek alana çökertmek "o an mı yazdı, sonradan mı" sorusunu
        /// cevaplanamaz yapardı.
        ///
        /// Günlüğe **yazılamaz**: append-only konteynerde terminal son frame ve
        /// sonrasına ekleme reddediliyor. Yan dosya bunu bir kısıt değil, doğru
        /// modelleme yapıyor — not gözlem değil, gözlem hakkında bir yorum.
        public var annotation: String?
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

        public init(url: URL, reason: String) {
            self.url = url; self.reason = reason
        }
    }

    public struct Listing: Equatable, Sendable {
        public var entries: [Entry]
        /// Okunamayan dosyalar — **atlanmıyor, raporlanıyor**.
        ///
        /// Sessizce atlamak, bozuk bir kaydı hiç var olmamış gibi gösterip
        /// abort oranını bozardı.
        public var failures: [Failure]
    }

    /// Kayıtların durduğu dizin.
    ///
    /// `Application Support`, `Documents` değil: ham dokunma koordinatı kişisel
    /// veri ve elle girilen hedef metin daha da hassas olabilir (§12.9).
    /// `Documents` kullanıcıya ve yedeğe açıktır.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("typing-sessions", isDirectory: true)
    }

    public static let journalExtension = "bkj"
    static let legacyExtension = "json"
    /// Yan dosya uzantısı — kaydın kendisi değil, hakkındaki not.
    public static let annotationExtension = "bknote"

    /// Dizini okur; iki biçimi de kanonik tipe çevirir.
    public static func list(in directory: URL) -> Listing {
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        } catch {
            // **Üç durum, iki değil.**
            //
            // Dizin okunamadı ≠ dizin boş: izin sorununu "hiç kayıt yok" diye
            // göstermek bozukluğu gizlerdi. Ama "dizin daha hiç oluşmadı" da
            // okunamamak değil — kayıt dizinini ilk `FileJournalWriter`
            // yaratıyor, dolayısıyla temiz kurulumda yokluğu **normal**.
            //
            // İkisini tek sonuca indirmek ters yönde yanlıştı: yeni kurulumda
            // liste ekranı kırmızı bir dosya sistemi hatası basıyor ve analiz
            // aracı hiç kayıt üretilmemiş bir cihazda 1 ile çıkıyordu.
            if Self.isNoSuchFile(error as NSError) {
                return Listing(entries: [], failures: [])
            }
            return Listing(entries: [],
                           failures: [.init(url: directory,
                                            reason: "dizin okunamadı: \(error)")])
        }
        var entries: [Entry] = []
        var failures: [Failure] = []

        for url in items.sorted(by: { $0.path < $1.path }) {
            switch url.pathExtension {
            case journalExtension:
                switch readJournal(at: url) {
                case var .success(e):
                    e.annotation = readAnnotation(for: url)
                    entries.append(e)
                case let .failure(f): failures.append(f)
                }
            case legacyExtension:
                switch readLegacy(at: url) {
                case var .success(e):
                    e.annotation = readAnnotation(for: url)
                    entries.append(e)
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

        // Frame **sırası** doğrulanıyor. Sıra-duyarsız bir okuyucuda iki
        // `engineConfigured`'dan sonuncusu sessizce kazanıyor, terminalden
        // sonraki bir action kabul ediliyor ve dosya kendi anlattığından başka
        // bir denemeyi tarif ediyordu.
        var configured = false
        var terminal: SessionJournal.Terminal?

        do {
            for frame in loaded.frames.dropFirst() {
                if terminal != nil {
                    return .failure(.init(url: url,
                                          reason: "terminalden sonra "
                                            + "\(frame.type) frame'i"))
                }
                // **Sıra**: motor kurulmadan olay olamaz. `configured` yalnız
                // ikinci `engineConfigured`'ı engelliyordu; üretimde imkânsız
                // olan `attemptStarted → action → engineConfigured` sırası
                // kabul ediliyor ve kayıt, eylemlerin hangi motorla üretildiği
                // hakkında yanlış bir şey söylüyordu.
                if !configured, frame.type == .touch || frame.type == .action {
                    return .failure(.init(url: url,
                                          reason: "engineConfigured'dan önce "
                                            + "\(frame.type) frame'i"))
                }
                switch frame.type {
                case .attemptStarted:
                    // İkinci bir başlangıç, iki denemenin aynı dosyaya
                    // yazıldığı anlamına gelir; hangisinin olduğu bilinemez.
                    return .failure(.init(url: url,
                                          reason: "ikinci attemptStarted"))
                case .engineConfigured:
                    guard !configured else {
                        return .failure(.init(url: url,
                                              reason: "ikinci engineConfigured"))
                    }
                    configured = true
                    session.engine = try d.decode(
                        CanonicalSession.EngineSnapshot.self, from: frame.payload)
                case .touch:
                    session.touches.append(try d.decode(
                        CanonicalSession.Touch.self, from: frame.payload))
                case .action:
                    session.actions.append(try d.decode(
                        CanonicalSession.Action.self, from: frame.payload))
                case .terminal:
                    terminal = try d.decode(SessionJournal.Terminal.self,
                                            from: frame.payload)
                }
            }
        } catch {
            return .failure(.init(url: url, reason: "frame çözülemedi: \(error)"))
        }

        if let t = terminal {
            // Tanınmayan sebep sessizce `.invalid`'e düşmüyor: bozuk bir yazıcı
            // "geçersiz deneme" gibi görünüp abort oranını bozardı.
            guard let status = CanonicalSession.Status(rawValue: t.reason) else {
                return .failure(.init(url: url,
                                      reason: "tanınmayan terminal sebebi: \(t.reason)"))
            }
            session.status = status
            session.endedAt = session.startedAt.addingTimeInterval(t.at)
            session.finalText = t.finalText
            session.note = t.note
            session.documentBaselineKnown = t.documentBaselineKnown

            // Terminal, katlanmış durumun **özetini** de taşıyor. İkisi
            // ayrışıyorsa ya yazıcı ya okuyucu yanlış — hangisi olduğunu
            // bilmiyoruz ama sessizce birini seçmek en kötüsü.
            let state = SessionEventReducer.reduce(session)
            if state.cursor != t.cursor {
                return .failure(.init(url: url,
                                      reason: "cursor uyuşmuyor: kayıt \(t.cursor),"
                                        + " türetim \(state.cursor)"))
            }
            if state.violations.count != t.violations.count {
                return .failure(.init(url: url,
                                      reason: "ihlal sayısı uyuşmuyor: kayıt "
                                        + "\(t.violations.count), türetim "
                                        + "\(state.violations.count)"))
            }
            // `promptTokenCount` decode ediliyordu ama **hiçbir yerde
            // kullanılmıyordu**. Terminal `completed` derken cursor hedef
            // sayısına eşit değilse kayıt kendi tamamlanma iddiasını
            // yalanlıyor: motor bunu yazma anında ölçüyor, okuyucu da
            // doğrulamak zorunda — yoksa elle kurulmuş bir terminal
            // tamamlanmamış bir denemeyi tamamlanmış gösterirdi.
            if status == .completed, t.promptTokenCount >= 0,
               t.cursor != t.promptTokenCount {
                return .failure(.init(url: url,
                                      reason: "completed ama cursor \(t.cursor),"
                                        + " hedef \(t.promptTokenCount)"))
            }
            if state.unverifiable != t.unverifiable {
                return .failure(.init(url: url,
                                      reason: "doğrulanamaz listesi uyuşmuyor"))
            }
        } else if !loaded.truncatedTail, session.status != .recording {
            // Terminal yok ama durum `recording` değil: başlangıç frame'i
            // yalan söylüyor.
            return .failure(.init(url: url,
                                  reason: "terminalsiz kayıt \(session.status) diyor"))
        }

        return .success(.init(url: url, origin: .journal, session: session,
                              truncatedTail: loaded.truncatedTail))
    }

    // MARK: - Bakım

    /// Varsayılan dizindeki kayıtlar.
    public static func list() -> Listing { list(in: directory) }

    /// Not dosyasının yolu.
    ///
    /// Uzantı **korunuyor** (`a.bkj` → `a.bkj.bknote`): atıldığında `a.json` ve
    /// `a.bkj` aynı nota bağlanıyordu — birine not eklemek ikisinde görünüyor,
    /// birini silmek diğerinin notunu siliyordu.
    private static func annotationURL(for record: URL) -> URL {
        record.appendingPathExtension(annotationExtension)
    }

    private static func readAnnotation(for record: URL) -> String? {
        guard let data = try? Data(contentsOf: annotationURL(for: record)),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Kayda **sonradan** not ekler ya da siler.
    ///
    /// Günlüğe dokunmuyor: append-only konteyner değişmez ve notun sonradan
    /// eklendiği bilgisi ancak ayrı bir dosyada saklanınca korunuyor.
    public static func setAnnotation(_ text: String?, for entry: Entry) throws {
        let url = annotationURL(for: entry.url)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // Boş not **yok** demek; boş dosya bırakmak "yazdı ama bir şey
            // söylemedi" gibi görünürdü.
            try AtomicFile.removeIfExists(url)
            return
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Tek bir kaydı siler — **kullanıcının silme hakkı toptan** (§12.9).
    ///
    /// Hangi biçim olduğunu bilmesi gerekmiyor: `Entry` kendi konumunu
    /// taşıyor ve iki uzantı da aynı yoldan siliniyor.
    public static func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.url)
        // Yan dosya da gidiyor: kaydı silip notunu bırakmak, sahibi olmayan bir
        // yorum bırakmak olurdu (§12.9 silme hakkı toptan).
        // Not silinemezse **söyleniyor**: `try?` ile yutmak, sahibi olmayan bir
        // yorumu sessizce bırakmaktı (§12.9 silme hakkı toptan).
        try AtomicFile.removeIfExists(annotationURL(for: entry.url))
    }

    /// Bütün kayıtları siler.
    public static func deleteAll() throws {
        for entry in list().entries { try delete(entry) }
    }

    /// Bu hata "dosya/dizin yok" mu?
    ///
    /// Hem Cocoa hem POSIX alanı kontrol ediliyor: `FileManager` çağrıya göre
    /// birini ya da diğerini veriyor ve yalnız birine bakmak, aynı olgunun
    /// yarısını kaçırmak olurdu.
    private static func isNoSuchFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoSuchFileError
            || error.code == NSFileNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        // Cocoa hatası POSIX'i **sarmalıyor**: kök sebep alt hatada duruyor.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isNoSuchFile(underlying)
        }
        return false
    }

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
