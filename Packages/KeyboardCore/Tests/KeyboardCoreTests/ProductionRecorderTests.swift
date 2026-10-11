import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSpatial
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

    /// **Devretme öğrenilmiş kalibrasyonu yürürlükten düşürmemeli.**
    ///
    /// `rollOver` koordinatörü sıfırdan kuruyor: yeni koordinatörün rezervuarı
    /// boş ve uzamsal modeli kalibrasyonsuz. Uzantı `applyCalibration`'ı yalnız
    /// paket yüklemesinde ve profil değişiminde çağırıyordu, dolayısıyla 512
    /// KB'lık tampon sınırına gelen kullanıcı öğrenilmiş sapmasını sessizce
    /// kaybediyordu — dosya duruyor ama canlı motor kalibrasyonsuz koşuyor.
    ///
    /// Çözüm kişisel sözlükle aynı: rezervuar `configure`'ın parametresi, yani
    /// **her denemede** yeniden veriliyor.
    @Test("Devretme öğrenilmiş kalibrasyonu düşürmüyor")
    func rolloverKeepsTheLearnedCalibration() throws {
        // Gerçek yoldan toplanmış rezervuar: `observe` üretimde de bu.
        var learner = CalibrationLearner()
        let word = "kalem"
        let touches = word.compactMap { ch in
            Support.layout.keyIndex(for: ch).map {
                TouchSample(down: Support.layout.keys[$0].center, timestamp: 0)
            }
        }
        for _ in 0..<CalibrationLearner.minStrongSamples {
            _ = learner.observe(touches: touches, literal: word, committed: word,
                                layout: Support.layout, confidence: .strong)
        }
        #expect(learner.strongCount > 0)

        let r = try ProductionRecorder(
            makeDescriptor: { self.descriptor($0) },
            build: { writer in
                RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: Support.layout),
                                layout: Support.layout)
            },
            configure: { [learner] engine in
                try engine.configure(loaded: Support.loaded,
                                     calibration: Support.blankCalibration,
                                     learner: learner)
            })
        #expect(r.engine.calibration.strongCount == learner.strongCount)

        try r.rollOver()
        #expect(r.engine.calibration.strongCount == learner.strongCount,
                "devretmeden sonra rezervuar boşaldı")
    }

    /// Kayıt, motorun **fiilen taşıdığı** kalibrasyonu yazmalı.
    ///
    /// Uzantı `applied: false` yazıp sonradan `applyCalibration` çağırıyordu:
    /// kayıt "kalibrasyon yok" derken canlı decoder öğrenilmiş profili
    /// uyguluyordu. Replay farkı ortam uyuşmazlığı olarak da görünmezdi —
    /// sahte bir kod regresyonu diye okunurdu.
    @Test("Snapshot uygulanan kalibrasyonu anlatıyor")
    func snapshotReportsTheAppliedCalibration() throws {
        var learner = CalibrationLearner()
        let word = "kalem"
        // Sapmalı dokunma: tuş merkezinin sağına basılıyor, yani tahmin
        // sıfırdan farklı çıkmalı.
        let touches = word.compactMap { ch -> TouchSample? in
            guard let k = Support.layout.keyIndex(for: ch) else { return nil }
            let c = Support.layout.keys[k].center
            return TouchSample(down: .init(x: c.x + 0.01, y: c.y), timestamp: 0)
        }
        for _ in 0..<CalibrationLearner.minStrongSamples {
            _ = learner.observe(touches: touches, literal: word, committed: word,
                                layout: Support.layout, confidence: .strong)
        }

        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer,
                                     coordinator: InputCoordinator(layout: Support.layout),
                                     layout: Support.layout)
        try engine.begin(descriptor("a"), at: 0)
        try engine.configure(loaded: Support.loaded,
                             calibration: Support.blankCalibration,
                             learner: learner)

        let loaded = try SessionJournal.load(writer.data).get()
        let frame = try #require(loaded.frames.first { $0.type == .engineConfigured })
        let snapshot = try SessionCodec.decoder.decode(
            CanonicalSession.EngineSnapshot.self, from: frame.payload)
        let config = try #require(snapshot.configuration.value)
        #expect(config.calibration.applied,
                "motor kalibre koşuyor ama kayıt 'uygulanmadı' diyor")
        #expect(config.calibration.biasX.contains { $0 != 0 },
                "uygulanan sapma kayda girmemiş")
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

    /// **Kalibrasyon değişikliği de denemeyi kapatıyor.**
    ///
    /// `engineConfigured` çoktan yazılmış durumda ve o snapshot artık motoru
    /// anlatmıyor: canlı decoder öğrenilmiş profili uygularken kayıt
    /// `applied: false` diyordu — replay farkı "kod değişti" diye okunurdu.
    @Test("Kalibrasyon değişikliği denemeyi kapatıyor")
    func calibrationChangeEndsTheAttempt() throws {
        let r = try makeRecorder()
        #expect(r.engine.stateChangedOutsideTheLog == false)
        r.engine.applyCalibration()
        #expect(r.engine.stateChangedOutsideTheLog)
        try r.rollOverIfNeeded()
        #expect(r.rollovers == 1)
    }

    /// Anlık görüntü **kurulan motordan** okunuyor.
    ///
    /// Çağıranın verdiği görüntüye güvenmek, kaydın kendi motorunu yanlış
    /// anlatmasına yol açıyordu.
    @Test("Snapshot motorun gerçek kalibrasyonunu taşıyor")
    func snapshotReflectsTheEngine() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = RecordingTestSupport.Doc()
        var id = 0
        try type("ev", into: r, doc: doc, from: &id)
        _ = try r.capture(note: nil, to: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        let cal = try #require(entry.session.engine.configuration.value?.calibration)
        // Kalibrasyonsuz motor: sapma sıfır, dolayısıyla `applied: false`.
        #expect(cal.applied == false)
        // Ama diziler **gerçek uzunlukta**: sıfır dizi yazmak, replay'in
        // kalibrasyonu hiç kuramaması demekti.
        #expect(cal.biasX.count == Support.layout.keys.count)
        #expect(cal.sigma.value?.x.count == Support.layout.keys.count)
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

extension ProductionRecorderTests {
    @Test("Çok kelimeli açılımın son sözcüğünü geri açmak geçerli kayıt bırakır")
    func expandedTailReopenKeepsRecordingFactsConsistent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try makeRecorder()
        let doc = Support.Doc()
        var id = 0
        try type("kib", into: r, doc: doc, from: &id)
        let phrase = "kendine iyi bak"
        try r.engine.perform(.init(command: .suggestionPick(id: InputCoordinator.expansionID(surface: phrase),
            surface: phrase, origin: .expansion(trigger: "kib")), timestamp: ProductionRecorder.now), into: doc)
        #expect(doc.text == phrase + " ")
        try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
        #expect(r.engine.composingSurface == "bak")
        for _ in 0..<3 {
            try r.engine.perform(.init(command: .space, timestamp: ProductionRecorder.now), into: doc)
            try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
            #expect(r.engine.composingSurface == "bak")
            #expect(doc.text == phrase)
        }
        try r.engine.perform(.init(command: .deleteWord, timestamp: ProductionRecorder.now), into: doc)
        #expect(doc.text == "kendine iyi ")
        _ = try r.capture(note: nil, to: dir)
        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(SessionValidator.validate(entry.session, layout: Support.layout).isEmpty)
    }

    @Test("Kayıttan seçim düzenlemeye geçiş öneriyi ve öğrenmeyi korur")
    func selectionContinuationPreservesLiveCoordinator() throws {
        let recorder = try makeRecorder()
        var continuation = try recorder.engine.continuationForUnrecordedEditing()
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce qrmenü")
        doc.hostSelects("qrmenü")
        #expect(continuation.handleSelection(doc.selectedText, into: doc) == "qrmenü")
        let original = try #require(continuation.suggestions().first { $0.origin == .literal })
        try continuation.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
        #expect(doc.selectedText == nil)
        #expect(doc.text == "önce qrmenü")
        #expect(continuation.personal.isAdmitted("qrmenü"))
        #expect(recorder.engine.stateChangedOutsideTheLog)
    }
}


extension ProductionRecorderTests {
    @Test("Teknik seçim devri canlı metni korur ve eski kaydı değiştirmez")
    func technicalSelectionContinuationAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_TECH_SELECTION_RECORDING_AUDIT"] else { return }
        var rows: [[String: String]] = []
        for value in ["0532 123 45 67", "+90 532 123 45 67", "\"Çağrı Şen\"@örnek.com",
                      "dev@example.com", "https://örnek.com/çağrı", "tcp/ip"] {
            for padding in ["", " "] {
                for committed in [false, true] {
                    let recorder = try makeRecorder()
                    let prior = Support.Doc(); var touchID = 0
                    try type("kalem", into: recorder, doc: prior, from: &touchID)
                    if committed {
                        try recorder.engine.perform(.init(command: .space, timestamp: ProductionRecorder.now), into: prior)
                    }
                    let frozen = recorder.engine.documentText
                    let calibration = recorder.engine.calibration.sampleCount
                    var continuation = try recorder.engine.continuationForUnrecordedEditing()
                    let doc = FakeDocument()
                    let selected = padding + value + padding
                    doc.hostRewrites(to: "önce " + selected); doc.hostSelects(selected)
                    let result = continuation.handleSelection(doc.selectedText, into: doc)
                    let literal = continuation.suggestions().first { $0.origin == .literal && $0.surface == value }
                    if let literal {
                        try continuation.perform(.suggestionPick(id: literal.id, surface: literal.surface, origin: literal.origin), touch: nil, into: doc)
                    }
                    let exact = doc.text == "önce " + selected && doc.selectedText == nil
                    let key = try #require(Support.layout.keyIndex(for: "x"))
                    continuation.insertLetter("x", touch: .init(down: Support.layout.keys[key].center), into: doc)
                    let continued = doc.text == "önce " + selected + "x"
                    continuation.backspaceTap(into: doc)
                    rows.append(["value": value, "padding": padding, "committed": String(committed),
                                 "selected": String(result == selected), "literal": String(literal != nil),
                                 "exact": String(exact), "continued": String(continued),
                                 "deleted_exact": String(doc.text == "önce " + selected),
                                 "old_record_unchanged": String(recorder.engine.documentText == frozen),
                                 "outside_log_marked": String(recorder.engine.stateChangedOutsideTheLog),
                                 "calibration_unchanged": String(continuation.calibration.sampleCount == calibration),
                                 "personal_empty": String(continuation.personal.entries.isEmpty)])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

extension ProductionRecorderTests {
    @Test("Şapkalı sembollerin Shift sonucu kayıt ve replay içinde korunur")
    func circumflexShiftRecordingAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_CIRCUMFLEX_RECORDING_AUDIT"] else { return }
        var rows: [[String: String]] = []
        for word in ["kâr", "resmî", "sükûn", "âlem", "îman"] {
            for mode in ["off", "oneShot", "locked"] {
                for boundary in ["space", "period", "reopen"] {
                    let dir = try tempDir()
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let r = try makeRecorder(), doc = Support.Doc()
                    var shift = ShiftPolicy(), id = 0, expected = ""
                    if mode != "off" { shift.tapShift(at: 0) }
                    if mode == "locked" { shift.tapShift(at: 0.1) }
                    for ch in word {
                        let time = ProductionRecorder.now
                        if "âîû".contains(ch) {
                            let text = shift.consumeSymbol(ch)
                            expected += text
                            try r.engine.perform(.init(command: .symbol(text), timestamp: time), into: doc)
                        } else {
                            let command = shift.letterCommand(ch)
                            expected += shift.isUppercase ? String(ch).uppercased(with: Locale(identifier: "tr_TR")) : String(ch)
                            var touch = Support.touch(id, char: ch, t: time)
                            touch.shift = String(describing: shift.mode)
                            try r.engine.record(touch)
                            try r.engine.perform(.init(command: command, touchID: id, timestamp: time), into: doc)
                            id += 1; shift.didEmitLetter()
                        }
                    }
                    let typed = doc.text == expected
                    let separator = boundary == "period" ? "." : " "
                    try r.engine.perform(.init(command: boundary == "period" ? .symbol(".") : .space, timestamp: ProductionRecorder.now), into: doc)
                    if boundary == "reopen" {
                        try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
                        try r.engine.perform(.init(command: .space, timestamp: ProductionRecorder.now), into: doc)
                    }
                    expected += separator
                    _ = try r.capture(note: nil, to: dir)
                    let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
                    let findings = SessionValidator.validate(entry.session, layout: Support.layout)
                    let replayed = try DocumentReconstruction.replay(entry.session) == .complete(expected)
                    let checks = ["typed_exact": typed, "final_exact": doc.text == expected,
                                  "recorded_exact": entry.session.finalText == expected,
                                  "valid_record": findings.isEmpty, "replayed_exact": replayed,
                                  "touch_count": entry.session.touches.count == id]
                    for (name, passed) in checks { #expect(passed, "\(word) \(mode) \(boundary): \(name), \(findings)") }
                    var row = checks.mapValues(String.init)
                    row["word"] = word; row["mode"] = mode; row["boundary"] = boundary
                    rows.append(row)
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}

extension ProductionRecorderTests {
    @Test("Whole-word offers survive recorded edits and recorder rollover")
    func wholeWordOfferRecordingAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_WHOLE_WORD_RECORDING_AUDIT"] else { return }
        var rows: [[String: String]] = []
        for (root, form) in [("qrmâvi", "qrmâviden"), ("qrmîlo", "qrmîlodan"), ("qrmûnu", "qrmûnudan")] {
            for opening in ["", "(", "\"", "'"] {
                for choice in ["original", "repair"] {
                    for edit in ["reopen", "last_character", "last_word"] {
                        let dir = try tempDir()
                        defer { try? FileManager.default.removeItem(at: dir) }
                        let doc = Support.Doc()
                        doc.insertText("PRIVATE_ANCHOR " + opening)
                        var personal = PersonalLexicon()
                        _ = personal.observe(root, confidence: .strong)
                        let r = try ProductionRecorder(
                            makeDescriptor: { self.descriptor($0) },
                            build: { writer in RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: Support.layout), layout: Support.layout) },
                            configure: { try $0.configure(loaded: Support.loaded,
                                calibration: Support.blankCalibration, personal: personal) },
                            baseline: { doc.text })
                        var id = 0
                        let source = form + "baç"
                        for ch in source {
                            if "âîû".contains(ch) {
                                try r.engine.perform(.init(command: .symbol(String(ch)), timestamp: ProductionRecorder.now), into: doc)
                            } else { try type(String(ch), into: r, doc: doc, from: &id) }
                        }
                        let offer = try #require(r.engine.wholeWordSuggestion(before: doc.text, after: "", selected: nil))
                        let target = choice == "original" ? source : form + " aç"
                        let replacement = try #require(offer.replacement(for: target))
                        #expect(offer.matches(before: doc.text, after: "", selected: nil))
                        // Match InputSession.closeComposition and the controller's
                        // recorded delete/text sequence, with the real host baseline.
                        try r.engine.invalidateComposing()
                        personal = r.engine.personal
                        try r.rollOver()
                        for _ in source {
                            try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
                        }
                        try r.engine.perform(.init(command: .text(replacement), timestamp: ProductionRecorder.now), into: doc)
                        if choice == "original" {
                            r.engine.confirmWholeWord(source)
                            personal = r.engine.personal
                            try r.rollOverIfNeeded()
                        }
                        let expected = "PRIVATE_ANCHOR " + opening + target + " "
                        let pickedExact = doc.text == expected
                        let admitted = r.engine.personal.admitted
                        var intermediateExact = true
                        switch edit {
                        case "reopen":
                            for _ in 0..<3 {
                                try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
                                intermediateExact = intermediateExact && doc.text == String(expected.dropLast())
                                try r.engine.perform(.init(command: .space, timestamp: ProductionRecorder.now), into: doc)
                                intermediateExact = intermediateExact && doc.text == expected
                            }
                        case "last_character":
                            for _ in 0..<2 {
                                try r.engine.perform(.init(command: .backspaceTap, timestamp: ProductionRecorder.now), into: doc)
                            }
                            intermediateExact = doc.text == String(expected.dropLast(2))
                            try type(String(target.last!), into: r, doc: doc, from: &id)
                            try r.engine.perform(.init(command: .space, timestamp: ProductionRecorder.now), into: doc)
                        default:
                            let withoutSpace = String(expected.dropLast())
                            let tail = String(withoutSpace.split(separator: " ").last!)
                            try r.engine.perform(.init(command: .deleteWord, timestamp: ProductionRecorder.now), into: doc)
                            intermediateExact = doc.text == String(expected.dropLast(tail.count + 1))
                            try r.engine.perform(.init(command: .text(tail + " "), timestamp: ProductionRecorder.now), into: doc)
                        }
                        personal = r.engine.personal
                        let finalExact = doc.text == expected
                        let learningStable = personal.admitted == admitted
                        _ = try r.capture(note: nil, to: dir)
                        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
                        let findings = SessionValidator.validate(entry.session, layout: Support.layout)
                        let privacy = entry.session.finalText.isEmpty && (entry.session.documentBaselineKnown == false) && entry.session.actions.allSatisfy { action in
                            (action.document.value?.mutations ?? []).allSatisfy { mutation in
                                if case let .insert(text) = mutation { return !text.contains("PRIVATE_ANCHOR") }
                                return true
                            }
                        }
                        var reconstructionHonest = false
                        if case .unverifiable = try DocumentReconstruction.replay(entry.session) { reconstructionHonest = true }
                        let checks = ["picked_exact": pickedExact, "intermediate_exact": intermediateExact,
                            "final_exact": finalExact, "learning_stable": learningStable,
                            "rollover_keeps_learning": r.engine.personal.admitted == admitted,
                            "valid_record": findings.isEmpty, "baseline_private": privacy,
                            "reconstruction_honest": reconstructionHonest]
                        for (name, passed) in checks { #expect(passed, "\(root) \(opening) \(choice) \(edit): \(name), \(findings)") }
                        var row = checks.mapValues(String.init)
                        row["root"] = root; row["opening"] = opening; row["choice"] = choice; row["edit"] = edit
                        rows.append(row)
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
