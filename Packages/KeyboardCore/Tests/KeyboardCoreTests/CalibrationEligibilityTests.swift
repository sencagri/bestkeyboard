import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions

/// Kalibrasyona **uygunluk** kapısı — §12.3.
///
/// Kapı fail-open'dı: yalnız `alignmentSource` ve reducer'ın kendi ihlal listesi
/// kontrol ediliyordu. Vazgeçilmiş bir deneme, düzeltmenin açık olduğu bir koşul,
/// kalibre bir modelle alınmış bir kayıt ve dokunma yaşam döngüsü bozuk bir kayıt
/// öğrenmeye giriyordu — hepsi "temiz" görünüyordu, çünkü hiçbiri reducer'ın
/// baktığı yerde değil.
///
/// ## Testin şekli
///
/// Önce **uygun** bir kayıt kuruluyor ve örnek ürettiği doğrulanıyor (pozitif
/// kontrol: bu olmadan aşağıdaki her satır boş bir sonucu "dışlandı" sanabilir).
/// Sonra her satır **tek** bir ölçütü bozuyor.
@MainActor
@Suite("Kalibrasyon uygunluk kapısı")
struct CalibrationEligibilityTests {

    private typealias Support = RecordingTestSupport

    /// Kalibrasyona **uygun** bir kayıt: tamamlanmış, kalibrasyon politikası,
    /// kalibrasyonsuz motor, constructed hizalama, iki harfli tek hedef.
    private func eligibleSession() -> CanonicalSession {
        var s = CanonicalSession(
            attemptID: "gate", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .completed,
            promptID: "p", promptText: "ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["ev"]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 2),
            engine: Support.unconfigured(policy: .calibration),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
        s.finalText = "ev "
        s.touches = [Support.touch(0, char: "e", t: 1),
                     Support.touch(1, char: "v", t: 1.1)]
        s.actions = [letter(0, touchID: 0, base: "e", t: 1),
                     letter(1, touchID: 1, base: "v", t: 1.1),
                     boundary(2, t: 1.2)]
        return s
    }

    /// Motoru **yapılandırılmış** hâle getirir; kalibrasyon durumu ayarlanabilir.
    private func configured(_ s: inout CanonicalSession,
                            calibrationApplied: Bool) {
        let cal = CanonicalSession.EngineSnapshot.CalibrationSnapshot(
            applied: calibrationApplied, strongSamples: 0, biasX: [], biasY: [],
            hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                keyX: [], keyY: []),
            sigma: .known(.init(x: [], y: [])))
        s.engine.configuration = .known(.init(
            packs: [], beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
            autoCorrectsOutOfVocabulary: true, scoring: .notApplicable,
            calibration: cal, initialLanguage: nil))
    }

    // MARK: - Pozitif kontrol

    @Test("Uygun kayıt örnek üretiyor")
    func eligibleSessionYieldsSamples() {
        let ext = CalibrationExtraction.extract(eligibleSession(),
                                                layout: Support.layout)
        #expect(ext.excludedSession == nil, "\(String(describing: ext.excludedSession))")
        #expect(ext.samples.count == 2, "iki harf, iki örnek")
    }

    // MARK: - Kapının her satırı

    @Test("Tamamlanmayan deneme dışlanıyor",
          arguments: [CanonicalSession.Status.aborted, .interrupted,
                      .invalid, .recording])
    func unfinishedAttemptIsExcluded(_ status: CanonicalSession.Status) {
        var s = eligibleSession()
        s.status = status
        // `recording` durumunda `endedAt` dolu kalmamalı; yoksa validator
        // bulgusu kapıyı **başka** bir sebeple kapatır ve test ölçtüğünü
        // ölçmez.
        if status == .recording { s.endedAt = nil }
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.excludedSession == .notCompleted(status))
        #expect(ext.samples.isEmpty)
    }

    @Test("Düzeltme uygulanan koşul dışlanıyor")
    func appliedCorrectionIsExcluded() {
        var s = eligibleSession()
        s.engine.policy.correction = .known(.applied)
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.excludedSession
                == .policyNotCalibration("düzeltme uygulanıyordu"))
        #expect(ext.samples.isEmpty)
    }

    /// Bilinmeyen politika **uygun sayılmıyor**.
    ///
    /// v2 kayıtlarında düzeltme durumu yok; onu "muhtemelen bastırılmıştı" diye
    /// geçirmek, bilmediğimizi bildiğimiz gibi kullanmak olurdu.
    @Test("Bilinmeyen düzeltme durumu dışlanıyor")
    func unknownCorrectionIsExcluded() {
        var s = eligibleSession()
        s.engine.policy.correction = .unknown
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.excludedSession
                == .policyNotCalibration("düzeltme durumu bilinmiyor"))
    }

    @Test("Canlı öğrenme dışlanıyor")
    func liveLearningIsExcluded() {
        var s = eligibleSession()
        s.engine.policy.learning = .live
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.excludedSession == .policyNotCalibration("öğrenme canlıydı"))
    }

    /// Kalibre bir modelle alınan kayıttan yeniden sapma öğrenmek, aynı
    /// düzeltmeyi iki kez uygulamaktır.
    @Test("Kalibre modelle alınan kayıt dışlanıyor")
    func alreadyCalibratedRecordingIsExcluded() {
        var s = eligibleSession()
        configured(&s, calibrationApplied: true)
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.excludedSession == .calibrationAlreadyApplied)

        // Kontrol: aynı kayıt `applied: false` ile **uygun**. Bu satır olmadan
        // yukarıdaki, `configuration`'ı doldurmanın kendisinden de geçebilirdi.
        var ok = eligibleSession()
        configured(&ok, calibrationApplied: false)
        #expect(CalibrationExtraction.extract(ok, layout: Support.layout)
                .excludedSession == nil)
    }

    /// **Reducer'ın görmediği** bir yapısal bulgu da kapıyı kapatıyor.
    ///
    /// Eskiden yalnız reducer'ın kendi ihlal listesine bakılıyordu; dokunma
    /// yaşam döngüsü, §2.1 etki tablosu, zaman penceresi ve tokenID tekilliği
    /// orada görünmüyor ve hepsi koordinatları güvenilmez yapabiliyor.
    @Test("Yapısal bulgu taşıyan kayıt dışlanıyor")
    func structuralFindingExcludesTheRecord() {
        var s = eligibleSession()
        // Zaman penceresi ihlali: saat tabanı karışıklığının imzası.
        s.actions[0].t = -806_576_468
        let findings = SessionValidator.validate(s)
        #expect(findings.contains { $0.kind == .timeOutOfSessionWindow },
                "önce bulgunun gerçekten üretildiğini doğrula")
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        guard case .structurallyInvalid = ext.excludedSession else {
            let got = String(describing: ext.excludedSession)
            Issue.record("beklenen structurallyInvalid, gelen: \(got)")
            return
        }
        #expect(ext.samples.isEmpty)
    }

    @Test("Sequential hizalama dışlanıyor")
    func sequentialAlignmentIsExcluded() {
        var s = eligibleSession()
        s.alignmentSource = .sequential
        #expect(CalibrationExtraction.extract(s, layout: Support.layout)
                .excludedSession == .alignmentNotConstructed(.sequential))
    }

    // MARK: - Yardımcılar

    private func letter(_ id: Int, touchID: Int, base: Character,
                        t: TimeInterval) -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: .letter, touchID: touchID,
              event: .known(.letter(baseKey: String(base),
                                    display: String(base), shifted: false)),
              effect: .notApplicable,
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: 0, targetToken: nil,
              candidates: .notApplicable, shown: .notApplicable, commit: nil)
    }

    private func boundary(_ id: Int, t: TimeInterval) -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: .space, touchID: nil,
              event: .known(.space), effect: .known(.boundary),
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: 0, targetToken: "ev",
              candidates: .notApplicable, shown: .notApplicable,
              commit: .init(kind: .literal, tokenID: .known(TokenID(raw: 0)),
                            literal: "ev", displayBefore: "ev", committed: "ev",
                            delta: nil, theta: nil, bestCost: nil, bestWord: nil,
                            language: 0, touchCount: 2, casingApplied: false,
                            literalProtected: true,
                            label: .init(source: .protocol, confidence: .strong,
                                         targetWord: "ev", matchesTarget: true),
                            cursorBefore: .known(0)))
    }
}
