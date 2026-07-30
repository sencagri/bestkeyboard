import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

/// Üretimde yazarken **son dilimi** bellekte tutan kaydedici.
///
/// ## Ne çözüyor
///
/// Kullanıcının derdi şu: WhatsApp'ta bir şey yazarken sorun çıkıyor — kelime
/// tanınmıyor, düzeltme doğruyu bozuyor, boşluk çalışmıyor — ve o an elde hiçbir
/// kanıt olmuyor. Kayıt ekranına geçip yeniden üretmek mümkün değil; sorun zaten
/// o bağlamda oluştu.
///
/// ## Neden sürekli yazmıyor
///
/// Yazılan her şeyi diske yazmak, tanım gereği yazılan her şeyi saklamak demek.
/// Burada tampon **bellekte** duruyor ve yalnız kullanıcı düğmeye bastığında
/// diske düşüyor. İstenmeyen hiçbir şey kalıcı olmuyor.
///
/// ## Neden düşürmek yerine devrediyor
///
/// Halka tamponun klasik hâli en eskiyi düşürür. Bir günlükte bu **bozuk kayıt**
/// üretir: ortadan frame düşünce katlama boşluk görür, token sınırları kayar ve
/// dosya kendi anlattığından başka bir şeyi tarif eder. Bunun yerine sınıra
/// gelince **yeni bir deneme** başlıyor: eski bağlam kayboluyor ama elde kalan
/// her zaman geçerli, kendi başına okunabilir bir kayıt.
///
/// Kaydın nerede başladığı da dürüst oluyor — `startedAt` devretme anını
/// gösteriyor, "her şeyin başı" değil.
@MainActor
public final class ProductionRecorder {

    /// Bellekte tutulacak üst sınır.
    ///
    /// Bayt cinsinden: frame sayısı yanıltıcı olurdu (bir `action` frame'i
    /// aday listesiyle birlikte bir `touch` frame'inin katı). Uzantının bellek
    /// bütçesi dar ve klavye öldürülürse kullanıcı klavyesini kaybeder.
    public static let byteCap = 512 * 1024

    public private(set) var engine: RecordingEngine
    private var writer: InMemoryJournalWriter
    private let makeDescriptor: (String) -> CanonicalSession
    private let makeEngine: () -> (InMemoryJournalWriter) -> RecordingEngine
    private let configure: (RecordingEngine) throws -> Void
    /// Deneme başlarken belgede duran metin.
    ///
    /// **Saklanmıyor**, yalnız farkın hesaplandığı nokta: host'ta zaten yazılı
    /// olan içerik mutasyonlara girmesin diye. Her devretmede yeniden
    /// soruluyor — kullanıcı arada başka bir alana geçmiş olabilir.
    private let baseline: () -> String

    /// Devretme sayısı — kaç kez bağlam kaybedildi.
    ///
    /// Raporlanıyor: sessiz devretme, kullanıcının "hepsi kaydedildi"
    /// sanmasına yol açardı.
    public private(set) var rollovers = 0

    /// - Parameter makeDescriptor: her devretmede yeni bir deneme tanımı
    ///   (yeni `attemptID`, yeni `startedAt`).
    /// - Parameter build: verilen yazıcıyla motoru kuran fabrika.
    /// - Parameter configure: motoru paketlerle yapılandıran çağrı.
    public init(makeDescriptor: @escaping (String) -> CanonicalSession,
                build: @escaping (InMemoryJournalWriter) -> RecordingEngine,
                configure: @escaping (RecordingEngine) throws -> Void,
                baseline: @escaping () -> String = { "" }) throws {
        self.baseline = baseline
        self.makeDescriptor = makeDescriptor
        self.makeEngine = { build }
        self.configure = configure
        self.writer = InMemoryJournalWriter()
        self.engine = build(writer)
        try start()
    }

    private func start() throws {
        try engine.begin(makeDescriptor(Self.attemptID()), at: Self.now,
                         baseline: baseline())
        try configure(engine)
    }

    /// Yeni bir denemeye geçer; eski tampon **atılır**.
    public func rollOver() throws {
        writer = InMemoryJournalWriter()
        engine = makeEngine()(writer)
        try start()
        rollovers += 1
    }

    /// Sınıra gelindiyse devreder.
    ///
    /// Her eylemden **sonra** çağrılıyor: eylemin ortasında devretmek, yarım bir
    /// mutasyonu iki denemeye bölerdi.
    public func rollOverIfNeeded() throws {
        guard writer.data.count > Self.byteCap else { return }
        try rollOver()
    }

    /// Tamponu diske yazar ve yeni bir denemeye geçer.
    ///
    /// - Parameter note: kullanıcının "ne oldu" anlatısı.
    /// - Returns: yazılan dosya.
    @discardableResult
    public func capture(note: String?, to directory: URL) throws -> URL {
        // Terminal **bellekteki** yazıcıya gidiyor; dosya ondan sonra tek
        // parça yazılıyor. Diske parça parça yazmak, yakalanmayan bir dilimin
        // de diskte iz bırakması demekti.
        _ = try engine.finish(.captured, at: Self.now,
                              finalText: engine.documentText, note: note)
        let data = writer.data
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "\(Self.attemptID()).\(RecordingLibrary.journalExtension)")
        try data.write(to: url, options: .atomic)
        try rollOver()
        return url
    }

    /// `UITouch.timestamp` ile **aynı taban**.
    ///
    /// Duvar saati kullanmak kaydın zaman çizgisini çöpe çeviriyordu; ölçüldü
    /// (`t = −806 576 468`).
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func attemptID() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(UInt32.random(in: 0..<0xFFFF))"
    }
}
