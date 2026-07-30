import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Günlüğe frame ekleyen tek yazıcı — plan v8 §2.6, §2.7.
///
/// ## Neden protokol
///
/// Dayanıklılık kuralları (fsync, parent-directory fsync, terminal sonrası
/// reddetme) **davranış**; dosya sistemi ise ayrıntı. Testler gerçek diske
/// yazmadan bu davranışı sınayabilmeli, yoksa kurallar yalnız elle
/// doğrulanabilir kalır.
public protocol SessionJournalWriter: AnyObject {
    /// Frame'i ekler.
    ///
    /// - Parameter durable: dönmeden önce fsync'lenir.
    /// - Throws: terminal frame'den **sonra** ekleme denenirse.
    func append(_ frame: SessionJournal.Frame, durable: Bool) throws
}

public enum JournalWriteError: Error, Equatable, CustomStringConvertible {
    /// Terminal yazıldıktan sonra ekleme.
    ///
    /// Geç bir callback (dokunma, `engineConfigured`, finalize) terminalden
    /// sonra frame yazabiliyordu; terminal **değişmez** olmalı, yoksa
    /// tamamlanmış bir deneme sonradan büyür ve `completed` koşulu geçmişe
    /// dönük olarak bozulur.
    case appendAfterTerminal(SessionJournal.FrameType)
    case ioFailure(String)

    public var description: String {
        switch self {
        case let .appendAfterTerminal(t):
            return "terminalden sonra \(t) yazılamaz"
        case let .ioFailure(d):
            return "yazma hatası: \(d)"
        }
    }
}

/// Terminal sonrası eklemeyi reddeden ortak taban.
///
/// Kural iki yazıcıda ayrı ayrı yazılsaydı biri güncellenip diğeri unutulurdu;
/// bellek içi yazıcı da dosya yazıcısıyla **aynı** sözleşmeyi uygulamak
/// zorunda, yoksa testler gerçekte olmayan bir davranışı doğrular.
open class BaseJournalWriter: SessionJournalWriter {
    public private(set) var terminalWritten = false

    public init() {}

    public final func append(_ frame: SessionJournal.Frame, durable: Bool) throws {
        guard !terminalWritten else {
            throw JournalWriteError.appendAfterTerminal(frame.type)
        }
        // Yazma **ile** dayanıklılık ayrı: baytlar dosyaya gittikten sonra
        // fsync başarısız olursa terminal yine de dosyada duruyor. Bayrağı
        // fsync'ten sonra kurmak, `finish`'in yeniden denenmesinde **ikinci**
        // bir terminal yazılmasına izin veriyordu.
        try write(SessionJournal.encode(frame), durable: false)
        if frame.type == .terminal { terminalWritten = true }
        if durable { try synchronize() }
    }

    /// Yazılanı kalıcılaştırır. Varsayılan: yapacak bir şey yok.
    open func synchronize() throws {}

    /// Alt sınıf yalnız baytları yazar; sıra kuralı tabanda.
    open func write(_ bytes: Data, durable: Bool) throws {
        fatalError("alt sınıf uygulamalı")
    }
}

/// Test ve replay için bellek içi yazıcı.
public final class InMemoryJournalWriter: BaseJournalWriter {
    public private(set) var data: Data
    /// Hangi eklemelerin fsync istendiği — dayanıklılık kuralları böyle
    /// sınanıyor, gerçek diske yazmadan.
    public private(set) var durableOffsets: [Int] = []

    public init(schema: UInt16 = UInt16(CanonicalSession.currentSchema)) {
        self.data = SessionJournal.header(schema: schema)
        super.init()
    }

    public override func write(_ bytes: Data, durable: Bool) throws {
        data.append(bytes)
    }

    public override func synchronize() throws {
        if shouldFailSync {
            // Hata **yazmadan sonra** geliyor: baytlar dosyada, dayanıklılık
            // yok. Testler bu ayrımı böyle sınıyor.
            throw JournalWriteError.ioFailure("fsync (enjekte edilmiş hata)")
        }
        durableOffsets.append(data.count)
    }

    /// Fault injection: `synchronize` başarısız olsun.
    public var shouldFailSync = false
}

/// Diske yazan gerçek yazıcı.
///
/// ## Dayanıklılığın operasyonel tanımı
///
/// Normal `write` tamamlanması dayanıklılık **değildir**: veri sayfa
/// önbelleğinde durur ve güç kaybında kaybolur. Sözleşme §12.6 denemenin
/// *"başlar başlamaz diske düşmesini"* istiyor — çünkü `attemptStarted`
/// kaybolursa vazgeçilen deneme abort oranının **paydasından tamamen düşer**
/// ve kalan küme tarafsız bir popülasyonmuş gibi görünür.
///
/// Bu yüzden iki ayrı fsync gerekiyor:
/// - **Dosya** fsync: içerik kalıcı olsun.
/// - **Üst dizin** fsync: yeni dosyanın *dizin girdisi* kalıcı olsun. Yalnız
///   dosyayı fsync'lemek, dosyanın var olduğunu garanti etmiyor.
///
/// macOS'ta `fsync(2)` sürücü önbelleğini boşaltmıyor; `F_FULLFSYNC` gerekiyor.
public final class FileJournalWriter: BaseJournalWriter {
    private let handle: FileHandle
    private let url: URL

    /// Dosyayı oluşturur, başlığı yazar ve **dizin girdisiyle birlikte**
    /// kalıcılaştırır.
    public init(url: URL,
                schema: UInt16 = UInt16(CanonicalSession.currentSchema)) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Ham dokunma koordinatı kişisel veri (§12.9): cihaz kilitliyken
        // okunamamalı. Dosya koruması **yalnız iOS'ta** var; macOS'ta öznitelik
        // olarak vermek dosya oluşturmayı tamamen başarısız kılıyor
        // (EPERM) — ve replay araçları macOS'ta koşuyor.
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUnlessOpen
        #endif
        guard fm.createFile(atPath: url.path,
                            contents: SessionJournal.header(schema: schema),
                            attributes: attributes)
        else {
            throw JournalWriteError.ioFailure("dosya oluşturulamadı: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        super.init()
        try fullSync()
        try syncParentDirectory()
    }

    /// **Var olan** bir günlüğü eklemek için açar.
    ///
    /// Kurtarma yolu (`RecordingRecovery`) yarım kalmış bir kayda `interrupted`
    /// terminal frame'i ekliyor. Normal `init` bunu yapamaz: `createFile`
    /// mevcut dosyayı **kırpıyor**, yani kurtarmak istediğimiz kaydı silerdi.
    ///
    /// Başlık yeniden yazılmıyor ve dosya doğrulanıyor: yabancı ya da bozuk bir
    /// dosyaya frame eklemek, okunamaz bir kayıt üretip onu "kurtarılmış" diye
    /// göstermek olurdu. Zaten terminali olan bir günlük de reddediliyor —
    /// terminal değişmez.
    public init(appendingTo url: URL) throws {
        self.url = url
        guard let data = try? Data(contentsOf: url) else {
            throw JournalWriteError.ioFailure("okunamadı: \(url.path)")
        }
        switch SessionJournal.load(data) {
        case let .failure(e):
            throw JournalWriteError.ioFailure("günlük değil: \(e.description)")
        case let .success(loaded):
            if loaded.frames.last?.type == .terminal {
                throw JournalWriteError.appendAfterTerminal(.terminal)
            }
            // Yarım kalan kuyruk **kırpılmıyor**: dosyanın sonuna yazmak bozuk
            // baytların arkasına sağlam bir frame koymak olur ve okuyucu artık
            // ortadaki bozuk frame'i görüp kaydın tamamını reddeder. Kurtarma
            // veri kaybetmemeli — bu dosya olduğu gibi kalıyor.
            if loaded.truncatedTail {
                throw JournalWriteError.ioFailure(
                    "son frame yarım kalmış; ekleme kaydı okunamaz yapardı")
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        super.init()
    }

    public override func write(_ bytes: Data, durable: Bool) throws {
        do { try handle.write(contentsOf: bytes) }
        catch { throw JournalWriteError.ioFailure("\(error)") }
    }

    public override func synchronize() throws { try fullSync() }

    public func closeFile() throws { try handle.close() }

    private func fullSync() throws {
        // `fsync(2)` macOS'ta sürücü önbelleğini boşaltmıyor. `F_FULLFSYNC`
        // desteklenmezse (bazı dosya sistemleri) `fsync`'e düşüyoruz —
        // sessizce hiç senkronlamamaktan iyi.
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            guard fsync(handle.fileDescriptor) == 0 else {
                throw JournalWriteError.ioFailure("fsync başarısız: \(errno)")
            }
        }
    }

    private func syncParentDirectory() throws {
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else {
            throw JournalWriteError.ioFailure("dizin açılamadı: \(dir.path)")
        }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else {
            throw JournalWriteError.ioFailure("dizin fsync başarısız: \(errno)")
        }
    }
}
