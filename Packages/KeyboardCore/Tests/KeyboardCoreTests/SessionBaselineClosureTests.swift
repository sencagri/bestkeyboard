import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions

/// **Baseline kapanışı.** `SessionBaselineTests` v2 yolunun *bugünkü* davranışını
/// donduruyor ve A1/A3'ü `withKnownIssue` ile kırmızı ama başarısız değil hâlde
/// tutuyor. Buradaki testler aynı iki senaryoyu **v3 zincirinden** geçirip
/// doğrusunu iddia ediyor.
///
/// ## Neden ayrı bir dosya
///
/// v2 karakterizasyonunu silmek kanıtı yok etmek olurdu: eski kayıtlar hâlâ
/// diskte ve `SessionMigration` onları okuyor, dolayısıyla o yolun davranışı
/// yaşamaya devam ediyor. Düzeltmenin kanıtı "eski test kaldırıldı" değil,
/// "aynı senaryo yeni yolda başka sonuç veriyor".
///
/// ## Neden `withKnownIssue` yok
///
/// Bu testler geçmek **zorunda**. Geçmiyorlarsa v3 zinciri A1/A3'ü kapatmıyor
/// demektir ve bunu bir known-issue arkasına koymak, kapatılmamış bir hatayı
/// kapatılmış göstermek olurdu.
@MainActor
@Suite("Baseline kapanışı — A1 ve A3 v3 zincirinde")
struct SessionBaselineClosureTests {

    private typealias Support = RecordingTestSupport

    private func descriptor(prompt: [String]) -> CanonicalSession {
        CanonicalSession(
            attemptID: "closure", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt), alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: .unconfigured(),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    /// Kayıt sürücüsü — dokunma **komuttan önce**, tek serileştirilmiş giriş.
    @MainActor
    private final class Driver {
        let engine: RecordingEngine
        let doc = RecordingTestSupport.Doc()
        let writer = InMemoryJournalWriter()
        private var nextTouch = 0
        private var clock: TimeInterval = 0

        init(prompt: [String], descriptor: CanonicalSession) throws {
            engine = RecordingEngine(
                writer: writer,
                coordinator: InputCoordinator(layout: RecordingTestSupport.layout),
                layout: RecordingTestSupport.layout)
            try engine.begin(descriptor, at: 0)
            // Kalibrasyon politikası: düzeltme **uygulanmıyor**, dolayısıyla
            // `literal == committed` ve etiket protokolden `strong`. Davranış
            // politikasıyla koşmak testin ölçtüğü şeyi (dokunma sayımı)
            // düzeltme kararına bağımlı yapardı.
            try RecordingTestSupport.configure(engine, policy: .calibration)
        }

        func type(_ text: String) throws {
            for ch in text {
                clock += 0.1
                let t = RecordingTestSupport.touch(nextTouch, char: ch, t: clock)
                try engine.record(t)
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: String(ch),
                                                          shifted: false),
                                         touchID: nextTouch, timestamp: clock),
                                   into: doc)
                nextTouch += 1
            }
        }

        func command(_ c: ReplayCommand) throws {
            clock += 0.1
            try engine.perform(.init(command: c, timestamp: clock), into: doc)
        }
    }

    // MARK: - A1: newline artık bir sınır

    /// **v2 davranışı** (`SessionBaselineTests.newlineLeaksTouches`): `.ret`
    /// token'ı kapatıyor ama kayda commit yazmıyor; importer `newline`'ı
    /// tanımadığı için `bir`in üç dokunması `iki`ye sızıyor ve tek token
    /// altı dokunma taşıyor.
    ///
    /// **v3 davranışı:** `newline` `ReplayCommand`'ın kapalı kümesinde, reducer
    /// onu sınır olayı olarak katlıyor ve `RecordingEngine` commit'i yazıyor.
    @Test("A1 — newline kendi token'ını üretiyor, dokunma sızmıyor")
    func newlineIsABoundary() throws {
        let d = try Driver(prompt: ["bir", "iki"],
                           descriptor: descriptor(prompt: ["bir", "iki"]))
        try d.type("bir")
        try d.command(.newline)
        try d.type("iki")
        try d.command(.space)

        let s = d.engine.state
        #expect(s.tokens.count == 2, "newline bir token sınırı")
        #expect(s.tokens.map(\.committed) == ["bir", "iki"])
        // Sızma testi tam burada: her token **yalnız kendi** dokunmalarını
        // taşıyor. v2'de birinci token yoktu ve ikincisi altı dokunma sayıyordu.
        #expect(s.tokens.map(\.atoms.count) == [3, 3])
        // `touchCountAgrees` kayıt ile türetimin aynı şeyi söylediğini sınıyor;
        // v2'de bu bayrak `false` idi ve sızmayı yakalayan tek şey oydu.
        #expect(s.tokens.allSatisfy { $0.touchCountAgrees })
        #expect(s.cursor == 2, "iki hedef token, iki ilerleme")
        #expect(s.violations.isEmpty)
        #expect(s.dropped.isEmpty, "hiçbir dokunma gerekçesiz düşmedi")
        #expect(d.doc.text == "bir\niki ")

        // Kalibrasyon: iki token da hedefiyle birebir → 6 örnek.
        let session = try recorded(d)
        let ext = CalibrationExtraction.extract(session, layout: Support.layout)
        #expect(ext.excludedSession == nil)
        #expect(ext.samples.count == 6, "3 + 3 harf, sızma yok")
    }

    // MARK: - A3: geri çekilen deneme iki kez sayılmıyor

    /// **v2 davranışı** (`SessionBaselineTests.retractedAttemptEntersCalibration`):
    /// sınırda backspace yalnız `wordIndex`'i geri alıyor, önceki commit kayıtta
    /// temiz token olarak duruyor. Sonuç: beş harflik tek kelime kalibrasyona
    /// **on** güçlü örnek veriyor ve aynı hedefe iki token hizalanıyor.
    ///
    /// **v3 davranışı:** ayırıcıyı silmek token'ı `restoreToken` ile **yeniden
    /// açıyor**; reducer onu kapalı token listesinden çıkarıp dokunmalarını
    /// `pending`'e alıyor ve cursor'ı `cursorBefore`'a döndürüyor. Yeniden
    /// commit edildiğinde ortada tek token var — aynı dokunmalar iki kez
    /// sayılamıyor.
    @Test("A3 — geri açılan token iki kez sayılmıyor")
    func restoredTokenIsCountedOnce() throws {
        let d = try Driver(prompt: ["kalem", "ev"],
                           descriptor: descriptor(prompt: ["kalem", "ev"]))
        try d.type("kalem")
        try d.command(.space)
        #expect(d.engine.state.tokens.count == 1)
        #expect(d.engine.state.cursor == 1)

        // Sınırda backspace: ayırıcı silinir, token yeniden açılır.
        try d.command(.backspaceTap)
        let mid = d.engine.state
        #expect(mid.tokens.isEmpty, "token kapalı listeden çıktı")
        #expect(mid.pending.count == 5, "dokunma kanıtı geri geldi")
        #expect(mid.cursor == 0, "cursor commit öncesine döndü")
        // Geri açma sapma **başlatmıyor**: aynı dokunmalar, aynı cursor.
        // Başlatsaydı etiket zayıflar ve doğru bir deneme kalibrasyondan
        // gereksiz yere düşerdi.
        #expect(mid.diverged == false)
        #expect(mid.violations.isEmpty)

        // Kullanıcı aynı kelimeyi tekrar kapatıyor.
        try d.command(.space)
        let s = d.engine.state
        #expect(s.tokens.count == 1, "hâlâ tek token — deneme çoğalmadı")
        #expect(s.tokens[0].atoms.count == 5)
        #expect(s.tokens[0].touchCountAgrees)
        #expect(s.cursor == 1, "tek hedef tüketildi; v2'de iki token bir hedefe bakıyordu")
        #expect(s.violations.isEmpty)

        let session = try recorded(d)
        let ext = CalibrationExtraction.extract(session, layout: Support.layout)
        #expect(ext.excludedSession == nil)
        // A3'ün ta kendisi: v2 on örnek üretiyordu.
        #expect(ext.samples.count == 5, "beş harf, beş örnek")
        #expect(ext.excludedDiverged == 0)
        #expect(ext.excludedWeakLabel == 0, "etiket protokolden strong kaldı")
    }

    /// Geri açıp **düzelten** kullanıcı: yanlış harfin dokunması örneğe
    /// girmiyor, doğru harfin dokunması giriyor.
    ///
    /// A3'ün asıl zararı buydu: kullanıcının kendi hatası diye geri aldığı
    /// dokunma, kalibrasyona *hedef tuşun* örneği olarak giriyordu.
    @Test("A3b — geri açıp düzeltilen token yalnız kalan dokunmaları taşıyor")
    func retractedAndFixedTokenDropsTheWrongTouch() throws {
        let d = try Driver(prompt: ["kalem"],
                           descriptor: descriptor(prompt: ["kalem"]))
        try d.type("kalen")            // son harf yanlış
        try d.command(.space)
        try d.command(.backspaceTap)   // ayırıcı silindi, token açıldı
        try d.command(.backspaceTap)   // yanlış harf silindi
        #expect(d.engine.state.pending.count == 4)
        try d.type("m")
        try d.command(.space)

        let s = d.engine.state
        #expect(s.tokens.count == 1)
        #expect(s.tokens[0].committed == "kalem")
        #expect(s.tokens[0].atoms.count == 5, "4 kalan + 1 yeni")
        #expect(s.tokens[0].touchCountAgrees)
        // Yanlış harfin dokunması **gerekçeli** düştü; sessizce kaybolmadı.
        #expect(s.dropped.count == 1)
        #expect(s.dropped[0].reason == .deletedBeforeCommit)

        let session = try recorded(d)
        let ext = CalibrationExtraction.extract(session, layout: Support.layout)
        #expect(ext.samples.count == 5)
        // `n` tuşuna basılıp `m` hedeflenen dokunma yok: silinen dokunma hiç
        // örneğe girmedi, dolayısıyla `recoveredDrifted` de saymıyor.
        #expect(ext.recoveredDriftedTouches == 0)
    }

    // MARK: - Yardımcı

    /// Kaydı **diskteki hâlinden** okur.
    ///
    /// Motorun bellekteki `state`'ini kullanmak daha kolay olurdu ama o zaman
    /// test yazıcı-okuyucu zincirini atlar: şema kaymasını görmeyen bir
    /// doğrulama, kaydın tekrar okunabildiğini kanıtlamaz.
    private func recorded(_ d: Driver) throws -> CanonicalSession {
        _ = try d.engine.finish(.completed, at: 99, finalText: d.doc.text)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.bkj")
        try d.writer.data.write(to: url)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        let entry = try #require(listing.entries.first)
        // Yapısal doğrulama da burada: senaryo geçerli bir kayıt üretmiyorsa
        // kalibrasyon sayıları hiçbir şey kanıtlamaz.
        #expect(SessionValidator.validate(entry.session).isEmpty)
        return entry.session
    }
}
