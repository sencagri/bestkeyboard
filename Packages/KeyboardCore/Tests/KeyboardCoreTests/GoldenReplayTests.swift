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

    private typealias Support = RecordingTestSupport

    private var layout: KeyLayout { Support.layout }

    private func packSource() throws -> PackSource {
        try #require(FileManager.default.fileExists(
            atPath: Support.packRoot.appendingPathComponent("tr-TR/tr-TR.bkt").path),
            "dil paketleri bulunamadı: \(Support.packRoot.path)")
        return Support.packSource
    }

    private func session(_ words: [String],
                         condition: CanonicalSession.Condition = .behavior,
                         calibration: CanonicalSession.EngineSnapshot
                             .CalibrationSnapshot = Support.blankCalibration) throws
        -> CanonicalSession {
        _ = try packSource()
        return try Support.session(from: try Support.record(
            words, condition: condition, calibration: calibration))
    }

    /// **Asıl iddia.** Aynı paketler ve aynı layout ile replay kayıtla birebir
    /// aynı kararları vermeli. Vermiyorsa ya kayıt eksik ya kurulum ayrışmış.
    @Test("Kayıt bağımsız replay ile birebir aynı")
    func recordReplayMatches() throws {
        let l = layout
        let source = try packSource()
        let s = try session(["kalem", "ev", "güzel"])

        let report = try GoldenReplay.run(s, layout: l, packs: source,
                                          currentRevision: "test")
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
        let l = layout
        let s = try session(["kalem", "ev"])

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
        let l = layout
        let s = try session(["ev"])
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
        let l = layout
        var s = try session(["ev"], condition: .calibrationReplay)
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
        let l = layout
        var s = try session(["kalem"])
        let i = try #require(s.actions.firstIndex { $0.commit != nil })
        s.actions[i].commit?.committed = "bambaşka"

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "committed" })
        #expect(!report.isClean)
    }

    /// **Kalibre motorla alınan kayıt da birebir replay ediliyor.**
    ///
    /// `RecordingEngine.configure` kalibrasyon anlık görüntüsünü **kaydediyor
    /// ama motora uygulamıyordu**; replay uyguluyordu. Sonuç: `applied: true`
    /// verilen bir kayıtta canlı motor kalibrasyonsuz koşuyor, kayıt
    /// "uygulandı" diyor, replay kalibrasyonlu koşuyor ve fark **sahte bir kod
    /// regresyonu** olarak okunuyordu. Ortam da "doğrulanabilir" kalıyordu.
    ///
    /// Bugünkü UI daima `applied: false` veriyor, yani tuzak gizliydi.
    @Test("Kalibre motorla alınan kayıt farksız replay ediliyor")
    func calibratedRecordingReplaysClean() throws {
        let l = layout
        // Sıfır olmayan, tuş başına **farklı** bir sapma: sıfır kalibrasyon
        // uygulanmasa da fark üretmez ve test hiçbir şey sınamazdı.
        let n = l.keys.count
        let cal = CanonicalSession.EngineSnapshot.CalibrationSnapshot(
            applied: true, strongSamples: 100,
            biasX: (0..<n).map { Double($0 % 5) * 0.004 - 0.008 },
            biasY: (0..<n).map { Double($0 % 3) * 0.005 - 0.005 },
            hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                keyX: [], keyY: []),
            sigma: .known(.init(x: Array(repeating: 0.05, count: n),
                                y: Array(repeating: 0.06, count: n))))
        let s = try session(["kalem", "ev"], calibration: cal)
        #expect(s.engine.configuration.value?.calibration.applied == true)

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.isEmpty, "\(report.divergences)")
        #expect(report.isClean)
    }

    /// Uygulanamayan kalibrasyon **deneme başlatmıyor**.
    ///
    /// Yarısı kalibre bir modelle kayıt almak, hangi motorun ölçüldüğünü
    /// söyleyememek demek.
    @Test("Eksik kalibrasyon dizisi reddediliyor")
    func unusableCalibrationRefusesToConfigure() throws {
        let l = layout
        let short = CanonicalSession.EngineSnapshot.CalibrationSnapshot(
            applied: true, strongSamples: 100, biasX: [0.01], biasY: [0.01],
            hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                keyX: [], keyY: []),
            sigma: .known(.init(x: [0.05], y: [0.05])))
        #expect(throws: RecordingEngine.IngressError.self) {
            _ = try Support.record(["ev"], calibration: short)
        }
    }

    /// **Kalibrasyon koşulu da birebir doğrulanmalı.**
    ///
    /// O koşulda `fieldProtectsLiteral` açık ve **her** token `θ = ∞` ile
    /// korunuyor. JSON sonsuz taşımadığı için kayıt `θ`'yı `nil` +
    /// `literalProtected: true` olarak yazıyor; golden ise `nil` ↔ `inf`
    /// karşılaştırması yapıyordu ve korunan her token'da sahte fark üretiyordu.
    ///
    /// Testler bunu görmüyordu çünkü hepsi `.behavior` koşulunda koşuyor ve
    /// orada `θ` sonlu. Cihazdan çekilen 28 gerçek kayıtta 81 sahte fark
    /// çıkınca görüldü — düzeltmeden sonra 28/28 temiz.
    @Test("Kalibrasyon koşulundaki kayıt farksız replay ediliyor")
    func calibrationConditionReplaysClean() throws {
        let l = layout
        // **Sözlük dışı** literal: `θ = ∞` koruması tam orada devreye giriyor.
        // Gerçek veride korunan 150 token'ın hepsi kullanıcının yanlış bastığı,
        // dolayısıyla sözlükte olmayan yüzeylerdi.
        let s = try session(["bajmsktan", "ev"], condition: .calibrationReplay)
        // Önce senaryonun gerçekten korunan token ürettiğini doğrula; yoksa
        // test hiçbir şey sınamıyor olabilir.
        #expect(s.actions.contains { $0.commit?.literalProtected == true },
                "kalibrasyon koşulu literal'i korumalı")
        #expect(s.actions.filter { $0.commit?.literalProtected == true }
                    .allSatisfy { $0.commit?.theta == nil },
                "θ = ∞ JSON'a girmiyor")

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.isEmpty, "\(report.divergences)")
        #expect(report.compared > 0)
    }

    /// Koruma kararının **kendisi** hâlâ karşılaştırılıyor.
    ///
    /// `θ` sayısal karşılaştırmadan çıkarıldı; bir taraf korurken diğeri
    /// korumazsa yine yakalanmak zorunda, yoksa muafiyet gerçek bir farkı
    /// gizlerdi.
    @Test("Koruma kararı farkı yakalanıyor")
    func protectionFlagMismatchDiverges() throws {
        let l = layout
        var s = try session(["bajmsktan"], condition: .calibrationReplay)
        let i = try #require(s.actions.firstIndex {
            $0.commit?.literalProtected == true
        })
        s.actions[i].commit?.literalProtected = false
        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "literalProtected" })
    }

    /// **Codex'in senaryosu.** Belge deltası karşılaştırılmadığı sürece kaydın
    /// anlattığı metin replay'in ürettiğinden farklı olabiliyordu.
    ///
    /// Kayıtlı delta değiştirilirse commit, etki ve nihai metin aynı kalıyor —
    /// yalnız belge zinciri ayrışıyor. Karşılaştırılmadığı sürece `isClean`
    /// dönüyordu.
    @Test("Belge deltası farkı yakalanıyor")
    func documentDeltaMismatchDiverges() throws {
        let l = layout
        var s = try session(["ev"])
        let i = try #require(s.actions.firstIndex { $0.document.value != nil })
        // Aynı uzunlukta başka bir metin: nihai metin karşılaştırması bunu
        // yakalamaz, çünkü sonraki deltalar zinciri kendi içinde tutarlı tutar.
        s.actions[i].document = .known(.init(
            mutations: [.insert("x")],
            hashAfter: DocumentReconstruction.hash("x")))

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "document" })
        #expect(!report.isClean)
    }

    /// **Boş `finalText` de bir iddia.**
    ///
    /// Muafiyet varken eylemleri `"ev "` üreten bir kayıt boş metinle temiz
    /// geçiyordu.
    @Test("Boş finalText muaf değil")
    func emptyFinalTextIsNotExempt() throws {
        let l = layout
        var s = try session(["ev"])
        s.finalText = ""
        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "finalText" })
    }

    /// Etiket **yeniden hesaplanıp** karşılaştırılıyor.
    ///
    /// Golden etiket alanlarına hiç bakmıyordu; uydurulmuş bir `targetWord`
    /// replay'den temiz geçiyordu. Kural `Commit.Label.make` içinde tek yerde,
    /// dolayısıyla golden kuralın **değişmesini** de fark olarak görüyor.
    @Test("Etiket farkı yakalanıyor")
    func labelMismatchDiverges() throws {
        let l = layout
        var s = try session(["ev"])
        let i = try #require(s.actions.firstIndex { $0.commit != nil })
        s.actions[i].commit?.label.targetWord = "at"
        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "label.targetWord" })
    }

    /// Gösterilen liste karşılaştırılıyor.
    @Test("Gösterilen liste farkı yakalanıyor")
    func shownMismatchDiverges() throws {
        let l = layout
        var s = try session(["ev"])
        let i = try #require(s.actions.firstIndex { $0.shown.value != nil })
        s.actions[i].shown = .known(.init(
            items: [.init(id: .known("uydurma"), surface: "uydurma",
                          origin: .known(.candidate(id: "uydurma")))],
            completeness: .complete))
        let report = try GoldenReplay.run(s, layout: l, packs: try packSource())
        #expect(report.divergences.contains { $0.field == "shown" })
    }

    /// Bilinmeyen komut (v2 migrasyonu) **atlanmıyor, sayılıyor**. Sessizce
    /// geçmek doğrulanmamış bir kaydı "hiç fark yok" diye gösterirdi.
    @Test("Bilinmeyen komut doğrulanamaz olarak raporlanıyor")
    func unknownCommandIsCounted() throws {
        let l = layout
        var s = try session(["ev"])
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
        let l = layout
        var s = try session(["ev"])
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
        let l = layout
        var s = try session(["ev"])
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
        let l = layout
        var s = try session(["ev"])
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
        let l = layout
        let s = try session(["ev"])

        let report = try GoldenReplay.run(s, layout: l, packs: try packSource(),
                                          currentRevision: "bambaşka")
        #expect(report.environment.codeRevisionDiffers)
        #expect(report.environment.isVerifiable,
                "revision farkı replay'i geçersiz kılmamalı")
        #expect(report.divergences.isEmpty)
    }
}
