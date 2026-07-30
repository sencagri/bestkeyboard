import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions

/// §12.5 etiketinin **semantik** doğrulaması.
///
/// Etiket, kalibrasyona giren tek yargı: `confidence == .strong` olan token'ın
/// harfleri hedef tuşlara güçlü örnek olarak yazılıyor. Değerinin doğru
/// üretildiğini hiçbir şey sınamıyordu — validator etiketin hedef token, cursor,
/// literal ve hizalama ile ilişkisine bakmıyor, golden da etiket alanlarını
/// karşılaştırmıyordu.
///
/// Codex'in verdiği senaryo aynen buradaki ilk test: geçerli bir `ev` commit'inin
/// etiketini `targetWord: "at"` yapmak yeterliydi; zincir temiz kalıyor ve
/// çıkarıcı `e`/`v` koordinatlarını `a`/`t` tuşlarına yazıyordu.
///
/// Bu doğrulama depodaki fixture'ın **bayatladığını** da yakaladı: `targetWord`
/// hiç yazılmamış bir sürümden kalmıştı ve hiçbir test bunu görmüyordu.
@MainActor
@Suite("Etiket doğrulaması")
struct LabelValidationTests {

    private typealias Support = RecordingTestSupport

    /// Hedefli, tamamlanmış, tek token'lı temiz bir kayıt.
    private func session(condition: CanonicalSession.Condition = .calibrationReplay,
                         alignment: CanonicalSession.AlignmentSource = .constructed)
        -> CanonicalSession {
        var s = CanonicalSession(
            attemptID: "label", participantID: "p", sessionOrdinal: 0,
            condition: condition, status: .completed,
            promptID: "p", promptText: "ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["ev"]),
            alignmentSource: alignment,
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
                     boundary(2, t: 1.2, literal: "ev",
                              label: .init(source: .protocol, confidence: .strong,
                                           targetWord: "ev", matchesTarget: true))]
        return s
    }

    private func labels(_ s: CanonicalSession) -> [SessionValidator.Finding] {
        SessionValidator.validate(s).filter { $0.kind == .labelInconsistent }
    }

    /// Pozitif kontrol: doğru etiket bulgu üretmiyor.
    ///
    /// Onsuz aşağıdaki her test, kaydın **başka** bir sebeple bulgu üretmesinden
    /// de geçebilirdi.
    @Test("Doğru etiket temiz")
    func correctLabelIsClean() {
        #expect(labels(session()).isEmpty, "\(SessionValidator.validate(session()))")
    }

    /// **Codex'in senaryosu.** Hedef kelime uydurulmuş.
    @Test("Uydurulmuş targetWord yakalanıyor")
    func fabricatedTargetWordIsCaught() {
        var s = session()
        s.actions[2].commit?.label = .init(source: .protocol, confidence: .strong,
                                          targetWord: "at", matchesTarget: true)
        let f = labels(s)
        #expect(f.contains { $0.detail.contains("targetWord=at") })
        // Aynı etiket `matchesTarget`'ı da yalanlıyor: literal `ev`, hedef `at`.
        #expect(f.contains { $0.detail.contains("matchesTarget=true") })
        // Ve kapı kapanıyor: bu kayıt artık öğrenmeye girmiyor.
        let ext = CalibrationExtraction.extract(s, layout: Support.layout)
        #expect(ext.samples.isEmpty)
    }

    @Test("matchesTarget türetimle çelişemez")
    func matchesTargetMustFollowFromLiteral() {
        var s = session()
        s.actions[2].commit?.label = .init(source: .protocol, confidence: .weak,
                                          targetWord: "ev", matchesTarget: false)
        #expect(labels(s).contains { $0.detail.contains("matchesTarget=false") })
    }

    /// Türkçe küçültme yazıcıyla **aynı** kuralla yapılıyor.
    ///
    /// İki kopya olsaydı biri `Locale`'i unutur ve `Ali`/`ali` karşılaştırması
    /// iki tarafta farklı sonuç verirdi — doğrulama yazıcıyı onaylamış olurdu.
    @Test("Büyük/küçük harf farkı eşleşmeyi bozmuyor")
    func caseFoldingUsesTurkishLocale() {
        var s = session()
        s.promptTokens = .known(["Ev"])
        s.actions[2].commit?.label = .init(source: .protocol, confidence: .strong,
                                          targetWord: "Ev", matchesTarget: true)
        #expect(labels(s).isEmpty, "literal 'ev' ile hedef 'Ev' eşleşir")
    }

    /// `strong` yalnız **hedefli protokolde** meşru.
    @Test("Hedefsiz koşulda strong yakalanıyor")
    func strongOutsideTheProtocolIsCaught() {
        var s = session(condition: .behavior, alignment: .sequential)
        s.actions[2].commit?.label = .init(source: .protocol, confidence: .strong,
                                          targetWord: "ev", matchesTarget: true)
        let f = labels(s)
        #expect(f.contains { $0.detail.contains("source=protocol") })
        #expect(f.contains { $0.detail.contains("hizalama protokolden gelmiyor") })
    }

    /// Hizalama bozulduktan **sonra** `strong` olamaz.
    ///
    /// Sapma protokolün verdiği kesinliği de götürüyor: token artık gösterilen
    /// kelimeye bağlı değil. Nihai duruma bakan bir kontrol sapmadan **önceki**
    /// token'ları da suçlardı; bu yüzden sapma eylem sırasına göre izleniyor.
    @Test("Sapmadan sonra strong yakalanıyor")
    func strongAfterDivergenceIsCaught() throws {
        var s = session()
        s.promptTokens = .known(["at", "ev"])
        // Atfedilemez bir silme sapma başlatıyor.
        s.actions.insert(
            .init(actionID: 2, t: 1.15, kind: .backspaceTap, touchID: nil,
                  event: .known(.backspaceTap),
                  effect: .known(.init(pending: .none,
                                       deleted: [.unattributed],
                                       evidenceStateAfter: .cleared)),
                  document: .known(.init(mutations: [], hashAfter: 0)),
                  targetTokenIndex: 0, targetToken: nil,
                  candidates: .notApplicable, shown: .notApplicable, commit: nil),
            at: 2)
        s.actions[3] = boundary(3, t: 1.2, literal: "ev",
                                label: .init(source: .protocol,
                                             confidence: .strong,
                                             targetWord: "at",
                                             matchesTarget: false))
        #expect(labels(s).contains {
            $0.detail.contains("hizalama bu action'dan önce bozulmuştu")
        })

        // Kontrol: aynı silme **olmadan** sapma bulgusu yok. Yoksa test her
        // `strong` etiketi suçluyor olabilirdi.
        var clean = session()
        clean.promptTokens = .known(["ev"])
        #expect(!labels(clean).contains {
            $0.detail.contains("hizalama bu action'dan önce bozulmuştu")
        })
    }

    /// Hedef dizisinin **dışındaki** cursor için hedef kelime olamaz.
    @Test("Hedef dışı cursor için targetWord olamaz")
    func targetOutsidePromptMustBeNil() {
        var s = session()
        s.actions[2].commit?.cursorBefore = .known(7)
        s.actions[2].commit?.label = .init(source: .protocol, confidence: .weak,
                                          targetWord: "ev", matchesTarget: true)
        #expect(labels(s).contains { $0.detail.contains("hedef dışı") })
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

    private func boundary(_ id: Int, t: TimeInterval, literal: String,
                          label: CanonicalSession.Action.Commit.Label)
        -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: .space, touchID: nil,
              event: .known(.space), effect: .known(.boundary),
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: 0, targetToken: label.targetWord,
              candidates: .notApplicable, shown: .notApplicable,
              commit: .init(kind: .literal, tokenID: .known(TokenID(raw: 0)),
                            literal: literal, displayBefore: literal,
                            committed: literal, delta: nil, theta: nil,
                            bestCost: nil, bestWord: nil, language: 0,
                            touchCount: literal.count, casingApplied: false,
                            literalProtected: true, label: label,
                            cursorBefore: .known(0)))
    }
}
