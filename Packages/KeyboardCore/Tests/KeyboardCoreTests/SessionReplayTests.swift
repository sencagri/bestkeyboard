import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLearning
@testable import KBSessions

/// Yazım kaydı şeması ve replay — sözleşme §12.
///
/// Bu testlerin varlık sebebi doğrudan bir bulgu: şema ve importer önce
/// uygulamada ve `kbbench` içinde, yani **test hedefi olmayan** yerlerde
/// duruyordu. Token türetimi (geri silme, öneri seçimi, yeniden açılan token)
/// tam da hata yapılacak yer ve tek bir test yoktu.
final class SessionReplayTests: XCTestCase {

    private let layout = TurkishQ.layout()

    // MARK: - Yardımcılar

    private func blankEngine() -> TypingSession.EngineSnapshot {
        .init(buildConfiguration: "Release", appVersion: "test", packs: [],
              beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
              autoCorrectsOutOfVocabulary: true,
              calibration: .init(applied: false, strongSamples: 0,
                                 globalX: 0, globalY: 0, rowX: [], rowY: [],
                                 keyX: [], keyY: [], biasX: [], biasY: []),
              learningFrozen: true, codeRevision: "test", initialLanguage: nil)
    }

    private func blankGeometry() -> TypingSession.Geometry {
        .init(layoutID: layout.id, boundsX: 0, boundsY: 0,
              boundsWidth: 393, boundsHeight: 216,
              frameInScreenX: 0, frameInScreenY: 600,
              frameInScreenWidth: 393, frameInScreenHeight: 216,
              safeAreaBottom: 34, screenScale: 3, interfaceOrientation: "portrait",
              deviceModel: "test", systemVersion: "0")
    }

    private func session(prompt: String,
                         condition: TypingSession.Condition = .calibrationReplay,
                         alignment: TypingSession.AlignmentSource = .constructed)
        -> TypingSession {
        TypingSession(attemptID: "t", participantID: "p", sessionOrdinal: 0,
                      condition: condition, promptID: "x", promptText: prompt,
                      promptSource: .builtin, split: "train",
                      alignmentSource: alignment, startedAt: Date(),
                      posture: .init(), engine: blankEngine(),
                      geometry: blankGeometry())
    }

    private var nextTouch = 0
    private var nextAction = 0

    /// Bir harfi **verilen noktaya** basar. `at` verilmezse tuş merkezine.
    private func typeLetter(_ ch: Character, into s: inout TypingSession,
                            targetIndex: Int, at point: Point? = nil,
                            hitKey: Character? = nil) {
        let hit = hitKey ?? ch
        guard let k = layout.keyIndex(for: hit) else { return XCTFail("tuş yok: \(hit)") }
        let p = point ?? layout.keys[k].center
        s.touches.append(.init(touchID: nextTouch, phase: "ended", outcome: "committed",
                               rawX: p.x * 393, rawY: p.y * 216,
                               normX: p.x, normY: p.y, decoderX: p.x, decoderY: p.y,
                               timestamp: Double(nextTouch) * 0.1,
                               majorRadius: 10, majorRadiusTolerance: 2,
                               plane: "letters", shift: "off",
                               hitKind: "letter", key: String(hit), keyIndex: k))
        s.actions.append(.init(actionID: nextAction, t: Double(nextAction) * 0.1,
                               kind: "letter", touchID: nextTouch,
                               targetWordIndex: targetIndex, targetWord: nil,
                               suggestions: nil, commit: nil, textAfter: nil))
        nextTouch += 1; nextAction += 1
    }

    private func commit(_ literal: String, target: String?, into s: inout TypingSession,
                        kind: String = "space", touchCount: Int,
                        diverged: Bool = false, matches: Bool? = nil) {
        let c = TypingSession.Action.Commit(
            kind: "literal", literal: literal, displayBefore: literal,
            committed: literal, delta: nil, theta: nil, bestCost: nil, bestWord: nil,
            language: 0, touchCount: touchCount, casingApplied: false,
            literalProtected: true, labelSource: "protocol", confidence: "strong",
            targetWord: target, matchesTarget: matches ?? (literal == target))
        s.actions.append(.init(actionID: nextAction, t: Double(nextAction) * 0.1,
                               kind: kind, touchID: nil,
                               targetWordIndex: nil, targetWord: target,
                               suggestions: nil, commit: c, textAfter: nil,
                               alignmentDiverged: diverged))
        nextAction += 1
    }

    private func backspace(_ s: inout TypingSession, word: Bool = false) {
        s.actions.append(.init(actionID: nextAction, t: Double(nextAction) * 0.1,
                               kind: word ? "backspaceWord" : "backspace", touchID: nil,
                               targetWordIndex: nil, targetWord: nil,
                               suggestions: nil, commit: nil, textAfter: nil))
        nextAction += 1
    }

    override func setUp() { super.setUp(); nextTouch = 0; nextAction = 0 }

    // MARK: - Şema

    /// Yazıcı ve okuyucu **aynı** tipi kullanıyor; round-trip bunu kanıtlar.
    func testCodableRoundTripPreservesEverything() throws {
        var s = session(prompt: "kalem")
        typeLetter("k", into: &s, targetIndex: 0)
        commit("k", target: "kalem", into: &s, touchCount: 1)
        s.status = .completed

        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(TypingSession.self, from: try e.encode(s))

        XCTAssertEqual(back.attemptID, s.attemptID)
        XCTAssertEqual(back.status, .completed)
        XCTAssertEqual(back.touches.count, 1)
        XCTAssertEqual(back.actions.count, 2)
        XCTAssertEqual(back.engine.codeRevision, "test")
        XCTAssertEqual(back.alignmentSource, .constructed)
    }

    // MARK: - Token türetimi

    func testTokensAreDerivedFromTheActionLog() {
        var s = session(prompt: "kalem ev")
        for ch in "kalem" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("kalem", target: "kalem", into: &s, touchCount: 5)
        for ch in "ev" { typeLetter(ch, into: &s, targetIndex: 1) }
        commit("ev", target: "ev", into: &s, touchCount: 2)

        let t = SessionReplay.tokens(of: s)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].touches.count, 5)
        XCTAssertEqual(t[1].touches.count, 2)
        XCTAssertTrue(t.allSatisfy(\.touchCountAgrees))
    }

    /// Karakter silme **bir** dokunma düşürür.
    func testCharacterBackspaceDropsOneTouch() {
        var s = session(prompt: "kale")
        for ch in "kalem" { typeLetter(ch, into: &s, targetIndex: 0) }
        backspace(&s)
        commit("kale", target: "kale", into: &s, touchCount: 4)

        let t = SessionReplay.tokens(of: s)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].touches.count, 4)
        XCTAssertTrue(t[0].touchCountAgrees)
    }

    /// Kelime silme **tüm** bekleyen dokunmaları düşürür.
    ///
    /// İlk uygulama iki kademeyi aynı `kind` ile yazıyor ve importer tek
    /// dokunma düşürüyordu; kalan dokunmalar bir sonraki token'a taşınıyor ve
    /// o token'ın hizalaması sessizce bozuluyordu.
    func testWordBackspaceDropsEveryPendingTouch() {
        var s = session(prompt: "ev")
        for ch in "kalem" { typeLetter(ch, into: &s, targetIndex: 0) }
        backspace(&s, word: true)
        for ch in "ev" { typeLetter(ch, into: &s, targetIndex: 1) }
        commit("ev", target: "ev", into: &s, touchCount: 2)

        let t = SessionReplay.tokens(of: s)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].touches.count, 2, "silinen kelimenin dokunmaları taşınmamalı")
        XCTAssertTrue(t[0].touchCountAgrees)
    }

    /// Kayıttaki `touchCount` ile türetilen sayı uyuşmazsa **işaretlenmeli**,
    /// sessizce kabul edilmemeli.
    func testTouchCountDisagreementIsFlagged() {
        var s = session(prompt: "kalem")
        for ch in "kal" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("kalem", target: "kalem", into: &s, touchCount: 5)   // yalan
        let t = SessionReplay.tokens(of: s)
        XCTAssertEqual(t.count, 1)
        XCTAssertFalse(t[0].touchCountAgrees)
    }

    // MARK: - Kalibrasyon örnekleri (§12.5)

    /// **Asıl kazanç:** parmak komşu tuşa taşsa bile dokunma HEDEF tuşa yazılır.
    ///
    /// İlk uygulama tuş indeksini isabet edilen tuştan alıyor ve uyuşmayan
    /// token'ı atıyordu — yani §8.3'ün kaydettiği yanlılık aynen duruyordu.
    /// Hedefli kaydın üretim verisine tek üstünlüğü niyetin bilinmesi; bu test
    /// o üstünlüğün kullanıldığını koruyor.
    func testDriftedTouchIsAssignedToTheTargetKeyNotTheHitKey() {
        var s = session(prompt: "kalem")
        let kIdx = layout.keyIndex(for: "k")!
        let lIdx = layout.keyIndex(for: "l")!
        // "k" hedefleniyor ama parmak "l" tuşuna düşmüş.
        typeLetter("k", into: &s, targetIndex: 0,
                   at: layout.keys[lIdx].center, hitKey: "l")
        for ch in "alem" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("lalem", target: "kalem", into: &s, touchCount: 5, matches: false)

        let ext = SessionReplay.calibrationExtract(s, layout: layout)
        XCTAssertEqual(ext.samples.count, 5, "token atılmamalı")
        XCTAssertEqual(ext.samples[0].keyIndex, kIdx,
                       "kayan dokunma HEDEF tuşa yazılmalı, isabet edilene değil")
        XCTAssertEqual(ext.recoveredDriftedTouches, 1)
        XCTAssertNotEqual(kIdx, lIdx)
    }

    /// Uzunluk eşit değilse pozisyonel eşleme **çıkarım** olur — §6.2 yasak.
    func testLengthMismatchIsExcludedAndCounted() {
        var s = session(prompt: "kalem")
        for ch in "kal" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("kal", target: "kalem", into: &s, touchCount: 3, matches: false)

        let ext = SessionReplay.calibrationExtract(s, layout: layout)
        XCTAssertTrue(ext.samples.isEmpty)
        XCTAssertEqual(ext.excludedLengthMismatch, 1)
    }

    /// Hizalaması delinmiş token kalibrasyona girmemeli.
    func testDivergedTokenIsExcludedAndCounted() {
        var s = session(prompt: "kalem")
        for ch in "kalem" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("kalem", target: "kalem", into: &s, touchCount: 5, diverged: true)

        let ext = SessionReplay.calibrationExtract(s, layout: layout)
        XCTAssertTrue(ext.samples.isEmpty)
        XCTAssertEqual(ext.excludedDiverged, 1)
    }

    /// `sequential` hizalama kalibrasyona **hiç** girmez: sırayla varsayıyor,
    /// kaydetmiyor.
    func testSequentialAlignmentYieldsNoCalibrationSamples() {
        var s = session(prompt: "kalem", condition: .behavior, alignment: .sequential)
        for ch in "kalem" { typeLetter(ch, into: &s, targetIndex: 0) }
        commit("kalem", target: "kalem", into: &s, touchCount: 5)
        XCTAssertTrue(SessionReplay.calibrationExtract(s, layout: layout).samples.isEmpty)
    }

    // MARK: - Özet

    func testSummaryCountsAbortsAndDroppedTouches() {
        var a = session(prompt: "kalem"); a.status = .completed
        for ch in "kalem" { typeLetter(ch, into: &a, targetIndex: 0) }
        commit("kalem", target: "kalem", into: &a, touchCount: 5)
        // İsabet etmeyen ve sürüklenip düşen birer dokunma.
        a.touches.append(.init(touchID: 90, phase: "ended", outcome: "neverHit",
                               rawX: 0, rawY: 0, normX: nil, normY: nil,
                               decoderX: nil, decoderY: nil, timestamp: 9,
                               majorRadius: 10, majorRadiusTolerance: 2,
                               plane: "letters", shift: "off",
                               hitKind: nil, key: nil, keyIndex: nil))
        a.touches.append(.init(touchID: 91, phase: "ended", outcome: "leftBounds",
                               rawX: 0, rawY: 0, normX: nil, normY: nil,
                               decoderX: nil, decoderY: nil, timestamp: 9.1,
                               majorRadius: 10, majorRadiusTolerance: 2,
                               plane: "letters", shift: "off",
                               hitKind: nil, key: nil, keyIndex: nil))

        var b = session(prompt: "ev"); b.status = .aborted

        let sum = SessionReplay.summarize([a, b], layout: layout)
        XCTAssertEqual(sum.total, 2)
        XCTAssertEqual(sum.completed, 1)
        XCTAssertEqual(sum.aborted, 1)
        XCTAssertEqual(sum.touchesNeverHit, 1)
        XCTAssertEqual(sum.touchesLeftBounds, 1)
    }
}
