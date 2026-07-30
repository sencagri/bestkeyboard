import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Üretimde yazarken son dilimi bellekte tutan kaydedici.
///
/// İki iddia sınanıyor ve ikisi de kolayca yanlış yapılabilirdi:
/// **istemediğin hiçbir şey diske yazılmıyor**, ve **elde kalan her zaman
/// geçerli bir kayıt** (halka tamponun klasik hâli ortadan frame düşürüp
/// katlamayı bozardı).
@MainActor
@Suite("Üretim kaydedicisi")
struct ProductionRecorderTests {

    private typealias Support = RecordingTestSupport

    private func descriptor(_ id: String) -> CanonicalSession {
        CanonicalSession(
            attemptID: id, participantID: "p", sessionOrdinal: 0,
            // Üretimde **hedef yok**: hizalama `none`, dolayısıyla kalibrasyon
            // kapısı bu kayıtları zaten eliyor.
            condition: .behavior, status: .recording,
            promptID: "production", promptText: "", promptSource: .manual,
            split: "none", promptTokens: .known(["-"]),
            alignmentSource: .none,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: Support.unconfigured(policy: .behavior),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    private func makeRecorder() throws -> ProductionRecorder {
        try ProductionRecorder(
            makeDescriptor: { self.descriptor($0) },
            build: { writer in
                RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: Support.layout),
                                layout: Support.layout)
            },
            configure: { try RecordingTestSupport.configure($0) })
    }

    private func type(_ text: String, into r: ProductionRecorder,
                      doc: RecordingTestSupport.Doc, from id: inout Int) throws {
        for ch in text {
            let t = ProductionRecorder.now
            try r.engine.record(Support.touch(id, char: ch, t: t))
            try r.engine.perform(.init(command: .letter(baseKey: String(ch),
                                                        display: String(ch),
                                                        shifted: false),
                                       touchID: id, timestamp: t), into: doc)
            id += 1
        }
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d,
                                                withIntermediateDirectories: true)
        return d
    }

    /// **Yakalanmayan hiçbir şey diske düşmüyor.**
    @Test("Yakalamadan önce disk boş")
    func nothingHitsDiskBeforeCapture() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("kalem", into: r, doc: doc, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc)

        #expect(RecordingLibrary.list(in: dir).entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// Yakalanan dilim **okunabilir bir kayıt**.
    @Test("Yakalanan dilim geçerli kayıt")
    func capturedSliceIsAValidRecording() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("kalem", into: r, doc: doc, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc)

        _ = try r.capture(note: "boşluğa bastım ama olmadı", to: dir)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        let entry = try #require(listing.entries.first)
        #expect(entry.session.status == .captured)
        #expect(entry.session.note == "boşluğa bastım ama olmadı")
        #expect(entry.session.finalText == "kalem ")
        #expect(SessionValidator.validate(entry.session).isEmpty,
                "\(SessionValidator.validate(entry.session))")
        // Dokunmalar da kayıtta: "bütün bastığım tuşlarla birlikte".
        #expect(entry.session.touches.count == 5)
        #expect(SessionEventReducer.reduce(entry.session).tokens.count == 1)
    }

    /// Yakalamadan **sonra** tampon boşalıyor: aynı dilim iki kez yazılmıyor.
    @Test("Yakalama tamponu boşaltıyor")
    func captureRollsOver() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc)
        _ = try r.capture(note: nil, to: dir)

        // İkinci yakalama: ilk dilimin eylemlerini **taşımamalı**.
        let doc2 = RecordingTestSupport.Doc()
        try type("ok", into: r, doc: doc2, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc2)
        _ = try r.capture(note: nil, to: dir)

        let entries = RecordingLibrary.list(in: dir).entries
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.session.finalText)) == ["ev ", "ok "])
    }

    /// **Devretme ortadan frame düşürmüyor.**
    ///
    /// Halka tamponun klasik hâli en eskiyi atar; bir günlükte bu bozuk kayıt
    /// üretir — katlama boşluk görür ve dosya kendi anlattığından başka bir şeyi
    /// tarif eder. Devretme yerine yeni bir deneme başlatmak, elde kalanın her
    /// zaman geçerli olmasını sağlıyor.
    @Test("Devretme geçerli kayıt bırakıyor")
    func rollOverLeavesAValidRecording() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        try r.rollOver()
        #expect(r.rollovers == 1)

        // Devretmeden **sonra** yazılanlar yeni denemede.
        let doc2 = RecordingTestSupport.Doc()
        try type("ok", into: r, doc: doc2, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc2)
        _ = try r.capture(note: nil, to: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(entry.session.finalText == "ok ", "eski bağlam taşınmıyor")
        #expect(SessionValidator.validate(entry.session).isEmpty)
        #expect(entry.session.touches.count == 2, "yalnız devretmeden sonrakiler")
    }

    /// Üretim kaydı **kalibrasyona girmiyor**: hedef yok.
    @Test("Yakalanan kayıt kalibrasyona girmiyor")
    func capturedRecordIsNotEligibleForCalibration() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc)
        _ = try r.capture(note: nil, to: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        let ext = CalibrationExtraction.extract(entry.session,
                                                layout: Support.layout)
        #expect(ext.samples.isEmpty)
        #expect(ext.excludedSession == .alignmentNotConstructed(.none))
    }
}
