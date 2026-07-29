import Foundation
import Testing
@testable import KBRuntime
@testable import KBSessions

/// Katlama ve doğrulama değişmezleri — plan v8 §2.4, §2.5.
///
/// Buradaki testlerin ortak sorusu: **kayıtta yazılı olan ile türetilen aynı
/// şeyi mi söylüyor?** Reducer hiçbir şey çıkarmıyor; yalnız `DestructiveEffect`
/// olgularını katlıyor. Bir kural yanlışsa fark burada görünür, üretimde değil.
@Suite("Katlama değişmezleri")
struct SessionReducerTests {

    // MARK: - Kurucu

    /// v3 kaydı üretir. Canlı tarafın yerine geçmiyor — **olguları** elle
    /// koyuyor ki katlama kuralları tek başına sınanabilsin.
    private final class Builder {
        var touches: [CanonicalSession.Touch] = []
        var actions: [CanonicalSession.Action] = []
        private var nextTouch = 0
        private var nextAction = 0
        private var nextToken = 0

        @discardableResult
        func letter(_ ch: Character, outcome: CanonicalSession.Touch.Outcome = .committed)
            -> Int {
            let id = nextTouch
            nextTouch += 1
            touches.append(.init(
                touchID: id, phase: .ended, outcome: outcome,
                rawX: 10, rawY: 20, normX: 0.1, normY: 0.2,
                decoderX: 0.1, decoderY: 0.2, timestamp: Double(id),
                majorRadius: 5, majorRadiusTolerance: 1,
                plane: "letters", shift: "off",
                hitKind: "letter", key: String(ch), keyIndex: id))
            append(.letter, touchID: id,
                   event: .known(.letter(baseKey: String(ch),
                                         display: String(ch), shifted: false)),
                   effect: .notApplicable)
            return id
        }

        /// Sınır: token kapanır.
        @discardableResult
        func boundary(_ kind: CanonicalSession.Action.Kind = .space,
                      literal: String, committed: String, touchCount: Int,
                      cursorBefore: Int,
                      tokenID: Epistemic<TokenID>? = nil) -> TokenID {
            let id = TokenID(raw: nextToken)
            nextToken += 1
            append(kind, touchID: nil,
                   event: .known(kind == .newline ? .newline : .space),
                   effect: .known(.boundary),
                   commit: .init(kind: .literal, tokenID: tokenID ?? .known(id),
                                 literal: literal, displayBefore: literal,
                                 committed: committed, delta: nil, theta: nil,
                                 bestCost: nil, bestWord: nil, language: 0,
                                 touchCount: touchCount, casingApplied: false,
                                 literalProtected: false,
                                 label: .init(source: .protocol,
                                              confidence: .strong,
                                              targetWord: committed,
                                              matchesTarget: true),
                                 cursorBefore: .known(cursorBefore)))
            return id
        }

        /// Boş sınır — art arda boşluk.
        func emptyBoundary() {
            append(.space, touchID: nil, event: .known(.space),
                   effect: .known(.boundary),
                   commit: .init(kind: .empty, tokenID: .notApplicable,
                                 literal: "", displayBefore: "", committed: "",
                                 delta: nil, theta: nil, bestCost: nil,
                                 bestWord: nil, language: nil, touchCount: 0,
                                 casingApplied: false, literalProtected: false,
                                 label: .init(source: .protocol,
                                              confidence: .weak,
                                              targetWord: nil,
                                              matchesTarget: nil),
                                 cursorBefore: .known(0)))
        }

        func destructive(_ effect: Epistemic<DestructiveEffect>,
                         kind: CanonicalSession.Action.Kind = .backspaceTap) {
            let event: Epistemic<ReplayCommand>
            switch kind {
            case .backspaceTap:    event = .known(.backspaceTap)
            case .backspaceRepeat: event = .known(.backspaceRepeat)
            case .deleteWord:      event = .known(.deleteWord)
            default:               event = .unknown
            }
            append(kind, touchID: nil, event: event, effect: effect)
        }

        private func append(_ kind: CanonicalSession.Action.Kind, touchID: Int?,
                            event: Epistemic<ReplayCommand>,
                            effect: Epistemic<DestructiveEffect>,
                            commit: CanonicalSession.Action.Commit? = nil) {
            actions.append(.init(
                actionID: nextAction, t: Double(nextAction) * 0.1, kind: kind,
                touchID: touchID, event: event, effect: effect,
                document: .known(.init(mutations: [], hashAfter: 0)),
                targetTokenIndex: nil, targetToken: nil,
                candidates: .notApplicable, shown: .notApplicable,
                commit: commit))
            nextAction += 1
        }

        func session(status: CanonicalSession.Status = .completed)
            -> CanonicalSession {
            CanonicalSession(
                attemptID: "t", participantID: "p", sessionOrdinal: 0,
                condition: .calibrationReplay, status: status,
                promptID: "p", promptText: "", promptSource: .builtin,
                split: "train", promptTokens: .known([]),
                alignmentSource: .constructed,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: status == .recording
                    ? nil : Date(timeIntervalSince1970: 1),
                engine: .unconfigured(),
                geometry: Self.geometry,
                touches: touches, actions: actions, finalText: "")
        }

        static let geometry = CanonicalSession.Geometry(
            layoutID: "tr-q", layoutFingerprint: .known("f"),
            boundsX: 0, boundsY: 0, boundsWidth: 393, boundsHeight: 216,
            frameInScreenX: 0, frameInScreenY: 600,
            frameInScreenWidth: 393, frameInScreenHeight: 216,
            safeAreaBottom: 34, screenScale: 3, interfaceOrientation: "portrait",
            deviceModel: "test", systemVersion: "18")
    }

    private func reduce(_ b: Builder) -> SessionEventReducer.State {
        SessionEventReducer.reduce(b.session())
    }

    // MARK: - Kanıt durum makinesi

    /// **Yeni token'ın ilk harfi.** "Yalnız `.attached` iken topla" kuralı onu
    /// düşürüyordu: token kapandığında kanıt `.cleared` oluyor ve sonraki harf
    /// oradan geliyor.
    @Test("Sınırdan sonraki ilk harf toplanıyor")
    func firstLetterAfterBoundaryIsCollected() {
        let b = Builder()
        for ch in "bir" { b.letter(ch) }
        b.boundary(literal: "bir", committed: "bir", touchCount: 3, cursorBefore: 0)
        for ch in "iki" { b.letter(ch) }
        b.boundary(literal: "iki", committed: "iki", touchCount: 3, cursorBefore: 1)

        let s = reduce(b)
        #expect(s.tokens.count == 2)
        #expect(s.tokens.allSatisfy { $0.touchCountAgrees })
        #expect(s.dropped.isEmpty)
    }

    /// Kanıt kopmuşken hangi dokunmanın hangi karakteri ürettiği bilinmiyor.
    /// Yüzey belgede duruyor ama kalibrasyona giremez.
    @Test("Kopuk kanıt sırasında gelen harf düşürülüyor")
    func lettersWhileDetachedAreDropped() {
        let b = Builder()
        b.letter("a")
        b.destructive(.known(.init(pending: .dropAll, deleted: [],
                                   evidenceStateAfter: .detached)))
        b.letter("b")
        b.letter("c")

        let s = reduce(b)
        #expect(s.pending.isEmpty)
        #expect(s.dropped.filter { $0.reason == .evidenceDetached }.count == 2)
    }

    /// **Kopma anında** bekleyenlerin tamamı gerekçeli düşmeli. Onları token'da
    /// bırakmak `commit.touchCount == atoms.count` eşitliğini meşru bir yolda
    /// bozuyordu.
    @Test("Kopma anındaki bekleyenler gerekçeli düşüyor")
    func pendingDroppedOnDetach() {
        let b = Builder()
        for ch in "abc" { b.letter(ch) }
        b.destructive(.known(.init(pending: .dropAll, deleted: [],
                                   evidenceStateAfter: .detached)))

        let s = reduce(b)
        #expect(s.pending.isEmpty)
        #expect(s.dropped.count == 3)
        #expect(s.dropped.allSatisfy { $0.reason == .droppedOnDetach })
    }

    /// `isDetached` üç ayrı yerde temizleniyor. Yalnız "koptu" olayını
    /// kaydetseydik reducer kopukluktan **çıkışı** hiç görmez ve sonraki bütün
    /// harfleri düşürürdü.
    @Test("Kopukluktan çıkış görülüyor")
    func evidenceReattaches() {
        let b = Builder()
        b.destructive(.known(.init(pending: .dropAll, deleted: [],
                                   evidenceStateAfter: .detached)))
        b.letter("a")                                    // düşer
        b.destructive(.known(.init(pending: .dropAll, deleted: [],
                                   evidenceStateAfter: .cleared)))
        b.letter("b")                                    // toplanır

        let s = reduce(b)
        #expect(s.dropped.count == 1)
        #expect(s.pending.count == 1)
    }

    @Test("Hiçbir tuşa denk gelmeyen dokunma token'a girmiyor")
    func neverHitTouchIsDropped() {
        let b = Builder()
        b.letter("a")
        b.letter("b", outcome: .neverHit)

        let s = reduce(b)
        #expect(s.pending.count == 1)
        #expect(s.dropped.map(\.reason) == [.neverHit])
    }

    // MARK: - Sınır

    @Test("Boş commit'te açıkta kalan dokunma ihlal")
    func pendingAtEmptyCommitIsViolation() {
        let b = Builder()
        b.letter("a")
        b.emptyBoundary()

        let s = reduce(b)
        #expect(s.violations.map(\.kind) == [.pendingAtEmptyCommit])
        #expect(s.pending.isEmpty)
    }

    @Test("Boş commit tek başına ihlal değil")
    func emptyCommitAloneIsFine() {
        let b = Builder()
        b.emptyBoundary()
        #expect(reduce(b).violations.isEmpty)
    }

    /// Sapma bunu **meşrulaştırmıyor**: hizalama bozulsa bile token'ın kendi
    /// dokunma sayısı tutmak zorunda.
    @Test("Dokunma sayısı uyuşmazlığı sapmaya rağmen ihlal")
    func touchCountMismatchIsViolationEvenWhenDiverged() {
        let b = Builder()
        b.destructive(.known(.init(pending: .none, deleted: [.unattributed],
                                   evidenceStateAfter: .cleared)))
        for ch in "ab" { b.letter(ch) }
        b.boundary(literal: "ab", committed: "ab", touchCount: 5, cursorBefore: 0)

        let s = reduce(b)
        #expect(s.diverged)
        #expect(s.violations.contains { $0.kind == .touchCountMismatch })
    }

    // MARK: - Geri açma

    /// Geri açma hizalamayı tam olarak eski hâline döndürüyor: aynı dokunmalar,
    /// aynı cursor. Sapma varsa geri açmadan değil, ondan **önce** olandan.
    @Test("Geri açma token'ı yeniden açıyor ve sapma ÜRETMİYOR")
    func restoreReopensWithoutDivergence() {
        let b = Builder()
        for ch in "bir" { b.letter(ch) }
        let id = b.boundary(literal: "bir", committed: "bir",
                            touchCount: 3, cursorBefore: 0)
        b.destructive(.known(.init(pending: .restoreToken, deleted: [.separator],
                                   evidenceStateAfter: .attached,
                                   restoredToken: id)))

        let s = reduce(b)
        #expect(s.tokens.isEmpty, "token yeniden açık")
        #expect(s.pending.count == 3, "dokunmaları geri döndü")
        #expect(s.cursor == 0, "cursor commit öncesine döndü")
        #expect(!s.diverged, "geri açma hizayı BOZMUYOR")
    }

    @Test("Bilinmeyen kimliğin geri açılması ihlal")
    func restoreOfUnknownTokenIsViolation() {
        let b = Builder()
        b.destructive(.known(.init(pending: .restoreToken, deleted: [.separator],
                                   evidenceStateAfter: .attached,
                                   restoredToken: TokenID(raw: 99))))
        #expect(reduce(b).violations.map(\.kind) == [.restoreOfUnknownToken])
    }

    @Test("Geçersiz kılınmış token ikinci kez geri açılamaz")
    func restoreOfInvalidatedTokenIsViolation() {
        let b = Builder()
        for ch in "ab" { b.letter(ch) }
        let id = b.boundary(literal: "ab", committed: "ab",
                            touchCount: 2, cursorBefore: 0)
        b.destructive(
                      .known(.init(pending: .none, deleted: [.removedToken(id)],
                                   evidenceStateAfter: .cleared)))
        b.destructive(.known(.init(pending: .restoreToken, deleted: [.separator],
                                   evidenceStateAfter: .attached,
                                   restoredToken: id)))

        let s = reduce(b)
        #expect(s.violations.contains { $0.kind == .restoreOfInvalidatedToken })
    }

    // MARK: - Silme atfı

    /// Token'ın **bir kısmı** silindi; kalanı belgede duruyor. Cursor geri
    /// alınmaz — yeniden yazılan harfler aynı hedefe gidiyor.
    @Test("editedToken cursor'ı geri almıyor")
    func editedTokenKeepsCursor() {
        let b = Builder()
        for ch in "ab" { b.letter(ch) }
        let id = b.boundary(literal: "ab", committed: "ab",
                            touchCount: 2, cursorBefore: 0)
        b.destructive(.known(.init(pending: .none,
                                   deleted: [.editedToken(id)],
                                   evidenceStateAfter: .cleared)))

        let s = reduce(b)
        #expect(s.cursor == 1, "cursor ilerlemiş hâlinde kalmalı")
        #expect(s.tokens[0].invalidated)
        // §2.1: kısmî silme sapma **başlatır** — commit edilen metin artık
        // belgedekinden farklı ve o token'ın hedefe eşlemesi kanıtlanamaz.
        // `removedToken`'dan farkı cursor'da: orada tam silme kanıtlandığı
        // için `cursorBefore`'a dönülüp hiza korunabiliyor.
        #expect(s.diverged)
    }

    /// §2.1 tablosu: hiza bozulup kanıt koptuğunda sapma **başlar**. Zaten
    /// kopukken gelen silmeler başlatmaz (`pending: .none`, önceki korunur).
    @Test("İlk kopuş sapma başlatıyor, ikincisi başlatmıyor")
    func firstDetachSetsDivergence() {
        let first = Builder()
        first.letter("a")
        first.destructive(.known(.init(pending: .dropAll, deleted: [],
                                       evidenceStateAfter: .detached)))
        #expect(reduce(first).diverged)

        let second = Builder()
        second.destructive(.known(.init(pending: .none, deleted: [],
                                        evidenceStateAfter: .detached)))
        #expect(!reduce(second).diverged, "zaten kopuk: önceki durum korunur")
    }

    /// `wi-fi ` gibi tek çağrıda iki token silen durumlar. Öğe başına geri alım
    /// cursor'ı iki kez geriye taşırdı.
    @Test("Tek eylemde iki token silinince cursor bir kez geri alınıyor")
    func cursorRollsBackOncePerAction() {
        let b = Builder()
        b.letter("w")
        let first = b.boundary(literal: "wi", committed: "wi",
                               touchCount: 1, cursorBefore: 0)
        b.letter("f")
        let second = b.boundary(literal: "fi", committed: "fi",
                                touchCount: 1, cursorBefore: 1)
        b.destructive(
                      .known(.init(pending: .none,
                                   deleted: [.removedToken(first),
                                             .removedToken(second),
                                             .separator],
                                   evidenceStateAfter: .cleared)))

        let s = reduce(b)
        #expect(s.cursor == 0, "en eski silinen token'ın cursorBefore'u")
        #expect(s.tokens.allSatisfy { $0.invalidated })
    }

    /// Ayırıcı silmek hizayı bozmuyor: cursor ilerlemiyor ve belge yüzeyi zaten
    /// mutasyonlardan yeniden kuruluyor. Eski koşulsuz kural burada her ayırıcı
    /// silmede yanlış pozitif üretiyordu.
    @Test("Ayırıcı silmek sapma üretmiyor")
    func separatorDeletionDoesNotDiverge() {
        let b = Builder()
        b.destructive(.known(.init(pending: .none, deleted: [.separator],
                                   evidenceStateAfter: .cleared)))
        #expect(!reduce(b).diverged)
    }

    @Test("Atfedilemez silme sapma üretiyor")
    func unattributedDeletionDiverges() {
        let b = Builder()
        b.destructive(.known(.init(pending: .none, deleted: [.unattributed],
                                   evidenceStateAfter: .cleared)))
        #expect(reduce(b).diverged)
    }

    @Test("Boş belgede silme sapma üretmiyor")
    func emptyDeletionDoesNotDiverge() {
        let b = Builder()
        b.destructive(.known(.init(pending: .none, deleted: [],
                                   evidenceStateAfter: .cleared)))
        #expect(!reduce(b).diverged)
    }

    /// Composing token'ının tamamen silinmesi commit edilmiş bir token'a
    /// dokunmuyor; hiza bozulmuyor.
    @Test("Açık token'ın silinmesi sapma üretmiyor")
    func composingDropAllDoesNotDiverge() {
        let b = Builder()
        for ch in "ab" { b.letter(ch) }
        b.destructive(
                      .known(.init(pending: .dropAll, deleted: [],
                                   evidenceStateAfter: .cleared)))
        let s = reduce(b)
        #expect(!s.diverged)
        #expect(s.dropped.map(\.reason) == [.deletedBeforeCommit,
                                            .deletedBeforeCommit])
    }

    @Test("Sapmadan sonraki token'lar işaretleniyor")
    func tokensAfterDivergenceAreMarked() {
        let b = Builder()
        b.letter("a")
        b.boundary(literal: "a", committed: "a", touchCount: 1, cursorBefore: 0)
        b.destructive(.known(.init(pending: .none, deleted: [.unattributed],
                                   evidenceStateAfter: .cleared)))
        b.letter("b")
        b.boundary(literal: "b", committed: "b", touchCount: 1, cursorBefore: 1)

        let s = reduce(b)
        #expect(s.tokens[0].afterDivergence == false)
        #expect(s.tokens[1].afterDivergence == true)
    }

    @Test("Bilinmeyen kimlikle silme ihlal ve sapma")
    func deleteOfUnknownTokenDiverges() {
        let b = Builder()
        b.destructive(
                      .known(.init(pending: .none,
                                   deleted: [.removedToken(TokenID(raw: 42))],
                                   evidenceStateAfter: .cleared)))
        let s = reduce(b)
        #expect(s.violations.map(\.kind) == [.deleteOfUnknownToken])
        #expect(s.diverged, "cursor geri alınamadı")
    }

    // MARK: - Bilinmeyen olgu

    /// v2'de yıkıcı olgu hiç kaydedilmemişti. Ne silindiğini tahmin etmek
    /// yerine bu noktadan sonrasını hizalama dışı sayıyoruz.
    @Test("Bilinmeyen yıkıcı olgu tahmin edilmiyor")
    func unknownEffectIsNotGuessed() {
        let b = Builder()
        b.letter("a")
        b.destructive(.unknown, kind: .backspaceUnspecified)

        let s = reduce(b)
        #expect(s.unverifiable == [1])
        #expect(s.diverged)
        #expect(s.violations.map(\.kind) == [.unknownFact])
    }

    @Test("Bilinmeyen tokenID hedefli etkiyi engelliyor")
    func unknownTokenIDIsUnverifiable() {
        let b = Builder()
        b.letter("a")
        b.boundary(literal: "a", committed: "a", touchCount: 1,
                   cursorBefore: 0, tokenID: .unknown)

        let s = reduce(b)
        #expect(s.unverifiable == [1])
        #expect(s.tokens.isEmpty, "kimliksiz token hedefli etkiye konu olamaz")
        #expect(s.cursor == 1, "ama cursor yine de ilerledi")
    }

    /// Migrate edilmiş v2 kaydı çökmeden katlanmalı ve doğrulanamaz olduğunu
    /// **söylemeli** — sessizce geçmemeli.
    @Test("Migrate edilmiş v2 kaydı doğrulanamaz olduğunu bildiriyor")
    func migratedV2IsReportedUnverifiable() throws {
        var v2 = TypingSession(
            attemptID: "a", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, promptID: "p", promptText: "ev",
            promptSource: .builtin, split: "train", alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0), posture: .init(),
            engine: .init(buildConfiguration: "Release", appVersion: "1",
                          packs: [.init(name: "tr", sha256: "a", bytes: 1)],
                          beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
                          autoCorrectsOutOfVocabulary: true,
                          calibration: .init(applied: false, strongSamples: 0,
                                             globalX: 0, globalY: 0, rowX: [],
                                             rowY: [], keyX: [], keyY: [],
                                             biasX: [], biasY: []),
                          learningFrozen: true, codeRevision: "abc",
                          initialLanguage: nil),
            geometry: .init(layoutID: "tr-q", boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
        v2.actions = [
            .init(actionID: 0, t: 0, kind: "space", touchID: nil,
                  targetWordIndex: 0, targetWord: "ev", suggestions: nil,
                  commit: .init(kind: "literal", literal: "ev",
                                displayBefore: "ev", committed: "ev",
                                delta: nil, theta: nil, bestCost: nil,
                                bestWord: nil, language: 0, touchCount: 0,
                                casingApplied: false, literalProtected: false,
                                labelSource: "protocol", confidence: "strong",
                                targetWord: "ev", matchesTarget: true),
                  textAfter: "ev "),
        ]
        let canonical = try SessionReader.read(
            try SessionCodec.encoder.encode(v2)).get()
        let s = SessionEventReducer.reduce(canonical)
        #expect(s.unverifiable == [0], "v2'de tokenID yok")
        #expect(s.violations.map(\.kind) == [.unknownFact])
    }
}

/// Yapısal doğrulama — plan v8 §2.5.
@Suite("Kayıt doğrulaması")
struct SessionValidatorTests {

    /// - Parameter sourceSchema: varsayılan **2**. Yerel v3 sayılan bir kayıt
    ///   hiçbir `.unknown` taşıyamaz; buradaki testler yapısal kuralları
    ///   sınıyor ve tam bir motor anlık görüntüsü kurmaları gerekmiyor.
    ///   Bütünlük kuralının kendi testi ayrı (`nativeRecordCannotCarryUnknown`).
    private func session(actions: [CanonicalSession.Action],
                         touches: [CanonicalSession.Touch] = [],
                         status: CanonicalSession.Status = .completed,
                         sourceSchema: Int = 2)
        -> CanonicalSession {
        CanonicalSession(
            sourceSchema: sourceSchema,
            attemptID: "t", participantID: "p", sessionOrdinal: 0,
            condition: .behavior, status: status,
            promptID: "p", promptText: "", promptSource: .builtin,
            split: "train", promptTokens: .known([]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: status == .recording ? nil : Date(timeIntervalSince1970: 1),
            engine: .unconfigured(),
            geometry: CanonicalSession.Geometry(
                layoutID: "tr-q", layoutFingerprint: .known("f"),
                boundsX: 0, boundsY: 0, boundsWidth: 393, boundsHeight: 216,
                frameInScreenX: 0, frameInScreenY: 600,
                frameInScreenWidth: 393, frameInScreenHeight: 216,
                safeAreaBottom: 34, screenScale: 3,
                interfaceOrientation: "portrait",
                deviceModel: "t", systemVersion: "18"),
            touches: touches, actions: actions, finalText: "")
    }

    private func action(_ id: Int, t: Double = 0,
                        kind: CanonicalSession.Action.Kind = .space,
                        touchID: Int? = nil,
                        event: Epistemic<ReplayCommand> = .known(.space),
                        effect: Epistemic<DestructiveEffect> = .known(.boundary))
        -> CanonicalSession.Action {
        .init(actionID: id, t: t, kind: kind, touchID: touchID,
              event: event, effect: effect,
              document: .known(.init(mutations: [], hashAfter: 0)),
              targetTokenIndex: nil, targetToken: nil,
              candidates: .notApplicable, shown: .notApplicable, commit: nil)
    }

    /// Boşluk, kaydın bir parçasının kaybolduğu anlamına geliyor ve katlama
    /// bunu fark etmeden çalışırdı: eksik bir `space` iki token'ı birleştirir.
    @Test("actionID kesintisiz olmalı")
    func actionIDMustBeContiguous() {
        let s = session(actions: [action(0), action(2)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .actionIDNotContiguous })
    }

    @Test("Zaman geri gidemez")
    func timeMustBeMonotonic() {
        let s = session(actions: [action(0, t: 1.0), action(1, t: 0.5)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .timeNotMonotonic })
    }

    /// `kind` ile `event` iki ayrı alan ve ayrışabilirler; replay o zaman
    /// kayıttan **farklı** bir şey sürerdi.
    @Test("Yük kip ile uyuşmalı")
    func payloadMustMatchKind() {
        let s = session(actions: [action(0, kind: .space,
                                         event: .known(.backspaceTap))])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .payloadKindMismatch })
    }

    /// `layout.keyIndex(for:)` tek karakter istiyor; çok karakterli bir değer
    /// sessizce `nil`'e düşerdi.
    @Test("baseKey tek grapheme olmalı")
    func baseKeyMustBeSingleGrapheme() {
        let s = session(
            actions: [action(0, kind: .letter, touchID: 0,
                             event: .known(.letter(baseKey: "ab", display: "ab",
                                                   shifted: false)),
                             effect: .notApplicable)],
            touches: [committedTouch(0)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .payloadKindMismatch })
    }

    @Test("Yıkıcı olmayan kip yıkıcı etki taşıyamaz")
    func nonDestructiveKindCannotCarryEffect() {
        let s = session(actions: [
            action(0, kind: .shift, event: .known(.shift("locked")),
                   effect: .known(.boundary)),
        ])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .payloadKindMismatch })
    }

    /// Çözülmezse harfin uzamsal kanıtı yok demektir; sessizce geçmek kanıtsız
    /// bir örneği güçlü sayardı.
    @Test("Harf terminal committed dokunmaya çözülmeli")
    func letterMustResolveToCommittedTouch() {
        let s = session(
            actions: [action(0, kind: .letter, touchID: 0,
                             event: .known(.letter(baseKey: "a", display: "a",
                                                   shifted: false)),
                             effect: .notApplicable)],
            touches: [committedTouch(0, outcome: .cancelled)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .letterTouchUnresolved })
    }

    @Test("Aynı dokunma iki terminal kayıt taşıyamaz")
    func duplicateTerminalTouchIsRejected() {
        let s = session(actions: [],
                        touches: [began(0), committedTouch(0), committedTouch(0)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .duplicateTerminalTouch })
    }

    /// Faz ile akıbet ayrı alanlar ve ayrışabilirler: biri "parmak hâlâ
    /// ekranda" derken diğeri "harf kesinleşti" diyordu.
    @Test("began fazında committed olamaz")
    func committedOnlyOnTerminalPhase() {
        var t = committedTouch(0)
        t.phase = .began
        let s = session(actions: [], touches: [t])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .touchLifecycle })
    }

    /// Aynı uzamsal kanıtın iki karaktere sayılması, kalibrasyonun onu iki kez
    /// öğrenmesi demek.
    @Test("Bir dokunma iki harfe bağlanamaz")
    func touchCannotBeConsumedTwice() {
        let letter = action(0, kind: .letter, touchID: 0,
                            event: .known(.letter(baseKey: "a", display: "a",
                                                  shifted: false)),
                            effect: .notApplicable)
        var second = letter
        second.actionID = 1
        let s = session(actions: [letter, second],
                        touches: [began(0), committedTouch(0)])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .touchConsumedTwice })
    }

    /// §2.1 tablosunda `space × restoreToken` diye bir satır yok; sessizce
    /// katlanırsa anlamsız bir duruma yol açardı.
    @Test("Tabloda olmayan operasyon×etki reddediliyor")
    func effectMustBeInTable() {
        let s = session(actions: [
            action(0, kind: .space, event: .known(.space),
                   effect: .known(.init(pending: .restoreToken, deleted: [],
                                        evidenceStateAfter: .attached,
                                        restoredToken: TokenID(raw: 0)))),
        ])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .effectNotInTable })
    }

    /// Bitişik ayırıcılar tek öğeye indirgenmeli; golden karşılaştırması ancak
    /// kanonik biçimde anlamlı.
    @Test("Kanonik olmayan silme listesi reddediliyor")
    func nonCanonicalSpansAreRejected() {
        let s = session(actions: [
            action(0, kind: .backspaceTap, event: .known(.backspaceTap),
                   effect: .known(.init(pending: .none,
                                        deleted: [.separator, .separator],
                                        evidenceStateAfter: .cleared))),
        ])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .effectNotInTable })
    }

    /// Geri açılıp yeniden commit edilen token **yeni** kimlik alır; eskisini
    /// geri vermek iki ayrı yazım denemesini tek token sanmaya yol açardı.
    @Test("Token kimliği monoton ve tekil olmalı")
    func tokenIDsMustBeMonotonic() {
        let s = session(actions: [
            boundary(0, tokenID: 5), boundary(1, tokenID: 3),
        ])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .tokenIDNotMonotonic })
    }

    /// Hedefli etki yalnız **var olan** bir kimliğe atıf yapabilir.
    @Test("Hiç commit edilmemiş kimliğe atıf reddediliyor")
    func effectCannotReferenceUnknownToken() {
        let s = session(actions: [
            action(0, kind: .deleteWord, event: .known(.deleteWord),
                   effect: .known(.init(pending: .none,
                                        deleted: [.removedToken(TokenID(raw: 9))],
                                        evidenceStateAfter: .cleared))),
        ])
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .tokenIDNotMonotonic })
    }

    /// **v3 hiçbir `.unknown` üretmez.** Yerel bir kayıtta görünmesi yazıcının
    /// bir olguyu atladığı anlamına gelir ve o kayıt sessizce kalibrasyondan
    /// düşerdi.
    @Test("Yerel v3 kaydı bilinmeyen olgu taşıyamaz")
    func nativeRecordCannotCarryUnknown() {
        let s = session(actions: [],
                        sourceSchema: CanonicalSession.currentSchema)
        let findings = SessionValidator.validate(s)
        #expect(findings.contains { $0.kind == .unknownFactInNativeRecord })
        // Migrate edilmiş kayıtta aynı olgular **yasal**.
        #expect(!SessionValidator.validate(session(actions: []))
            .contains { $0.kind == .unknownFactInNativeRecord })
    }

    private func boundary(_ id: Int, tokenID: Int) -> CanonicalSession.Action {
        var a = action(id, t: Double(id), kind: .space, event: .known(.space),
                       effect: .known(.boundary))
        a.commit = .init(kind: .literal, tokenID: .known(TokenID(raw: tokenID)),
                         literal: "a", displayBefore: "a", committed: "a",
                         delta: nil, theta: nil, bestCost: nil, bestWord: nil,
                         language: 0, touchCount: 0, casingApplied: false,
                         literalProtected: false,
                         label: .init(source: .protocol, confidence: .weak,
                                      targetWord: nil, matchesTarget: nil),
                         cursorBefore: .known(0))
        return a
    }

    private func began(_ id: Int) -> CanonicalSession.Touch {
        var t = committedTouch(id)
        t.phase = .began
        t.outcome = .pending
        return t
    }

    /// JSON sonsuz taşıyamıyor; `θ = ∞` ayrı bir bayrakla yazılıyor. NaN
    /// görmek, o bayrağın atlandığı ya da hesabın bozulduğu anlamına gelir.
    @Test("Sayısal alanlar sonlu olmalı")
    func numbersMustBeFinite() {
        var a = action(0)
        a.commit = .init(kind: .literal, tokenID: .known(TokenID(raw: 0)),
                         literal: "a", displayBefore: "a", committed: "a",
                         delta: .infinity, theta: nil, bestCost: nil,
                         bestWord: nil, language: 0, touchCount: 0,
                         casingApplied: false, literalProtected: false,
                         label: .init(source: .protocol, confidence: .weak,
                                      targetWord: nil, matchesTarget: nil),
                         cursorBefore: .known(0))
        #expect(SessionValidator.validate(session(actions: [a]))
            .contains { $0.kind == .nonFiniteNumber })
    }

    @Test("Terminal durum endedAt ile tutarlı olmalı")
    func terminalStatusNeedsEndedAt() {
        var s = session(actions: [], status: .completed)
        s.endedAt = nil
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .terminalStateInconsistent })

        var r = session(actions: [], status: .recording)
        r.endedAt = Date(timeIntervalSince1970: 1)
        #expect(SessionValidator.validate(r)
            .contains { $0.kind == .terminalStateInconsistent })
    }

    /// `backspaceUnspecified` **yalnız** migrasyondan çıkabilir; yerel bir v3
    /// kaydında görünmesi yazıcının bozuk olduğu anlamına gelir.
    @Test("Yerel v3 kaydında legacy kip olamaz")
    func legacyOnlyKindIsRejectedInNativeRecord() {
        let s = session(actions: [action(0, kind: .backspaceUnspecified,
                                         event: .unknown, effect: .unknown)],
                        sourceSchema: CanonicalSession.currentSchema)
        #expect(SessionValidator.validate(s)
            .contains { $0.kind == .legacyOnlyKindInNativeRecord })

        let migrated = session(actions: [action(0, kind: .backspaceUnspecified,
                                                event: .unknown, effect: .unknown)])
        #expect(!SessionValidator.validate(migrated)
            .contains { $0.kind == .legacyOnlyKindInNativeRecord })
    }

    @Test("Temiz kayıt bulgu üretmiyor")
    func cleanRecordHasNoFindings() {
        let s = session(
            actions: [action(0, kind: .letter, touchID: 0,
                             event: .known(.letter(baseKey: "a", display: "a",
                                                   shifted: false)),
                             effect: .notApplicable)],
            touches: [began(0), committedTouch(0)])
        #expect(SessionValidator.validate(s).isEmpty, "\(SessionValidator.validate(s))")
    }

    private func committedTouch(_ id: Int,
                                outcome: CanonicalSession.Touch.Outcome = .committed)
        -> CanonicalSession.Touch {
        .init(touchID: id, phase: .ended, outcome: outcome,
              rawX: 1, rawY: 2, normX: 0.1, normY: 0.2,
              decoderX: 0.1, decoderY: 0.2, timestamp: 0,
              majorRadius: 5, majorRadiusTolerance: 1,
              plane: "letters", shift: "off",
              hitKind: "letter", key: "a", keyIndex: 0)
    }
}
