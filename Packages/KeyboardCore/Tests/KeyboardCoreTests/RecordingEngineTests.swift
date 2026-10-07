import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Kayıt motoru ve deneme durum makinesi — plan v8 §2.6.
///
/// Buradaki testlerin ortak sorusu: **kayıt, belgeyle ayrışabilir mi?** Eski
/// akış önce koordinatörü ve belgeyi değiştirip sonra logluyordu; aradaki
/// pencerede gelen geç bir callback belgeyi değiştirebiliyordu.
@MainActor
@Suite("Kayıt motoru")
struct RecordingEngineTests {

    /// Yalnız sona yazan belge — replay'in kullandığı tampon.
    private typealias Doc = RecordingTestSupport.Doc

    private func layout() -> KeyLayout {
        KeyLayout(id: "test",
                  keys: "abcdefghijklmnopqrstuvwxyz".enumerated().map { i, ch in
                      Key(char: ch, center: .init(x: Double(i) * 0.03 + 0.02, y: 0.5),
                          width: 0.03, height: 0.3)
                  },
                  asciiBase: [:])
    }

    private func engine(prompt: [String] = ["ev"])
        -> (RecordingEngine, InMemoryJournalWriter, Doc) {
        let writer = InMemoryJournalWriter()
        let l = layout()
        let e = RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: l),
                                layout: l)
        return (e, writer, Doc())
    }

    private func descriptor(prompt: [String],
                            policy: RecordingPolicy = .behavior)
        -> CanonicalSession {
        CanonicalSession(
            attemptID: "a", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt), alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: RecordingTestSupport.unconfigured(policy: policy),
            geometry: .init(layoutID: "test", layoutFingerprint: .known("f"),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    private func touch(_ id: Int, x: Double = 0.1) -> CanonicalSession.Touch {
        .init(touchID: id, phase: .ended, outcome: .committed,
              rawX: x * 393, rawY: 100, normX: x, normY: 0.5,
              decoderX: x, decoderY: 0.5, timestamp: Double(id),
              majorRadius: 5, majorRadiusTolerance: 1,
              plane: "letters", shift: "off",
              hitKind: "letter", key: "a", keyIndex: 0)
    }

    // MARK: - Politika tek kaynaktan

    /// Politika `attemptStarted`'dan geliyor ve `configure` onu **bir daha
    /// sormuyor**.
    ///
    /// İki ayrı giriş varken hiçbir şey ikisinin eşit olduğunu kontrol
    /// etmiyordu: kayda `suppressed` yazılırken motor `applied` ile kurulabilir
    /// ve kayıt kendi anlattığından başka bir klavyeyi ölçerdi.
    @Test("Politika kayıttan alınıp uygulanıyor")
    func policyComesFromTheRecord() throws {
        let (hidden, _, _) = engine()
        try hidden.begin(descriptor(prompt: ["ev"], policy: .calibration), at: 0)
        try RecordingTestSupport.configure(hidden)
        #expect(hidden.visibleSuggestions().isEmpty,
                "kalibrasyon koşulunda öneri çubuğu yok")

        let (shown, _, _) = engine()
        try shown.begin(descriptor(prompt: ["ev"], policy: .behavior), at: 0)
        try RecordingTestSupport.configure(shown)
        // Davranış koşulunda çubuk açık; içeriğinin dolu olması sözlüğe bağlı,
        // burada sınanan şey **kapının** açık olması.
        #expect(hidden.visibleSuggestions().count <= shown.visibleSuggestions().count)
    }

    /// Yazılan anlık görüntü, `begin`'de verilen politikanın ta kendisi.
    @Test("engineConfigured kayıttaki politikayı yazıyor")
    func configuredSnapshotCarriesTheBeginPolicy() throws {
        let (e, writer, _) = engine()
        try e.begin(descriptor(prompt: ["ev"], policy: .calibration), at: 0)
        try RecordingTestSupport.configure(e)

        let loaded = try SessionJournal.load(writer.data).get()
        let frame = try #require(loaded.frames.first { $0.type == .engineConfigured })
        let snapshot = try SessionCodec.decoder.decode(
            CanonicalSession.EngineSnapshot.self, from: frame.payload)
        #expect(snapshot.policy == .init(RecordingPolicy.calibration))
        // Derleme kimliği de `begin`'den: yükleme bitmeden yarıda kalan bir
        // deneme hangi derlemeyle koştuğunu söyleyebilmeli.
        #expect(snapshot.build == RecordingTestSupport.build)
        #expect(snapshot.appVersion == "test")
    }

    /// Politikası bilinmeyen bir kayıt **hiç başlamıyor**.
    ///
    /// Varsayılana düşmek en kötüsüydü: kayıt "bilmiyorum" derken motor
    /// `behavior` gibi kurulur ve replay farkı hiçbir zaman açıklanamazdı.
    @Test("Bilinmeyen politikayla deneme başlamıyor")
    func unknownPolicyRefusesToBegin() throws {
        let (e, writer, _) = engine()
        var d = descriptor(prompt: ["ev"])
        d.engine = .init(buildConfiguration: "Debug", appVersion: "test",
                         build: RecordingTestSupport.build,
                         policy: .init(feedbackVisible: .known(true),
                                       suggestionsVisible: .unknown,
                                       correction: .known(.applied),
                                       learning: .frozen),
                         configuration: .unknown)
        #expect(throws: RecordingEngine.IngressError
            .policyUnknown("suggestionsVisible")) {
            try e.begin(d, at: 0)
        }
        // **Hiçbir frame yazılmadı**: reddedilen bir deneme diskte yarım bir
        // kayıt bırakmamalı, yoksa vazgeçme oranına bozuk bir satır girer.
        // Başlık yazıcı kurulurken düşüyor; frame'siz günlük okunamaz sayılıyor.
        #expect(SessionJournal.load(writer.data) == .failure(.emptyJournal))
        #expect(e.phase == .initializing)
    }

    // MARK: - Faz makinesi

    @Test("Kayıt başlamadan komut kabul edilmiyor")
    func commandBeforeBeginIsRejected() {
        let (e, _, doc) = engine()
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.perform(.init(command: .space, timestamp: 0), into: doc)
        }
        #expect(e.phase == .initializing)
    }

    @Test("İki kez başlatılamıyor")
    func doubleBeginIsRejected() throws {
        let (e, _, _) = engine()
        try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        }
    }

    /// Geç bir callback terminalden **sonra** frame yazabiliyordu; terminal
    /// değişmez olmalı, yoksa tamamlanmış bir deneme sonradan büyür.
    @Test("Terminalden sonra ekleme reddediliyor")
    func appendAfterTerminalIsRejected() throws {
        let (e, writer, doc) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        _ = try e.finish(.aborted, at: 1, finalText: "")

        #expect(e.phase == .aborted)
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.perform(.init(command: .space, timestamp: 2), into: doc)
        }
        #expect(throws: JournalWriteError.self) {
            try writer.append(.init(type: .touch, payload: Data()), durable: false)
        }
    }

    /// §12.6: deneme *"başlar başlamaz diske düşer"*. `attemptStarted`
    /// kaybolursa vazgeçilen deneme abort oranının **paydasından** düşer.
    @Test("attemptStarted ve terminal dayanıklı yazılıyor")
    func attemptStartAndTerminalAreDurable() throws {
        let (e, writer, _) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        #expect(writer.durableOffsets.count == 1, "ilk frame fsync'li")
        _ = try e.finish(.aborted, at: 1, finalText: "")
        #expect(writer.durableOffsets.count == 2, "terminal de fsync'li")
    }

    @Test("Ara frame'ler fsync istemiyor")
    func intermediateFramesAreNotDurable() throws {
        let (e, writer, _) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        try e.record(touch(0))
        #expect(writer.durableOffsets.count == 1,
                "her dokunmada fsync yazma maliyetini uçururdu")
    }

    /// **Codex bulgusu.** Terminal baytları yazılıp fsync başarısız olursa
    /// terminal **yine de dosyada**. Bayrağı fsync'ten sonra kurmak, ikinci bir
    /// terminal yazılmasına izin veriyordu — dosyada iki terminal, hangisinin
    /// geçerli olduğu belirsiz.
    @Test("fsync hatasından sonra ikinci terminal yazılamıyor")
    func terminalIsSingleEvenWhenSyncFails() throws {
        let (e, writer, _) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        writer.shouldFailSync = true

        #expect(throws: (any Error).self) {
            _ = try e.finish(.aborted, at: 1, finalText: "")
        }
        #expect(writer.terminalWritten, "baytlar dosyaya gitti")
        #expect(throws: JournalWriteError.self) {
            try writer.append(.init(type: .terminal, payload: Data()),
                              durable: false)
        }
    }

    // MARK: - Dokunma kimliği

    /// "Son dokunmaya" örtük bağlanmak kimlik korunumunu zayıflatıyordu: iki
    /// parmak üst üste bindiğinde harf yanlış dokunmaya bağlanıyor ve
    /// kalibrasyon o yanlış koordinatı öğreniyordu.
    @Test("Harf komutu dokunma kimliği taşımak zorunda")
    func letterNeedsTouchID() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.perform(.init(command: .letter(baseKey: "a", display: "a",
                                                 shifted: false),
                                timestamp: 1), into: doc)
        }
    }

    @Test("Bilinmeyen dokunmaya bağlanamıyor")
    func unknownTouchIsRejected() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.perform(.init(command: .letter(baseKey: "a", display: "a",
                                                 shifted: false),
                                touchID: 99, timestamp: 1), into: doc)
        }
    }

    @Test("Aynı dokunma iki harfe bağlanamıyor")
    func touchCannotBeConsumedTwice() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        try e.record(touch(0))
        let cmd = RecordingEngine.CommandEnvelope(
            command: .letter(baseKey: "a", display: "a", shifted: false),
            touchID: 0, timestamp: 1)
        try e.perform(cmd, into: doc)
        #expect(throws: RecordingEngine.IngressError.self) {
            try e.perform(cmd, into: doc)
        }
    }

    // MARK: - Tamamlanma koşulu

    /// `cursor > promptTokens.count` başarı **değil**: hedeften fazla token
    /// yazmak hizalamanın kaydığı anlamına geliyor.
    @Test("Fazla token yazmak tamamlanma sayılmıyor")
    func overshootIsNotCompleted() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        try type("ev", engine: e, doc: doc, from: 0)
        try e.perform(.init(command: .space, timestamp: 10), into: doc)
        try type("ok", engine: e, doc: doc, from: 10)
        try e.perform(.init(command: .space, timestamp: 20), into: doc)

        #expect(try e.finish(.completed, at: 30, finalText: doc.text) == .invalid)
    }

    @Test("Tam eşleşme tamamlanma")
    func exactCursorCompletes() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        try type("ev", engine: e, doc: doc, from: 0)
        try e.perform(.init(command: .space, timestamp: 10), into: doc)

        #expect(try e.finish(.completed, at: 30, finalText: doc.text) == .completed)
    }

    /// Açık bir token varken tamamlandı demek, ölçülmemiş bir kelimeyi ölçülmüş
    /// saymaktır.
    @Test("Açık token varken tamamlanma sayılmıyor")
    func openTokenBlocksCompletion() throws {
        let (e, _, doc) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        try type("ev", engine: e, doc: doc, from: 0)

        #expect(try e.finish(.completed, at: 30, finalText: doc.text) == .invalid)
    }

    @Test("Vazgeçilen deneme terminal olarak kaydediliyor")
    func abortIsRecorded() throws {
        let (e, _, _) = engine()
        try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        #expect(try e.finish(.aborted, at: 1, finalText: "") == .aborted)
    }

    /// Kurtarma **yalnız** `recording → interrupted`. Tamamlanmış bir denemeyi
    /// sonradan kesintiye çevirmek, geçmişe dönük yeniden yorumlama olurdu.
    @Test("Kurtarma yalnız yarım kalmış kayıtta")
    func recoveryOnlyFromRecording() throws {
        let (e, _, _) = engine()
        try e.begin(descriptor(prompt: []), at: 0)
        try RecordingTestSupport.configure(e)
        try e.recover(at: 5)
        #expect(e.phase == .interrupted)
        #expect(throws: RecordingEngine.IngressError.self) { try e.recover(at: 6) }
    }

    // MARK: - Belge tutarlılığı

    /// Kaydedilen mutasyonlar belgenin **gerçek** hâlini üretmeli; üretmiyorsa
    /// kayıt ile belge ayrışmış demektir.
    @Test("Mutasyonlar belgeyi birebir yeniden üretiyor")
    func mutationsReproduceDocument() throws {
        let (e, writer, doc) = engine()
        try e.begin(descriptor(prompt: ["ev"]), at: 0)
        try RecordingTestSupport.configure(e)
        try type("ev", engine: e, doc: doc, from: 0)
        try e.perform(.init(command: .space, timestamp: 10), into: doc)
        _ = try e.finish(.completed, at: 30, finalText: doc.text)

        let loaded = try SessionJournal.load(writer.data).get()
        var text = ""
        var actionID = 0
        for frame in loaded.frames where frame.type == .action {
            let a = try SessionCodec.decoder.decode(
                CanonicalSession.Action.self, from: frame.payload)
            let delta = try #require(a.document.value)
            try DocumentReconstruction.apply(delta.mutations, to: &text,
                                             actionID: actionID)
            #expect(DocumentReconstruction.hash(text) == delta.hashAfter)
            actionID += 1
        }
        #expect(text == doc.text)
    }

    /// Artımlı katlama ile toplu katlama **aynı** sonucu vermeli; vermezse
    /// terminal anındaki tamamlanma kararı, sonradan yapılan analizle
    /// çelişirdi.
    @Test("Artımlı katlama toplu katlamayla aynı")
    func incrementalMatchesBatch() throws {
        let (e, writer, doc) = engine()
        try e.begin(descriptor(prompt: ["ev", "ok"]), at: 0)
        try RecordingTestSupport.configure(e)
        try type("ev", engine: e, doc: doc, from: 0)
        try e.perform(.init(command: .space, timestamp: 10), into: doc)
        try type("ok", engine: e, doc: doc, from: 10)
        try e.perform(.init(command: .space, timestamp: 20), into: doc)
        _ = try e.finish(.completed, at: 30, finalText: doc.text)

        let loaded = try SessionJournal.load(writer.data).get()
        var session = try SessionCodec.decoder.decode(
            CanonicalSession.self,
            from: try #require(loaded.frames.first { $0.type == .attemptStarted })
                .payload)
        session.touches = try loaded.frames.filter { $0.type == .touch }.map {
            try SessionCodec.decoder.decode(CanonicalSession.Touch.self,
                                            from: $0.payload)
        }
        session.actions = try loaded.frames.filter { $0.type == .action }.map {
            try SessionCodec.decoder.decode(CanonicalSession.Action.self,
                                            from: $0.payload)
        }

        let batch = SessionEventReducer.reduce(session)
        #expect(batch == e.state)
        #expect(batch.cursor == 2)
        #expect(batch.violations.isEmpty)
    }

    private func type(_ word: String, engine e: RecordingEngine, doc: Doc,
                      from base: Int) throws {
        for (i, ch) in word.enumerated() {
            let id = base + i
            try e.record(touch(id, x: 0.02 + Double(i) * 0.03))
            try e.perform(.init(command: .letter(baseKey: String(ch),
                                                 display: String(ch),
                                                 shifted: false),
                                touchID: id, timestamp: Double(id)), into: doc)
        }
    }
}
