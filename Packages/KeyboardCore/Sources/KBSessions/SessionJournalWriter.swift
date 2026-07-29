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
        try write(SessionJournal.encode(frame), durable: durable)
        if frame.type == .terminal { terminalWritten = true }
    }

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
        if durable { durableOffsets.append(data.count) }
    }
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
        guard fm.createFile(atPath: url.path,
                            contents: SessionJournal.header(schema: schema),
                            // Ham dokunma koordinatı kişisel veri (§12.9):
                            // cihaz kilitliyken okunamamalı.
                            attributes: [.protectionKey:
                                            FileProtectionType.completeUnlessOpen])
        else {
            throw JournalWriteError.ioFailure("dosya oluşturulamadı: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        super.init()
        try fullSync()
        try syncParentDirectory()
    }

    public override func write(_ bytes: Data, durable: Bool) throws {
        do { try handle.write(contentsOf: bytes) }
        catch { throw JournalWriteError.ioFailure("\(error)") }
        if durable { try fullSync() }
    }

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
