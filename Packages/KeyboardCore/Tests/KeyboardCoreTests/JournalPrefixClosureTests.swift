import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// **Önek kapanışı.** Append-only bir günlüğün her öneki, kendi başına geçerli
/// bir kayıt olmalı.
///
/// ## Neden bu ayrı bir değişmez
///
/// §12.6 denemenin *"başlar başlamaz diske düştüğünü"* şart koşuyor ve güç
/// kaybında elde kalan şey tam olarak bir **önek**. Bunun okunabilir olması
/// tesadüfe bırakılamaz: okunamıyorsa vazgeçilen deneme abort oranının
/// paydasından düşer ve elde kalan küme tarafsız bir popülasyonmuş gibi görünür.
///
/// Ayrı bir test olmasının sebebi, mevcut testlerin **yarım bayt** kırpmayı
/// (frame ortasından kesme) sınaması ama **tam frame** sınırında kesmeyi hiç
/// sınamaması: gerçek kesinti çoğunlukla iki frame arasında oluyor ve orada
/// `truncatedTail` bayrağı bile kalkmıyor — yani sessiz. Sessiz olan şeyin
/// doğru olduğu ayrıca gösterilmek zorunda.
@MainActor
@Suite("Günlük önek kapanışı")
struct JournalPrefixClosureTests {

    private typealias Support = RecordingTestSupport

    private func descriptor(prompt: [String]) -> CanonicalSession {
        CanonicalSession(
            attemptID: "prefix", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt), alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: RecordingTestSupport.unconfigured(policy: .calibration),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    /// Tamamlanmış bir kayıt üretir ve frame'lerini döndürür.
    private func fullRecording() throws
        -> (frames: [SessionJournal.Frame], full: CanonicalSession, text: String) {
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(
            writer: writer,
            coordinator: InputCoordinator(layout: Support.layout),
            layout: Support.layout)
        let doc = Support.Doc()
        try engine.begin(descriptor(prompt: ["kalem", "ev"]), at: 0)
        try RecordingTestSupport.configure(engine)

        var id = 0
        var clock: TimeInterval = 0
        func type(_ text: String) throws {
            for ch in text {
                clock += 0.1
                try engine.record(Support.touch(id, char: ch, t: clock))
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: String(ch),
                                                          shifted: false),
                                         touchID: id, timestamp: clock), into: doc)
                id += 1
            }
        }
        try type("kalem")
        clock += 0.1
        try engine.perform(.init(command: .space, timestamp: clock), into: doc)
        try type("ev")
        clock += 0.1
        try engine.perform(.init(command: .space, timestamp: clock), into: doc)
        _ = try engine.finish(.completed, at: 99, finalText: doc.text)

        let loaded = try #require(try SessionJournal.load(writer.data).get())
        #expect(loaded.truncatedTail == false)
        let listing = try readBack(writer.data)
        return (loaded.frames, try #require(listing.entries.first).session, doc.text)
    }

    private func readBack(_ data: Data) throws -> RecordingLibrary.Listing {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try data.write(to: dir.appendingPathComponent("a.bkj"))
        return RecordingLibrary.list(in: dir)
    }

    /// Frame sınırında kesilmiş **her** önek okunabilir ve tam kaydın bir
    /// önekini anlatıyor.
    @Test("Her frame öneki geçerli bir kayıt")
    func everyFramePrefixIsAValidRecording() throws {
        let (frames, full, _) = try fullRecording()
        #expect(frames.count > 5, "senaryo anlamlı sayıda frame üretmeli")

        // `attemptStarted`'sız önek zaten reddedilmeli (ayrı testi var);
        // burada 1'den başlıyoruz.
        for k in 1..<frames.count {
            var data = SessionJournal.header()
            for f in frames.prefix(k) { data.append(SessionJournal.encode(f)) }

            let listing = try readBack(data)
            #expect(listing.failures.isEmpty,
                    "\(k) frame'lik önek okunamadı: \(listing.failures)")
            guard let entry = listing.entries.first else { continue }

            // Terminal frame yok → durum `recording` kalmalı. Yarım kalmış bir
            // kaydı `completed` göstermek, ölçülmemiş bir denemeyi ölçülmüş
            // saymaktı.
            #expect(entry.session.status == .recording,
                    "\(k): terminalsiz kayıt hâlâ açık olmalı")
            // **Kuyruk kırpılmadı**: kesme tam frame sınırında oldu. Bayrağın
            // burada kalkması, olmayan bir veri kaybını rapor etmek olurdu.
            #expect(entry.truncatedTail == false, "\(k)")

            // Önek olma iddiası: action'lar tam kaydın ilk n'i, birebir.
            let n = entry.session.actions.count
            #expect(n <= full.actions.count)
            #expect(entry.session.actions == Array(full.actions.prefix(n)),
                    "\(k): action önek değil")
            let m = entry.session.touches.count
            #expect(entry.session.touches == Array(full.touches.prefix(m)),
                    "\(k): dokunma önek değil")

            // Katlama da tutarlı olmalı: önek kaydını katlamak, tam kaydın ilk
            // n action'ını katlamakla aynı sonucu vermeli. Vermiyorsa reducer
            // ileriye bakıyor demektir ve canlı `applyIncrementally` yolu
            // sondaki bilgiyi kullanıyor olurdu.
            var expected = SessionEventReducer.State()
            let touchByID = Dictionary(full.touches.map { ($0.touchID, $0) },
                                       uniquingKeysWith: { a, _ in a })
            for a in full.actions.prefix(n) {
                SessionEventReducer.applyIncrementally(a, to: &expected,
                                                       touches: touchByID)
            }
            #expect(SessionEventReducer.reduce(entry.session) == expected, "\(k)")

            // Yapısal doğrulama: önek **geçerli** bir kayıt, eksik değil bozuk
            // değil. `status`/`endedAt` kuralları terminalsiz kayda da uyuyor.
            #expect(SessionValidator.validate(entry.session).isEmpty,
                    "\(k): \(SessionValidator.validate(entry.session))")

            // Kurtarma yolu bunu bulmak zorunda; bulamazsa kayıt sonsuza dek
            // `recording` kalır ve hiçbir sayıma girmez.
            #expect(entry.session.status == .recording)
        }
    }

    /// Önek kaydı **belge türetimini** de sürdürüyor.
    ///
    /// `finalText` yalnız terminalde yazılıyor; terminalsiz bir kayıtta metin
    /// karşılaştırması yapılmıyor ama mutasyon zinciri kendi özetlerini
    /// tutturmak zorunda. Tutturmuyorsa kaydın yarısı doğrulanamaz hâle gelir.
    @Test("Önek kaydında belge zinciri tutarlı")
    func documentChainHoldsOnPrefixes() throws {
        let (frames, full, text) = try fullRecording()
        for k in 1..<frames.count {
            var data = SessionJournal.header()
            for f in frames.prefix(k) { data.append(SessionJournal.encode(f)) }
            guard let entry = try readBack(data).entries.first else { continue }
            let rec = try DocumentReconstruction.replay(entry.session)
            guard case let .complete(t) = rec else {
                Issue.record("\(k): belge türetimi doğrulanamaz döndü")
                continue
            }
            // Türetilen metin tam metnin bir öneki olmalı. Eşit olması yalnız
            // bütün action'lar dahilse beklenir.
            #expect(text.hasPrefix(t), "\(k): '\(t)' tam metnin öneki değil")
        }
        #expect(full.finalText == text)
    }
}
