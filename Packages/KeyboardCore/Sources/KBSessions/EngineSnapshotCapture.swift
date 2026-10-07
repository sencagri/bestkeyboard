import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBRuntime
import KBSpatial

/// Kurulu bir motordan **kayıt anlık görüntüsü** üretir — plan v8 §2.8.
///
/// ## Neden burada
///
/// Anlık görüntüyü elle doldurmak, `ReplayEngineFactory`'nin okuduğu alanlarla
/// yazan tarafın ayrışmasına açık kapı bırakıyordu: bir parametre eklendiğinde
/// fabrika onu arıyor ama yazıcı koymuyor ve replay farkı "kod regresyonu" diye
/// raporlanıyordu. Yakalama ile kurulum **aynı dosyada**, karşılıklı.
public extension CanonicalSession.EngineSnapshot {

    /// Kalibrasyonu **kurulan motordan** okur.
    ///
    /// Çağıranın verdiği anlık görüntü, motorun fiilen taşıdığı kalibrasyonla
    /// ayrışabiliyordu: uzantı `applied: false` ve sıfır dizilerle yazıyor ama
    /// canlı decoder öğrenilmiş profili uygulamış oluyordu. Kayıt böylece
    /// **kendi motorunu yanlış anlatıyor** ve replay farkı "kod değişti" diye
    /// okunuyordu.
    ///
    /// Sıfır sapmalı bir model `applied: false` sayılıyor: uygulanmış ama etkisi
    /// olmayan bir kalibrasyon ile hiç uygulanmamış olan, replay açısından aynı
    /// motor.
    static func calibrationSnapshot(of spatial: SpatialModel)
        -> CalibrationSnapshot {
        let biasX = spatial.calib.map(\.biasX)
        let biasY = spatial.calib.map(\.biasY)
        let applied = biasX.contains { $0 != 0 } || biasY.contains { $0 != 0 }
        return .init(applied: applied, strongSamples: 0,
                     biasX: biasX, biasY: biasY,
                     hierarchical: .init(globalX: 0, globalY: 0, rowX: [],
                                         rowY: [], keyX: [], keyY: []),
                     sigma: .known(.init(x: spatial.calib.map(\.sigmaX),
                                         y: spatial.calib.map(\.sigmaY))))
    }

    /// Kaydedilen kalibrasyonun decoder'a uygulanamamasının sebebi.
    internal enum CalibrationFailure: Error, Equatable, Sendable, CustomStringConvertible {
        /// σ v2'de kaydedilmiyordu → `.unknown`.
        case sigmaUnknown
        /// σ olgusu bu kayıtta yok (`.notApplicable`).
        case sigmaNotRecorded
        /// Diziler layout'un tuş sayısını karşılamıyor.
        case lengthMismatch(keys: Int)

        var description: String {
            switch self {
            case .sigmaUnknown, .sigmaNotRecorded: return "σ bilinmiyor"
            case let .lengthMismatch(n): return "dizi uzunluğu \(n) tuşu karşılamıyor"
            }
        }
    }

    /// Kaydedilen kalibrasyonu decoder'a uygular — **tek** uygulama.
    ///
    /// Hem `RecordingEngine.configure` hem `ReplayEngineFactory` buradan
    /// geçiyor. Önce yalnız replay uyguluyordu: `configure` snapshot'ı
    /// **kaydediyor ama motora uygulamıyordu**, yani `applied: true` verilen
    /// bir kayıtta canlı motor kalibrasyonsuz koşarken kayıt "uygulandı"
    /// diyor ve replay kalibrasyonlu koşuyordu. Fark ortam uyuşmazlığı
    /// olarak da görünmüyordu — sahte bir kod regresyonu olarak okunurdu.
    /// Sonra ikisi de uyguladı ama σ seçimi, uzunluk kontrolü ve decoder'ın
    /// yeniden kurulması iki kopyada duruyordu.
    ///
    /// Bias **ve** ölçek birlikte: sapmayı uygulayıp ölçeği atlamak, aynı
    /// dokunmayı farklı bir olasılıkla puanlamak demek — hangisinin fark
    /// ürettiği de ayırt edilemezdi.
    ///
    /// Kısa dizide sessizce durmak da tehlikeliydi: yarısı kalibre bir model
    /// kurulup ortam yine "doğrulanabilir" kalıyordu. Eksik dizi **hiçbir şey
    /// uygulamıyor** ve çağıran sebebi öğreniyor; tepkisini (denemeyi reddetmek
    /// ya da ortam olgusu yazmak) kendisi seçiyor.
    ///
    /// - Returns: `applied == false` ise decoder **olduğu gibi**.
    internal static func calibrated(_ decoder: Decoder, with cal: CalibrationSnapshot,
                           layout: KeyLayout) throws(CalibrationFailure) -> Decoder {
        guard cal.applied else { return decoder }
        let sigma: CalibrationSnapshot.Sigma
        switch cal.sigma {
        case let .known(s):  sigma = s
        case .unknown:       throw .sigmaUnknown
        case .notApplicable: throw .sigmaNotRecorded
        }
        let n = layout.keys.count
        guard cal.biasX.count >= n, cal.biasY.count >= n,
              sigma.x.count >= n, sigma.y.count >= n else {
            throw .lengthMismatch(keys: n)
        }
        var spatial = decoder.spatial
        for i in 0..<n {
            spatial.setCalibration(.init(biasX: cal.biasX[i], biasY: cal.biasY[i],
                                         sigmaX: sigma.x[i], sigmaY: sigma.y[i]),
                                   at: i)
        }
        // `with(spatial:)`: bigram paketi ve dil durumu da taşınıyor — elle
        // yeniden kurmak onları düşürüyordu ve kalibre kayıtlar `F_ctx`'siz bir
        // motoru ölçüyordu.
        return decoder.with(spatial: spatial)
    }

    /// Kişisel sözlük kaynağının paket kaydı (§8.7) — kurulu değilse boş.
    ///
    /// `loaded.packs` bunu göremez: kişisel kaynak paketlerden değil, motor
    /// kurulduktan **sonra** koordinatör tarafından ekleniyor. Yazılmazsa
    /// kayıt, decoder'ın leksikonunu eksik anlatır ve replay farkı "kod
    /// değişti" diye okunurdu (§12.1).
    ///
    /// Diskte karşılığı yok; `ReplayEngineFactory` bunu `missingPacks`'e
    /// yazacak ve replay **ortam uyuşmazlığı** olarak işaretlenecek. İstenen
    /// tam olarak bu: kişisel sözlükle kaydedilmiş bir yazım, o sözlük olmadan
    /// birebir yeniden üretilemez ve kayıt bunu söylemeli.
    private static func personalPacks(_ coordinator: InputCoordinator)
        -> [PackRef] {
        guard let ref = coordinator.personalSourceRef else { return [] }
        return [.init(name: "personal.\(ref.wordCount)",
                      sha256: .known(ref.sha256),
                      bytes: ref.byteCount,
                      topology: .known(.init(role: .personal,
                                             language: Int(ref.language),
                                             sourceOrder: ref.sourceOrder,
                                             offset: 0)))]
    }

    /// - Parameter loaded: `PackLoader`'ın kurduğu motor.
    static func capture(loaded: PackLoader.Loaded,
                        coordinator: InputCoordinator,
                        buildConfiguration: String,
                        appVersion: String,
                        build: BuildManifest,
                        policy: RecordingPolicy,
                        calibration: CalibrationSnapshot)
        -> CanonicalSession.EngineSnapshot {
        .init(buildConfiguration: buildConfiguration, appVersion: appVersion,
              build: build, policy: .init(policy),
              configuration: .known(.init(
                packs: loaded.packs.map { pack -> PackRef in
                    .init(name: pack.name,
                          // Özet **istenmediyse** yok; `""` yazmak kaydı
                          // doğrulanabilir gösterip aslında değil yapardı.
                          sha256: pack.sha256.map { Epistemic.known($0) } ?? .unknown,
                          bytes: pack.bytes,
                          // Rol **tek** enum: iki ayrı tanım ve
                          // `?? .forms` yedeği, yeni bir rolü sessizce
                          // `forms` sanmak demekti.
                          topology: .known(.init(
                            role: pack.role,
                            language: Int(pack.language),
                            sourceOrder: pack.sourceOrder, offset: pack.offset)))
                } + personalPacks(coordinator),
                beamWidth: loaded.decoder.beamWidth,
                oovTheta: coordinator.correction.oovTheta,
                suggestionWindow: coordinator.suggestionWindow,
                autoCorrectsOutOfVocabulary:
                    loaded.literalChannel.autoCorrectsOutOfVocabulary,
                scoring: .known(.init(
                    decoder: .init(loaded.decoder.weights),
                    literalChannel: .init(loaded.literalChannel.weights),
                    cUnk: loaded.literalChannel.cUnk,
                    sigmaMin: loaded.decoder.spatial.sigmaMin,
                    decoderLanguageModel: .init(
                        prior: loaded.decoder.languageModel.prior,
                        previous: loaded.decoder.languageModel.previous),
                    literalChannelLanguageModel: .init(
                        prior: loaded.literalChannel.languageModel.prior,
                        previous: loaded.literalChannel.languageModel.previous))),
                calibration: calibration,
                initialLanguage: loaded.decoder.languageModel.previous.map(Int.init))))
    }
}

public extension CanonicalSession.EngineSnapshot.ScoringConfig.WeightsSnapshot {
    /// Çalışan ağırlıklardan kayıt anlık görüntüsü.
    ///
    /// Eşleme **elle** ve tam; `ScoreWeightsSnapshotTests` her alanın gidip
    /// geldiğini yansımayla sayarak sabitliyor. Yeni bir ağırlık eklenip burada
    /// unutulursa test kırılıyor — sessizce düşseydi replay onu varsayılanıyla
    /// kurar ve fark "kod değişti" diye raporlanırdı.
    init(_ w: ScoreWeights) {
        self.init(wSpaEq: w.wSpaEq, wEq: w.wEq, wOmGem: w.wOmGem,
                  wOmInit: w.wOmInit, wOm: w.wOm, wInsNear: w.wInsNear,
                  wInsRepeat: w.wInsRepeat, wIns: w.wIns, wInsBg: w.wInsBg,
                  wTr: w.wTr, wLen: w.wLen, wLex: w.wLex, wCtx: w.wCtx,
                  wLang: w.wLang, wSwitch: w.wSwitch,
                  maxConsecutiveOmissions: w.maxConsecutiveOmissions,
                  maxKeyCandidates: w.maxKeyCandidates,
                  candidateCostWindow: w.candidateCostWindow,
                  tauFast: w.tauFast, dNear: w.dNear)
    }

    /// Kayıttan çalışan ağırlıklara — `ReplayEngineFactory`'nin kullandığı yön.
    var scoreWeights: ScoreWeights {
        var w = ScoreWeights()
        w.wSpaEq = wSpaEq; w.wEq = wEq
        w.wOmGem = wOmGem; w.wOmInit = wOmInit; w.wOm = wOm
        w.wInsNear = wInsNear; w.wInsRepeat = wInsRepeat
        w.wIns = wIns; w.wInsBg = wInsBg
        w.wTr = wTr; w.wLen = wLen; w.wLex = wLex
        w.wCtx = wCtx; w.wLang = wLang; w.wSwitch = wSwitch
        w.maxConsecutiveOmissions = maxConsecutiveOmissions
        w.maxKeyCandidates = maxKeyCandidates
        w.candidateCostWindow = candidateCostWindow
        w.tauFast = tauFast; w.dNear = dNear
        return w
    }
}
