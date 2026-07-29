import Testing
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLearning
@testable import KBSessions

/// **Adım 0 — baseline karakterizasyonu.** Sözleşme §12, plan v6 §2.0.
///
/// Bu testler *doğru* davranışı değil, **bugünkü davranışı** kaydediyor. Amaçları
/// üç tane:
///
/// 1. Reducer refactor'ünden **önce** neyin nasıl davrandığını dondurmak. Fixture
///    diff'in "öncesi" sonradan üretilemez: `SessionReplay.tokens(of:)` refactor
///    sırasında silinecek.
/// 2. Bilinen hataları `withKnownIssue` ile **kırmızı ama başarısız değil** hâlde
///    tutmak. Düzeltme geldiğinde `withKnownIssue` kaldırılır ve o kaldırma işlemi
///    davranış değişikliğinin **kanıtı** olur.
/// 3. Kasıtlı davranış değişikliklerini (plan §4) kasıtsız regresyondan ayırmak.
///
/// **Kapsam sınırı:** A1 (newline commit yazmıyor) ve A3'ün `wordIndex−1` çifte
/// hizalaması `RecorderViewController`'da yaşıyor ve `Apps/` test hedefi taşımıyor.
/// Buradaki karakterizasyon elle kurgulanmış kayda dayanıyor, **VC'nin kendisini
/// test etmiyor**; gerçek kapanış `RecordingEngine` SwiftPM'e taşınınca (plan
/// adım 5) mümkün olacak.
@Suite("Kayıt zinciri — adım 0 baseline")
struct SessionBaselineTests {

    private let layout = TurkishQ.layout()

    // MARK: - Kurulum yardımcıları

    private func blankEngine() -> TypingSession.EngineSnapshot {
        .init(buildConfiguration: "Release", appVersion: "baseline", packs: [],
              beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
              autoCorrectsOutOfVocabulary: true,
              calibration: .init(applied: false, strongSamples: 0,
                                 globalX: 0, globalY: 0, rowX: [], rowY: [],
                                 keyX: [], keyY: [], biasX: [], biasY: []),
              learningFrozen: true, codeRevision: "baseline", initialLanguage: nil)
    }

    private func blankGeometry() -> TypingSession.Geometry {
        .init(layoutID: layout.id, boundsX: 0, boundsY: 0,
              boundsWidth: 393, boundsHeight: 216,
              frameInScreenX: 0, frameInScreenY: 600,
              frameInScreenWidth: 393, frameInScreenHeight: 216,
              safeAreaBottom: 34, screenScale: 3, interfaceOrientation: "portrait",
              deviceModel: "baseline", systemVersion: "0")
    }

    /// Kayıt kurucusu — canlı VC'yi taklit eder, ama **bugünkü** kurallarıyla.
    private final class Builder {
        let layout: KeyLayout
        var session: TypingSession
        var nextTouch = 0
        var nextAction = 0
        /// VC'nin `wordIndex`'i — bugünkü ilerletme kuralı.
        var wordIndex = 0
        var pendingCount = 0

        init(layout: KeyLayout, session: TypingSession) {
            self.layout = layout
            self.session = session
        }

        func letter(_ ch: Character) {
            guard let k = layout.keyIndex(for: ch) else { return }
            let c = layout.keys[k].center
            session.touches.append(.init(
                touchID: nextTouch, phase: "ended", outcome: "committed",
                rawX: c.x * 393, rawY: c.y * 216, normX: c.x, normY: c.y,
                decoderX: c.x, decoderY: c.y, timestamp: Double(nextTouch) * 0.1,
                majorRadius: 10, majorRadiusTolerance: 2,
                plane: "letters", shift: "off",
                hitKind: "letter", key: String(ch), keyIndex: k))
            session.actions.append(.init(
                actionID: nextAction, t: Double(nextAction) * 0.1, kind: "letter",
                touchID: nextTouch, targetWordIndex: wordIndex, targetWord: nil,
                suggestions: nil, commit: nil, textAfter: nil))
            nextTouch += 1; nextAction += 1; pendingCount += 1
        }

        /// Bugünkü `space` yolu: commit yazılır, `wordIndex` ilerler.
        func space(literal: String, target: String?, words: Int) {
            let c = TypingSession.Action.Commit(
                kind: "literal", literal: literal, displayBefore: literal,
                committed: literal, delta: nil, theta: nil, bestCost: nil,
                bestWord: nil, language: 0, touchCount: pendingCount,
                casingApplied: false, literalProtected: true,
                labelSource: "protocol", confidence: "strong",
                targetWord: target, matchesTarget: literal == target)
            session.actions.append(.init(
                actionID: nextAction, t: Double(nextAction) * 0.1, kind: "space",
                touchID: nil, targetWordIndex: wordIndex, targetWord: target,
                suggestions: nil, commit: c, textAfter: nil))
            nextAction += 1; pendingCount = 0
            if wordIndex < words { wordIndex += 1 }
        }

        /// **Bugünkü `.ret` yolu: commit kaydı YOK.** A1'in kaynağı.
        func newline() {
            session.actions.append(.init(
                actionID: nextAction, t: Double(nextAction) * 0.1, kind: "newline",
                touchID: nil, targetWordIndex: wordIndex, targetWord: nil,
                suggestions: nil, commit: nil, textAfter: nil))
            nextAction += 1
            // **Canlı taraf token'ı KAPATIYOR** (`session.finishToken` + `invalidate`),
            // dolayısıyla sonraki commit'in `touchCount`'u yalnız yeni token'ı
            // sayar. Ama kayda commit yazılmadığı için **importer bunu bilmiyor**
            // ve dokunmaları biriktirmeye devam ediyor. Ayrışma tam burada.
            pendingCount = 0
        }

        /// Bugünkü sınırda backspace: `wordIndex` geri alınır, ama **önceki space
        /// action'ı zaten `alignmentDiverged: false` ile yazılmıştı.** A3'ün kaynağı.
        func boundaryBackspace() {
            session.actions.append(.init(
                actionID: nextAction, t: Double(nextAction) * 0.1, kind: "backspace",
                touchID: nil, targetWordIndex: wordIndex, targetWord: nil,
                suggestions: nil, commit: nil, textAfter: nil))
            nextAction += 1
            if wordIndex > 0 { wordIndex -= 1 }
            session.hadBackspace = true
        }
    }

    private func builder(prompt: String) -> Builder {
        Builder(layout: layout, session: TypingSession(
            attemptID: "baseline", participantID: "b", sessionOrdinal: 0,
            condition: .calibrationReplay, promptID: "p", promptText: prompt,
            promptSource: .builtin, split: "train", alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0), posture: .init(),
            engine: blankEngine(), geometry: blankGeometry()))
    }

    // MARK: - A1: newline deliği

    /// **Bugünkü hata:** `.ret` token'ı kapatıyor ama commit kaydı yazmıyor;
    /// importer `newline`'ı tanımıyor (`default: break`) → bekleyen dokunmalar
    /// **bir sonraki token'a sızıyor**.
    ///
    /// Doğrusu: newline bir token sınırıdır, kendi token'ını üretmeli ve
    /// dokunmaları taşımamalı.
    @Test("A1 — newline dokunmaları sonraki token'a sızdırıyor")
    func newlineLeaksTouches() {
        let b = builder(prompt: "bir iki")
        for ch in "bir" { b.letter(ch) }
        b.newline()
        for ch in "iki" { b.letter(ch) }
        b.space(literal: "iki", target: "iki", words: 2)

        let tokens = SessionReplay.tokens(of: b.session)

        withKnownIssue("newline sınır değil; 'bir'in 3 dokunması 'iki'ye sızıyor") {
            #expect(tokens.count == 2, "newline kendi token'ını üretmeli")
        }
        // Bugünkü gerçek: tek token, altı dokunma.
        #expect(tokens.count == 1)
        #expect(tokens[0].touches.count == 6,
                "bugün 'bir'in 3 dokunması 'iki'nin 3'üne ekleniyor")
        #expect(tokens[0].touchCountAgrees == false,
                "kayıt 3 diyor, türetme 6 — tek yakalayan bayrak bu")
    }

    // MARK: - A3: geri açma çift gerçekliği

    /// **Bugünkü hata:** sınırda backspace `wordIndex`'i geri alıyor ama önceki
    /// space action'ı **zaten** `alignmentDiverged: false` ile yazılmıştı.
    /// Importer o commit'i temiz token sayıyor; sonuç: kullanıcının *"yanlış
    /// bastım"* diye geri aldığı dokunmalar kalibrasyona **güçlü örnek** giriyor.
    /// Üstelik aynı hedefe **iki token** hizalanıyor.
    @Test("A3 — geri çekilen deneme kalibrasyona güçlü örnek olarak giriyor")
    func retractedAttemptEntersCalibration() {
        let b = builder(prompt: "kalem ev")
        for ch in "kalem" { b.letter(ch) }
        b.space(literal: "kalem", target: "kalem", words: 2)
        b.boundaryBackspace()                    // token geri açıldı
        for ch in "kalem" { b.letter(ch) }       // yeniden yazıldı
        b.space(literal: "kalem", target: "kalem", words: 2)

        let ext = SessionReplay.calibrationExtract(b.session, layout: layout)

        withKnownIssue("geri çekilen deneme dışlanmalı; bugün her iki deneme de giriyor") {
            #expect(ext.samples.count == 5, "yalnız son deneme sayılmalı")
        }
        // Bugünkü gerçek: iki deneme de strong.
        #expect(ext.samples.count == 10)
        #expect(ext.excludedDiverged == 0,
                "sapma bayrağı yok — commit action'ı backspace'ten ÖNCE yazıldı")
    }

    // MARK: - A2: importer kendi içinde ayrışıyor

    /// `tokens()` `backspaceWord`'ü işliyor (tüm pending düşer) ama `verifyGolden`
    /// onu tanımıyor. Bu test **bugünkü asimetriyi** kaydediyor.
    @Test("A2 — backspaceWord tokens() ve verifyGolden arasında ayrışıyor")
    func backspaceWordDivergesBetweenConsumers() {
        let b = builder(prompt: "ev")
        for ch in "kalem" { b.letter(ch) }
        b.session.actions.append(.init(
            actionID: b.nextAction, t: 9, kind: "backspaceWord", touchID: nil,
            targetWordIndex: 0, targetWord: nil,
            suggestions: nil, commit: nil, textAfter: nil))
        b.nextAction += 1; b.pendingCount = 0
        for ch in "ev" { b.letter(ch) }
        b.space(literal: "ev", target: "ev", words: 1)

        let tokens = SessionReplay.tokens(of: b.session)
        // `tokens()` doğru davranıyor: silinen kelimenin dokunmaları taşınmıyor.
        #expect(tokens.count == 1)
        #expect(tokens[0].touches.count == 2)
        // `verifyGolden` ise `backspaceWord`'ü tanımıyor — bu asimetri kayıtlı.
    }

    // MARK: - A5: tokenizer iç ayırıcıyı sıyırmıyor

    /// `PromptCorpus.words` yalnız **uç** noktalamayı sıyırıyor; `Wi-Fi` gibi
    /// **iç ayırıcı** taşıyan hedefler tek token sayılıyor. Sembol token'ı
    /// kapatıp hedefi ilerlettiği için constructed hizalama **bugün burada
    /// deliniyor**.
    ///
    /// `PromptCorpus` `Apps/` altında olduğu için burada doğrudan çağrılamıyor;
    /// kural birebir kopyalanarak karakterize ediliyor (plan §2.3 onu
    /// `KBSessions`'a taşıyacak).
    @Test("A5 — iç ayırıcılı hedef tek token sayılıyor")
    func internalSeparatorsAreNotSplit() {
        func todaysWords(_ text: String) -> [String] {
            text.split(separator: " ")
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        withKnownIssue("Wi-Fi iki token olmalı: layout harflerinin maksimal dizileri") {
            #expect(todaysWords("Wi-Fi şifresi").count == 3)
        }
        #expect(todaysWords("Wi-Fi şifresi") == ["Wi-Fi", "şifresi"])
        #expect(todaysWords("Caddesi'ne") == ["Caddesi'ne"])
    }
}
