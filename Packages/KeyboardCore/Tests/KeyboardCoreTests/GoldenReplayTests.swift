import Foundation
import Testing
@testable import KBAssembly
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Uçtan uca golden: **kaydet → oku → bağımsız replay → karşılaştır**.
///
/// ## Neden bu test her şeyin üstünde
///
/// Şema, katlama, konteyner ve fabrika ayrı ayrı yeşil olabilir ama birbirine
/// yanlış bağlanmış olabilir. Burada gerçek paketlerle gerçek bir motor
/// kuruluyor, kayıt diske yazılıyor, geri okunuyor ve motor **yalnız
/// komutlarla** yeniden sürülüyor. Kaydedilmiş sonuç motora geri beslenmiyor —
/// beslenseydi test her zaman geçerdi ve hiçbir şey kanıtlamazdı.
@MainActor
@Suite("Golden replay")
struct GoldenReplayTests {

    /// Depodaki `LanguagePacks/` ağacı.
    private static var packRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/KeyboardCoreTests/x.swift
            .deletingLastPathComponent()          // KeyboardCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // KeyboardCore
            .deletingLastPathComponent()          // Packages
            .deletingLastPathComponent()          // repo kökü
            .appendingPathComponent("LanguagePacks")
    }

    private final class Doc: DocumentEditor {
        private(set) var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

    /// Türkçe Q düzeninin ölçüm için yeterli bir yaklaşımı.
    ///
    /// Uygulamanın layout'u `Apps/` altında ve pakette yok; testin kendi
    /// düzenini kurması sorun değil çünkü **aynı** düzen hem kayıt hem replay
    /// tarafında kullanılıyor ve parmak izi bunu doğruluyor.
    private func layout() -> KeyLayout {
        let rows = ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"]
        var keys: [Key] = []
        for (r, row) in rows.enumerated() {
            let w = 1.0 / Double(row.count)
            for (c, ch) in row.enumerated() {
                keys.append(Key(char: ch,
                                center: .init(x: (Double(c) + 0.5) * w,
                                              y: (Double(r) + 0.5) / 3),
                                width: w, height: 1.0 / 3))
            }
        }
        return KeyLayout(id: "tr-q-test", keys: keys,
                         asciiBase: ["ı": "i", "ğ": "g", "ü": "u", "ş": "s",
                                     "ö": "o", "ç": "c"])
    }

    private func packSource() throws -> PackSource {
        try #require(FileManager.default.fileExists(
            atPath: Self.packRoot.appendingPathComponent("tr-TR/tr-TR.bkt").path),
            "dil paketleri bulunamadı: \(Self.packRoot.path)")
        return DirectoryPackSource(root: Self.packRoot)
    }

    /// Tuşun merkezine dokunan bir örnek — gerçek parmak gürültüsü yok, çünkü
    /// test **replay'in birebirliğini** ölçüyor, decoder'ın doğruluğunu değil.
    private func touch(_ id: Int, char: Character, layout: KeyLayout,
                       t: TimeInterval) -> CanonicalSession.Touch {
        let index = layout.keyIndex(for: char)
        let center = index.map { layout.keys[$0].center } ?? .init(x: 0.5, y: 0.5)
        return .init(touchID: id, phase: .ended, outcome: .committed,
                     rawX: center.x * 393, rawY: center.y * 216,
                     normX: center.x, normY: center.y,
                     decoderX: center.x, decoderY: center.y, timestamp: t,
                     majorRadius: 5, majorRadiusTolerance: 1,
                     plane: "letters", shift: "off",
                     hitKind: "letter", key: String(char), keyIndex: index)
    }

    /// Bir cümleyi kaydeder ve günlüğü döndürür.
    private func record(_ words: [String], layout l: KeyLayout,
                        source: PackSource,
                        condition: CanonicalSession.Condition = .behavior) throws
        -> Data {
        let loaded = try PackLoader.load(layout: l, source: source,
                                         computeHashes: true)
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer,
                                     coordinator: InputCoordinator(layout: l),
                                     layout: l)

        var descriptor = CanonicalSession(
            attemptID: "golden", participantID: "p", sessionOrdinal: 0,
            condition: condition, status: .recording,
            promptID: "g", promptText: words.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(words),
            alignmentSource: condition == .calibrationReplay
                ? .constructed : .sequential,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: .unconfigured(),
            geometry: .init(layoutID: l.id,
                            layoutFingerprint: .known(l.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "test", systemVersion: "18"))
        // Anlık görüntü `configure` tarafından **kurulan motordan** üretiliyor;
        // burada elle doldurmak, kayda yazılanla motorun ayrışmasına açık kapı
        // bırakırdı.
        try engine.begin(descriptor, at: 0)
        try engine.configure(loaded: loaded,
                             policy: condition == .calibrationReplay
                                ? .calibration : .behavior,
                             buildConfiguration: "Debug", appVersion: "test",
                             build: .init(codeRevision: .known("golden"),
                                          provenance: .known(.init(
                                            sourceTree: .clean, swiftVersion: "6",
                                            targetTriple: "t", arch: "arm64",
                                            optimization: "-Onone",
                                            xcodeVersion: "0"))),
                             calibration: .init(
                                applied: false, strongSamples: 0,
                                biasX: [], biasY: [],
                                hierarchical: .init(globalX: 0, globalY: 0,
                                                    rowX: [], rowY: [],
                                                    keyX: [], keyY: []),
                                sigma: .known(.init(x: [], y: []))))
        let doc = Doc()
        var id = 0
        var t = 0.0
        for word in words {
            for ch in word {
                t += 0.1
                try engine.record(touch(id, char: ch, layout: l, t: t))
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: String(ch),
                                                          shifted: false),
                                         touchID: id, timestamp: t), into: doc)
                id += 1
            }
            t += 0.1
            try engine.perform(.init(command: .space, timestamp: t), into: doc)
        }
        _ = try engine.finish(.completed, at: t + 1, finalText: doc.text)
        return writer.data
    }

    /// Günlüğü kanonik oturuma katlar.
    private func session(from journal: Data) throws -> CanonicalSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        try journal.write(to: dir.appendingPathComponent("g.bkj"))
        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        return try #require(listing.entries.first).session
    }

    /// **Asıl iddia.** Aynı paketler ve aynı layout ile replay kayıtla birebir
    /// aynı kararları vermeli. Vermiyorsa ya kayıt eksik ya kurulum ayrışmış.
    @Test("Kayıt bağımsız replay ile birebir aynı")
    func recordReplayMatches() throws {
        let l = layout()
        let source = try packSource()
        let s = try session(from: try record(["kalem", "ev", "güzel"],
                                             layout: l, source: source))

        let report = try GoldenReplay.run(s, layout: l, packs: source,
                                          currentRevision: "golden")
        #expect(report.environment.isVerifiable,
                "ortam uyuşmuyor: \(report.environment)")
        #expect(!report.environment.codeRevisionDiffers)
        #expect(report.compared == 3, "üç sınır olayı karşılaştırılmalı")
        #expect(report.unverifiable.isEmpty)
        #expect(report.divergences.isEmpty, "\(report.divergences)")
        #expect(report.isClean)
    }

    /// Kayıt kendi içinde tutarlı olmalı: katlama ihlal üretmemeli, belge
    /// mutasyonlardan birebir kurulmalı.
    @Test("Kayıt kendi doğrulamasından geçiyor")
    func recordingValidates() throws {
        let l = layout()
        let s = try session(from: try record(["kalem", "ev"], layout: l,
                                             source: try packSource()))

        let findings = SessionValidator.validate(s)
        #expect(findings.isEmpty, "\(findings)")

        #expect(try DocumentReconstruction.replay(s) == .complete(s.finalText))

        let state = SessionEventReducer.reduce(s)
        #expect(state.tokens.count == 2)
        #expect(state.violations.isEmpty)
        #expect(state.unverifiable.isEmpty)
        #expect(state.cursor == 2)
        #expect(state.tokens.allSatisfy { $0.touchCountAgrees })
    }

    /// Kalibrasyon çıkarımı — reducer'ın asıl karşılığı.
    ///
    /// Kayıt `behavior` koşulunda alındığı için hizalama `sequential`; §12.4
    /// gereği oradan **hiçbir** örnek çıkmamalı. `sequential` sırayla
    /// varsayıyor, kayıt değil.
    @Test("Sequential hizalamadan örnek çıkmıyor")
    func sequentialYieldsNoSamples() throws {
        let l = layout()
        let s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))
        #expect(s.alignmentSource == .sequential)
        #expect(CalibrationExtraction.extract(s, layout: l).samples.isEmpty)
    }

    /// Kurgulanmış hizalamada güçlü etiketli token'lar örnek veriyor ve her
    /// dokunma **hedef** karakterin tuşuna atanıyor.
    ///
    /// Basılan tuşa atamak sapmayı sistematik olarak kırpıyordu: komşu tuşa
    /// kayan dokunma o komşunun örneği sayılıyor ve kendi tuşunun sapması hiç
    /// öğrenilmiyordu. Kaymanın **kendisi** öğrenilecek şey.
    @Test("Kurgulanmış hizalamada örnekler hedef tuşa atanıyor")
    func constructedAlignmentYieldsSamples() throws {
        let l = layout()
        var s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource(),
                                             condition: .calibrationReplay))
        #expect(s.alignmentSource == .constructed)

        let result = CalibrationExtraction.extract(s, layout: l)
        #expect(result.samples.count == 2, "iki harf, iki örnek")
        #expect(result.samples.map(\.keyIndex)
                == ["e", "v"].compactMap { l.keyIndex(for: Character($0)) })
        #expect(result.samples.allSatisfy { $0.confidence == .strong })

        // Etiket zayıflarsa örnek çıkmamalı: §12.5 yalnız `literal == hedef`
        // durumunda `strong` diyor.
        for i in s.actions.indices {
            s.actions[i].commit?.label.confidence = .weak
        }
        #expect(CalibrationExtraction.extract(s, layout: l).samples.isEmpty)
    }

    /// **Testin kendisini sınayan test.** Karşılaştırma canlı değilse yukarıdaki
    /// "birebir aynı" iddiası hiçbir şey kanıtlamaz: bozulmuş bir kayıt da
    /// temiz görünürdü.
    @Test("Bozulmuş kayıt fark üretiyor")
    func corruptedRecordingDiverges() throws {
        let l = layout()
        var s = try session(from: try record(["kalem"], layout: l,
                                             source: try packSource()))
        let i = try #require(s.actions.firstIndex { $0.commit != nil })
        s.actions[i].commit?.committed = "bambaşka"

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "committed" })
        #expect(!report.isClean)
    }

    /// Bilinmeyen komut (v2 migrasyonu) **atlanmıyor, sayılıyor**. Sessizce
    /// geçmek doğrulanmamış bir kaydı "hiç fark yok" diye gösterirdi.
    @Test("Bilinmeyen komut doğrulanamaz olarak raporlanıyor")
    func unknownCommandIsCounted() throws {
        let l = layout()
        var s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))
        s.actions[0].event = .unknown

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        // Bilinmeyen bir **durum değiştiren** olaydan sonra motor kayıttan
        // ayrışıyor: sonraki karşılaştırmalar iki farklı geçmişi kıyaslar ve
        // sahte fark üretir. Suffix'in tamamı doğrulanamaz.
        #expect(report.unverifiable == s.actions.map(\.actionID))
        #expect(report.divergences.isEmpty, "sahte fark üretilmemeli")
        #expect(!report.isClean, "doğrulanamayan kayıt temiz sayılamaz")
    }

    /// Layout içeriği değişirse fark "kod regresyonu" **değil**, ortam farkı.
    /// `layoutID` tekil olmadığı için bu ayrım parmak iziyle yapılıyor.
    @Test("Layout değişimi ortam uyuşmazlığı olarak raporlanıyor")
    func layoutChangeIsEnvironmentMismatch() throws {
        let l = layout()
        var s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))
        s.geometry.layoutFingerprint = .known("başka-bir-iz")

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.environment.layoutMismatch)
        #expect(!report.environment.isVerifiable)
    }

    /// Kayıtta olmayan bir sözlük diskte duruyorsa replay motoru kayıttakinden
    /// **daha zengin** olur ve "kod düzeldi" gibi görünen sahte bir iyileşme
    /// üretir. Eksik paket kadar fazladan paket de uyuşmazlıktır.
    @Test("Fazladan paket ortam uyuşmazlığı")
    func extraPackIsMismatch() throws {
        let l = layout()
        var s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))
        var cfg = try #require(s.engine.configuration.value)
        cfg.packs.removeLast()                 // kayıt daha az paketle alınmış
        s.engine.configuration = .known(cfg)

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.environment.packMismatches.contains { $0.hasSuffix("/fazladan") })
        #expect(!report.environment.isVerifiable)
    }

    /// Sapmayı uygulayıp ölçeği varsayılana bırakmak **karışık** bir model
    /// kurardı; hangisinin fark ürettiği ayırt edilemezdi.
    @Test("Kalibrasyon uygulanmış ama σ bilinmiyorsa doğrulanamaz")
    func appliedCalibrationWithoutSigmaIsUnverifiable() throws {
        let l = layout()
        var s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))
        var cfg = try #require(s.engine.configuration.value)
        cfg.calibration.applied = true
        cfg.calibration.sigma = .unknown
        s.engine.configuration = .known(cfg)

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.environment.unknownFacts.contains("calibration.sigma"))
        #expect(!report.environment.isVerifiable)
    }

    /// Kayıt revision'ı ile bugünkü kodun farklı olması **regression replay'in
    /// amacıdır**; tek başına ortam uyuşmazlığı değildir.
    @Test("Revision farkı ortam uyuşmazlığı sayılmıyor")
    func revisionDifferenceIsNotMismatch() throws {
        let l = layout()
        let s = try session(from: try record(["ev"], layout: l,
                                             source: try packSource()))

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource(),
                                          currentRevision: "bambaşka")
        #expect(report.environment.codeRevisionDiffers)
        #expect(report.environment.isVerifiable,
                "revision farkı replay'i geçersiz kılmamalı")
        #expect(report.divergences.isEmpty)
    }
}
