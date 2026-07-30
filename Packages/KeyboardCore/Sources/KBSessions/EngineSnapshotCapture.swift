import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBRuntime

/// Kurulu bir motordan **kayıt anlık görüntüsü** üretir — plan v8 §2.8.
///
/// ## Neden burada
///
/// Anlık görüntüyü elle doldurmak, `ReplayEngineFactory`'nin okuduğu alanlarla
/// yazan tarafın ayrışmasına açık kapı bırakıyordu: bir parametre eklendiğinde
/// fabrika onu arıyor ama yazıcı koymuyor ve replay farkı "kod regresyonu" diye
/// raporlanıyordu. Yakalama ile kurulum **aynı dosyada**, karşılıklı.
public extension CanonicalSession.EngineSnapshot {

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
                packs: loaded.packs.map {
                    .init(name: $0.name,
                          // Özet **istenmediyse** yok; `""` yazmak kaydı
                          // doğrulanabilir gösterip aslında değil yapardı.
                          sha256: $0.sha256.map { Epistemic.known($0) } ?? .unknown,
                          bytes: $0.bytes,
                          // Rol **tek** enum: iki ayrı tanım ve
                          // `?? .forms` yedeği, yeni bir rolü sessizce
                          // `forms` sanmak demekti.
                          topology: .known(.init(
                            role: $0.role,
                            language: Int($0.language),
                            sourceOrder: $0.sourceOrder, offset: $0.offset)))
                },
                beamWidth: loaded.decoder.beamWidth,
                oovTheta: coordinator.oovTheta,
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
