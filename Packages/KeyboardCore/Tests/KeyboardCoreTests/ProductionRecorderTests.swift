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
            // **Hedef yok**, boş hedef değil.
            split: "none", promptTokens: .notApplicable,
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

    /// **Host'ta zaten duran metin kayda GİRMİYOR.**
    ///
    /// `document` daima `""` başlıyordu: kullanıcı WhatsApp'ta yazılı bir
    /// mesajın sonuna tek harf eklese, o mesajın tamamı ilk mutasyona
    /// `.insert(...)` olarak giriyordu — kullanıcının o dilimde yazmadığı
    /// içerik diske düşüyordu.
    @Test("Host'un mevcut metni kayda sızmıyor")
    func hostTextDoesNotLeakIntoTheCapture() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = RecordingTestSupport.Doc()
        // Host'ta zaten yazılı bir mesaj var.
        doc.insertText("müşteri notu: gizli ")
        let existing = doc.text

        let r = try ProductionRecorder(
            makeDescriptor: { self.descriptor($0) },
            build: { writer in
                RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: Support.layout),
                                layout: Support.layout)
            },
            configure: { try RecordingTestSupport.configure($0) },
            baseline: { doc.text })
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        _ = try r.capture(note: nil, to: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        // Hiçbir mutasyon host metnini taşımıyor.
        for a in entry.session.actions {
            for m in a.document.value?.mutations ?? [] {
                if case let .insert(text) = m {
                    #expect(!text.contains("gizli"), "host metni sızdı: \(text)")
                    #expect(!existing.contains(text) || text.count <= 1)
                }
            }
        }
        // Nihai metin de yazılmıyor: türetilen metin host içeriğini taşırdı.
        #expect(entry.session.finalText.isEmpty)
        // Ve kayıt bunu **söylüyor**: belge zinciri dışarıdan doğrulanamaz.
        #expect(entry.session.documentBaselineKnown == false)
        if case .unverifiable = try DocumentReconstruction.replay(entry.session) {
        } else {
            Issue.record("taban bilinmiyorken doğrulanamaz olmalı")
        }
        #expect(SessionValidator.validate(entry.session,
                                          layout: Support.layout).isEmpty)
    }

    /// Boş tabanda belge zinciri **doğrulanabilir** kalıyor.
    ///
    /// Kontrol testi: yukarıdaki `.unverifiable` her durumda dönseydi, sızıntı
    /// testi hiçbir şey kanıtlamazdı.
    @Test("Boş tabanda belge doğrulanabilir")
    func emptyBaselineStaysVerifiable() throws {
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
        #expect(entry.session.documentBaselineIsKnown)
        #expect(try DocumentReconstruction.replay(entry.session)
                == .complete("ev "))
    }

    /// Üretim kaydı **layout verilerek** de doğrulamadan geçmeli.
    ///
    /// Önce hedef dizisi `["-"]` yer tutucusuydu ve tokenizer kanonikliği onu
    /// haklı olarak reddediyordu; test layout vermediği için kontrol atlanıyor
    /// ve bulgu görünmüyordu.
    @Test("Üretim kaydı layout ile de doğrulanıyor")
    func productionRecordValidatesWithLayout() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        _ = try r.capture(note: nil, to: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        let findings = SessionValidator.validate(entry.session,
                                                 layout: Support.layout)
        #expect(findings.isEmpty, "\(findings)")
    }

    /// **Kayda girmeyen durum değişikliği denemeyi kapatıyor.**
    ///
    /// `invalidateComposing` koordinatörün durumunu değiştiriyor ama action
    /// üretmiyor. Sessizce devam etmek katlamanın gerçekte olandan başka bir
    /// geçmişi anlatması demekti: `"ka"` yazıp iptal edip `"l"` + boşluk
    /// yapınca canlı taraf tek dokunmalı token commit ederken reducer üç
    /// dokunma bekliyordu.
    @Test("Kayıtsız durum değişikliği denemeyi kapatıyor")
    func unloggedStateChangeEndsTheAttempt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ka", into: r, doc: doc, from: &id)
        try r.engine.invalidateComposing()
        #expect(r.engine.stateChangedOutsideTheLog)

        try r.rollOverIfNeeded()
        #expect(r.rollovers == 1, "deneme kapanmalı")
        #expect(r.engine.stateChangedOutsideTheLog == false, "yeni deneme temiz")

        // Devretmeden sonra yazılanlar tutarlı bir kayıt oluşturuyor.
        try type("l", into: r, doc: doc, from: &id)
        try r.engine.perform(.init(command: .space,
                                   timestamp: ProductionRecorder.now), into: doc)
        _ = try r.capture(note: nil, to: dir)
        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(SessionValidator.validate(entry.session,
                                          layout: Support.layout).isEmpty)
        let state = SessionEventReducer.reduce(entry.session)
        #expect(state.tokens.count == 1)
        #expect(state.tokens[0].touchCountAgrees, "sayım tutmalı")
    }

    /// **Devretme token sınırında.**
    ///
    /// Composing açıkken devretmek kullanıcının yazmakta olduğu kelimenin
    /// dokunma kanıtını siliyordu: yeni koordinatör `kalem`i değil yalnız
    /// `lem`i görüyor ve adaylar oradan hesaplanıyordu.
    @Test("Cap aşımı token ortasında devretmiyor")
    func overflowWaitsForATokenBoundary() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        // Sınırı aşacak kadar yaz — token AÇIK bırakılıyor.
        while r.engine.state.tokens.count < 40 {
            try type("kalem", into: r, doc: doc, from: &id)
            try r.engine.perform(.init(command: .space,
                                       timestamp: ProductionRecorder.now), into: doc)
            try r.rollOverIfNeeded()
        }
        try type("kal", into: r, doc: doc, from: &id)
        let before = r.rollovers
        try r.rollOverIfNeeded()
        #expect(r.rollovers == before, "token açıkken devretmemeli")
        #expect(r.engine.isComposing, "composing korunmalı")
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
