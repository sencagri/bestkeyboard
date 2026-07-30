import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions

/// **Cihazdan çekilen gerçek kayıtta ölçülen iki hata.**
///
/// İkisi de test kümesi tamamen yeşilken diskteydi ve sebebi aynı: fixture'lar
/// gerçek cihazın ürettiği şekli üretmiyordu. Bir dokunma için tek `.ended`
/// frame yazılıyordu (cihaz `began/moved/ended` yazıyor) ve bütün zaman
/// damgaları aynı sentetik saatten geliyordu (cihazda iki taban var).
///
/// Buradaki testler o iki şekli **kasten** kuruyor.
@MainActor
@Suite("Saat tabanı ve dokunma fazı")
struct ClockAndTouchPhaseTests {

    private typealias Support = RecordingTestSupport

    private func descriptor(prompt: [String]) -> CanonicalSession {
        CanonicalSession(
            attemptID: "clock", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt), alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: Support.unconfigured(policy: .calibration),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    /// Belirtilen tuşun merkezine, verilen fazda bir dokunma.
    private func touch(_ id: Int, char: Character,
                       phase: CanonicalSession.Touch.Phase,
                       outcome: CanonicalSession.Touch.Outcome,
                       t: TimeInterval) -> CanonicalSession.Touch {
        var x = Support.touch(id, char: char, t: t)
        x.phase = phase
        x.outcome = outcome
        return x
    }

    // MARK: - Dokunma fazı

    /// **Son faz kazanıyor.**
    ///
    /// Canlı motor `touches[id] = touch` ile son fazı görüyordu; diskten okuyan
    /// taraf `uniquingKeysWith: { a, _ in a }` ile **ilkini** seçiyordu. Yani
    /// decoder `ended` koordinatını kullanırken kalibrasyon `began`
    /// koordinatını öğreniyordu. Gerçek kayıtta ölçüldü: dokunma 1 için
    /// `began normX=0.073`, `ended normX=0.077`.
    @Test("Katlama dokunmanın son fazını kullanıyor")
    func foldingUsesTheTerminalPhase() throws {
        var session = descriptor(prompt: ["ev"])
        // Parmak `a` tuşunda başlıyor, `e` tuşunda bitiyor. Harf **`e`**.
        session.touches = [
            touch(0, char: "a", phase: .began, outcome: .pending, t: 1),
            touch(0, char: "a", phase: .moved, outcome: .pending, t: 1.1),
            touch(0, char: "e", phase: .ended, outcome: .committed, t: 1.2),
        ]
        let terminal = session.terminalTouches
        #expect(terminal.count == 1)
        let picked = try #require(terminal[0])
        #expect(picked.phase == .ended)
        #expect(picked.key == "e", "sürüklenen parmağın BİTTİĞİ tuş")
        #expect(picked.outcome == .committed)

        // Reducer da aynı noktayı görüyor: atom'un koordinatı `e`nin merkezi.
        session.actions = [letterAction(0, touchID: 0, t: 1.2)]
        let state = SessionEventReducer.reduce(session)
        #expect(state.pending.count == 1)
        #expect(state.pending[0].touch.key == "e")
        #expect(state.pending[0].keyIndex == Support.layout.keyIndex(for: "e"))
    }

    /// `outcome` da faza bağlı: `began` daima `pending`.
    ///
    /// İlk faza bakan bir reducer `neverHit`'i **hiç** göremiyordu — yani
    /// kullanıcının "bastım ama hiçbir tuşa denk gelmedi" olgusu ölçülemiyordu.
    @Test("neverHit son fazdan okunuyor")
    func neverHitIsReadFromTheTerminalPhase() throws {
        var session = descriptor(prompt: ["ev"])
        var began = touch(0, char: "e", phase: .began, outcome: .pending, t: 1)
        began.keyIndex = nil
        began.key = nil
        var ended = touch(0, char: "e", phase: .ended, outcome: .neverHit, t: 1.1)
        ended.keyIndex = nil
        ended.key = nil
        session.touches = [began, ended]
        session.actions = [letterAction(0, touchID: 0, t: 1.1)]

        let state = SessionEventReducer.reduce(session)
        #expect(state.pending.isEmpty, "hiçbir tuşa denk gelmeyen dokunma token'a girmez")
        #expect(state.dropped.count == 1)
        #expect(state.dropped[0].reason == .neverHit)
    }

    /// Kalibrasyon **bitiş** koordinatını öğreniyor, başlangıç koordinatını değil.
    @Test("Kalibrasyon son fazın koordinatını öğreniyor")
    func calibrationLearnsTheTerminalCoordinate() throws {
        var session = descriptor(prompt: ["ev"])
        session.status = .completed
        session.endedAt = Date(timeIntervalSince1970: 3)
        session.finalText = "ev "

        // `e` doğru basılmış; `v` parmağı `c`de başlayıp `v`de bitiyor.
        session.touches = [
            touch(0, char: "e", phase: .began, outcome: .pending, t: 1),
            touch(0, char: "e", phase: .ended, outcome: .committed, t: 1.1),
            touch(1, char: "c", phase: .began, outcome: .pending, t: 1.2),
            touch(1, char: "v", phase: .ended, outcome: .committed, t: 1.3),
        ]
        session.actions = [
            letterAction(0, touchID: 0, t: 1.1),
            letterAction(1, touchID: 1, t: 1.3),
            boundaryAction(2, t: 1.4, literal: "ev", target: "ev"),
        ]

        let ext = CalibrationExtraction.extract(session, layout: Support.layout)
        #expect(ext.excludedSession == nil)
        #expect(ext.samples.count == 2)
        // Hedef `v`; öğrenilen nokta `v` tuşunun merkezi olmalı, `c`nin değil.
        let vIndex = try #require(Support.layout.keyIndex(for: "v"))
        let cIndex = try #require(Support.layout.keyIndex(for: "c"))
        let vSample = try #require(ext.samples.first { $0.keyIndex == vIndex })
        #expect(abs(vSample.point.x - Support.layout.keys[vIndex].center.x) < 1e-9,
                "sürüklemenin BİTTİĞİ nokta öğrenilmeli")
        #expect(abs(vSample.point.x - Support.layout.keys[cIndex].center.x) > 1e-9)
        // Dokunma hedef tuşta bitmiş: sapma sayılmıyor.
        #expect(ext.recoveredDriftedTouches == 0)
    }

    // MARK: - Saat tabanı

    /// **Başka saatten gelen dokunma reddediliyor.**
    ///
    /// Cihazda `UITouch.timestamp` (açılışa göre, ~521 032) ile
    /// `CFAbsoluteTimeGetCurrent()` (duvar saati, ~807 000 000) aynı alanda
    /// karışıyordu ve harf action'larının `t`'si −806 576 468 oluyordu. Hiçbir
    /// şey bunu yakalamıyordu.
    @Test("Başka saat tabanından gelen dokunma reddediliyor")
    func touchFromAnotherClockIsRejected() throws {
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(
            writer: writer,
            coordinator: InputCoordinator(layout: Support.layout),
            layout: Support.layout)
        // Deneme duvar saatiyle başlıyor…
        try engine.begin(descriptor(prompt: ["ev"]), at: 807_000_000)
        try RecordingTestSupport.configure(engine)

        // …dokunma açılış saatiyle geliyor.
        let stray = Support.touch(0, char: "e", t: 521_032)
        #expect(throws: RecordingEngine.IngressError
            .clockMismatch(touchID: 0, touch: 521_032, start: 807_000_000)) {
            try engine.record(stray)
        }

        // Aynı tabandan gelen dokunma **kabul ediliyor**: kontrol her dokunmayı
        // reddetmiyor, yalnız tabanı karışanı.
        try engine.record(Support.touch(1, char: "e", t: 807_000_001))
    }

    /// Negatif `t` yapısal bir bulgu — monotonluk kontrolü onu yakalamıyordu.
    @Test("Negatif t validator bulgusu")
    func negativeActionTimeIsAFinding() {
        var session = descriptor(prompt: ["ev"])
        session.touches = [Support.touch(0, char: "e", t: 1)]
        // Gerçek kayıttan alınan büyüklük.
        session.actions = [letterAction(0, touchID: 0, t: -806_576_468.37)]
        let findings = SessionValidator.validate(session)
        #expect(findings.contains { $0.kind == .timeOutOfSessionWindow })
        // Monotonluk **tek başına** yeşil geçiyordu: tek action'lı bir dizide
        // (ve gerçek kayıtta olduğu gibi hepsi negatifken) zaman hep artıyor.
        #expect(!findings.contains { $0.kind == .timeNotMonotonic })
    }

    @Test("endedAt startedAt'tan önce olamaz")
    func endedBeforeStartedIsAFinding() {
        var session = descriptor(prompt: ["ev"])
        session.status = .interrupted
        // Kurtarma negatif `at` yazdığında tam olarak bu oluyordu.
        session.endedAt = Date(timeIntervalSince1970: -806_576_462)
        let findings = SessionValidator.validate(session)
        #expect(findings.contains {
            $0.kind == .timeOutOfSessionWindow
                && $0.detail.contains("startedAt'tan önce")
        })
    }

    // MARK: - Yardımcılar

    private func letterAction(_ id: Int, touchID: Int,
                              t: TimeInterval) -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: .letter, touchID: touchID,
              event: .known(.letter(baseKey: "e", display: "e", shifted: false)),
              effect: .notApplicable,
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: 0, targetToken: nil,
              candidates: .notApplicable, shown: .notApplicable, commit: nil)
    }

    private func boundaryAction(_ id: Int, t: TimeInterval,
                               literal: String,
                               target: String) -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: .space, touchID: nil,
              event: .known(.space), effect: .known(.boundary),
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: 0, targetToken: target,
              candidates: .notApplicable, shown: .notApplicable,
              commit: .init(kind: .literal, tokenID: .known(TokenID(raw: 0)),
                            literal: literal, displayBefore: literal,
                            committed: literal, delta: nil, theta: nil,
                            bestCost: nil, bestWord: nil, language: 0,
                            touchCount: literal.count, casingApplied: false,
                            literalProtected: true,
                            label: .init(source: .protocol, confidence: .strong,
                                         targetWord: target, matchesTarget: true),
                            cursorBefore: .known(0)))
    }
}
