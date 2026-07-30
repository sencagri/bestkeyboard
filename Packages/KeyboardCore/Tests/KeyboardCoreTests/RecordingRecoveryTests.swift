import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Yarım kalmış kaydın kapatılması — §12.6.
///
/// **Cihazda gözlenen durum.** Uygulama arka planda öldürülünce terminal frame
/// hiç yazılmıyor ve kayıt sonsuza dek `recording` kalıyor: ne tamamlanmış ne
/// vazgeçilmiş sayılabiliyor, yani vazgeçme oranının hangi kovasına gireceği
/// belirsiz. Bu testler kurtarmanın olguyu **türetip** yazdığını, uyduramadığı
/// yerde ise dosyaya dokunmadığını sınıyor.
@MainActor
@Suite("Yarım kalmış kaydı kapatma")
struct RecordingRecoveryTests {

    private typealias Support = RecordingTestSupport

    private func descriptor(prompt: [String]) -> CanonicalSession {
        CanonicalSession(
            attemptID: "recover", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt), alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: Support.unconfigured(policy: .calibration),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    /// Terminal **yazılmadan** kesilen bir kayıt üretir.
    ///
    /// `finish` çağrılmıyor: süreç öldürülmüş gibi davranıyoruz.
    private func abandonedRecording(in dir: URL,
                                    words: [String] = ["kalem", "ev"])
        throws -> (url: URL, text: String) {
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(
            writer: writer,
            coordinator: InputCoordinator(layout: Support.layout),
            layout: Support.layout)
        let doc = Support.Doc()
        try engine.begin(descriptor(prompt: words), at: 0)
        try RecordingTestSupport.configure(engine)

        var id = 0
        var clock: TimeInterval = 0
        for word in words {
            for ch in word {
                clock += 0.1
                try engine.record(Support.touch(id, char: ch, t: clock))
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: String(ch),
                                                          shifted: false),
                                         touchID: id, timestamp: clock), into: doc)
                id += 1
            }
            clock += 0.1
            try engine.perform(.init(command: .space, timestamp: clock), into: doc)
        }
        let url = dir.appendingPathComponent("abandoned.bkj")
        try writer.data.write(to: url)
        return (url, doc.text)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    @Test("Kesilen kayıt interrupted olarak kapanıyor")
    func staleRecordingIsClosedAsInterrupted() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, text) = try abandonedRecording(in: dir)

        // Kapatmadan önce: sayılamaz bir kayıt.
        #expect(RecordingLibrary.list(in: dir).entries.first?.session.status
                == .recording)
        #expect(RecordingLibrary.stale(in: dir).count == 1)

        let outcome = RecordingRecovery.closeStale(in: dir)
        #expect(outcome.skipped.isEmpty, "\(outcome.skipped)")
        #expect(outcome.closed.count == 1)
        // `/var` ile `/private/var` aynı yer: sembolik bağ çözülüyor, yoksa
        // test dosya sistemi ayrıntısı yüzünden kırmızı olurdu.
        #expect(outcome.closed.first?.url.resolvingSymlinksInPath()
                == url.resolvingSymlinksInPath())
        // Nihai metin **türetildi**: mutasyon zincirinin zorunlu sonucu.
        #expect(outcome.closed.first?.finalText == text)

        // Kapatıldıktan sonra: okuyucu kaydı kabul ediyor ve durumu doğru.
        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        let entry = try #require(listing.entries.first)
        #expect(entry.session.status == .interrupted)
        #expect(entry.session.finalText == text)
        // Okuyucunun çapraz doğrulaması (cursor, ihlal, doğrulanamaz) geçti —
        // geçmese `failures` dolu olurdu. Yani yazdığımız özet türetimle uyuşuyor.
        #expect(entry.session.endedAt != nil)
        #expect(SessionValidator.validate(entry.session).isEmpty,
                "\(SessionValidator.validate(entry.session))")
        // Belge zinciri hâlâ tutarlı: `finalText` karşılaştırması artık koşuyor
        // (terminalsiz kayıtta muaftı) ve geçiyor.
        #expect(try DocumentReconstruction.replay(entry.session)
                == .complete(text))
        // `stale` listesi boşaldı.
        #expect(RecordingLibrary.stale(in: dir).isEmpty)
    }

    /// İkinci koşu **hiçbir şey yapmıyor**: terminal değişmez.
    @Test("İkinci kurtarma koşusu no-op")
    func secondRunIsANoOp() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try abandonedRecording(in: dir)
        _ = RecordingRecovery.closeStale(in: dir)
        let after = try Data(contentsOf: url)

        let second = RecordingRecovery.closeStale(in: dir)
        #expect(second.closed.isEmpty)
        #expect(second.skipped.isEmpty)
        #expect(try Data(contentsOf: url) == after, "dosya değişmemeli")
    }

    /// Terminali olan bir günlüğe ekleme **reddediliyor**.
    ///
    /// Kurtarma bu yola girmiyor (terminal varsa kayıt `stale` değil) ama kuralı
    /// yazıcının kendisi uygulamak zorunda: değişmezliği çağıranın dikkatine
    /// bırakmak, ikinci bir terminalin yazılmasına açık kapı olurdu.
    @Test("Terminali olan günlüğe ekleme reddediliyor")
    func appendingToAClosedJournalIsRejected() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try abandonedRecording(in: dir)
        _ = RecordingRecovery.closeStale(in: dir)

        #expect(throws: JournalWriteError.appendAfterTerminal(.terminal)) {
            _ = try FileJournalWriter(appendingTo: url)
        }
    }

    /// **Yarım kuyruk kapatılmıyor.**
    ///
    /// Bozuk baytların arkasına sağlam bir frame koymak, okuyucunun "ortada
    /// bozuk frame" görüp **kaydın tamamını** reddetmesine yol açardı.
    /// Kurtarmanın veri kaybetmesi kabul edilemez.
    @Test("Yarım kuyruklu kayıt kapatılmıyor")
    func truncatedTailIsNotClosed() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try abandonedRecording(in: dir)
        // Son frame'in ortasından kes.
        var data = try Data(contentsOf: url)
        data.removeLast(5)
        try data.write(to: url)
        #expect(RecordingLibrary.list(in: dir).entries.first?.truncatedTail == true)

        let outcome = RecordingRecovery.closeStale(in: dir)
        #expect(outcome.closed.isEmpty)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.reason.contains("yarım kalmış") == true)
        // Dosya **dokunulmadı**: elde kalan veri korunuyor.
        #expect(try Data(contentsOf: url) == data)
    }

    /// v2 JSON kayıtlar dokunulmuyor.
    ///
    /// Yerinde değiştirmek eski biçimi yeniden yazmak olurdu; append-only
    /// konteyner değiller.
    @Test("Eski JSON kaydı kurtarma dışında")
    func legacyJSONIsSkipped() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Yazıcının **kendi tipiyle** üretiliyor: elle kurulmuş bir JSON sözlüğü
        // şema kayınca sessizce geçersiz olur ve testi hiçbir şeyi sınamaz hâle
        // getirirdi.
        var legacy = TypingSession(
            attemptID: "old", participantID: "p", sessionOrdinal: 0,
            condition: .behavior, promptID: "p", promptText: "ev",
            promptSource: .builtin, split: "train", alignmentSource: .sequential,
            startedAt: Date(timeIntervalSince1970: 0), posture: .init(),
            engine: .init(buildConfiguration: "Release", appVersion: "1",
                          packs: [], beamWidth: 128, oovTheta: 17,
                          suggestionWindow: 3, autoCorrectsOutOfVocabulary: true,
                          calibration: .init(applied: false, strongSamples: 0,
                                             globalX: 0, globalY: 0, rowX: [],
                                             rowY: [], keyX: [], keyY: [],
                                             biasX: [], biasY: []),
                          learningFrozen: true, codeRevision: "x",
                          initialLanguage: nil),
            geometry: .init(layoutID: "tr-q", boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
        // v2'nin "hâlâ açık" durumu; migrasyon onu `.recording` yapıyor.
        legacy.status = .inProgress
        try SessionCodec.encoder.encode(legacy)
            .write(to: dir.appendingPathComponent("old.json"))

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        #expect(RecordingLibrary.stale(in: dir).count == 1)

        let outcome = RecordingRecovery.closeStale(in: dir)
        #expect(outcome.closed.isEmpty)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.reason.contains("v2 JSON") == true)
    }
}
