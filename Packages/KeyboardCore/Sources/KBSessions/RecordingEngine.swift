import Foundation
import KBGeometry
import KBRuntime
import KBSpatial

/// Kaydı **sahiplenen** motor — plan v8 §2.6.
///
/// ## Neden tek huni `log()` yetmiyordu
///
/// Mevcut akış önce `InputCoordinator`'ı ve belgeyi değiştiriyor, **sonra**
/// logluyordu. Aradaki pencerede gelen geç bir callback kaydı değiştirmese bile
/// **belgeyi** değiştirebiliyor ve kayıt ile belge ayrışıyordu.
///
/// Komut kapısı da yetmiyordu: geç bir `touch`, `engineConfigured` ya da
/// finalize callback'i terminalden **sonra** frame yazabiliyordu.
///
/// Çözüm tek serileştirilmiş giriş: faz **mutasyondan önce** kontrol edilir,
/// sonra runtime çağrısı → rapor/snapshot → katlama → günlük yazımı **tek
/// sıralı işlem** olarak koşar.
///
/// ## Neden koordinatörü sahipleniyor
///
/// `InputCoordinator`'a dışarıdan da erişilebilseydi, kayıt görmediği bir
/// mutasyon olabilirdi. Sahiplenmek bu ihtimali tiple kapatıyor.
public final class RecordingEngine {

    /// Deneme durum makinesi.
    ///
    /// Terminal durumlar **değişmez**. Kurtarma yalnız `recording →
    /// interrupted`: tamamlanmış bir denemeyi sonradan kesintiye çevirmek,
    /// geçmişe dönük olarak veriyi yeniden yorumlamak olurdu.
    public enum Phase: String, Equatable, Sendable {
        case initializing, recording, finishing
        case completed, aborted, invalid, interrupted

        public var isTerminal: Bool {
            switch self {
            case .initializing, .recording, .finishing: return false
            case .completed, .aborted, .invalid, .interrupted: return true
            }
        }
    }

    public enum IngressError: Error, Equatable, CustomStringConvertible {
        case wrongPhase(expected: [Phase], actual: Phase)
        /// Harf komutu, zaten tüketilmiş bir dokunmaya bağlanmaya çalıştı.
        case touchAlreadyConsumed(Int)
        /// Harf komutunun dokunması hiç kaydedilmemiş.
        case unknownTouch(Int)
        /// Harf komutu dokunma taşımıyor.
        case letterWithoutTouch
        case writeFailed(String)

        public var description: String {
            switch self {
            case let .wrongPhase(e, a):
                return "faz \(a); beklenen \(e.map(\.rawValue).joined(separator: "|"))"
            case let .touchAlreadyConsumed(id): return "dokunma \(id) zaten tüketildi"
            case let .unknownTouch(id):         return "dokunma \(id) kayıtta yok"
            case .letterWithoutTouch:           return "harf komutunun dokunması yok"
            case let .writeFailed(d):           return "yazılamadı: \(d)"
            }
        }
    }

    /// Harf komutu, **tüketilmemiş terminal `touchID`** taşıyan bir zarfla
    /// gelir.
    ///
    /// "Son dokunmaya" örtük bağlanmak kimlik korunumunu zayıflatıyordu: iki
    /// parmak üst üste bindiğinde ya da bir dokunma sınır dışına çıkıp
    /// düştüğünde harf yanlış dokunmaya bağlanıyordu ve kalibrasyon o yanlış
    /// koordinatı öğreniyordu.
    public struct CommandEnvelope {
        public var command: ReplayCommand
        /// Harf komutlarında **zorunlu**; diğerlerinde `nil`.
        public var touchID: Int?
        public var timestamp: TimeInterval

        public init(command: ReplayCommand, touchID: Int? = nil,
                    timestamp: TimeInterval) {
            self.command = command
            self.touchID = touchID
            self.timestamp = timestamp
        }
    }

    public enum TerminalReason: String, Sendable {
        case completed, aborted, invalid, interrupted
    }

    // MARK: - Durum

    public private(set) var phase: Phase = .initializing
    /// Katlanmış görünüm — `completed` koşulu buna bakıyor.
    public private(set) var state = SessionEventReducer.State()

    private let writer: SessionJournalWriter
    private let encoder = SessionCodec.encoder
    private var coordinator: InputCoordinator
    private let layout: KeyLayout

    private var touches: [Int: CanonicalSession.Touch] = [:]
    /// Bir harfe bağlanmış dokunmalar — ikinci kez bağlanamazlar.
    private var consumedTouches: Set<Int> = []
    private var actions: [CanonicalSession.Action] = []
    private var nextActionID = 0
    private var startTime: TimeInterval = 0
    /// Türetilen belge metni; `documentHash` bundan hesaplanıyor.
    private var document = ""
    private var promptTokenCount = 0

    public init(writer: SessionJournalWriter,
                coordinator: InputCoordinator,
                layout: KeyLayout) {
        self.writer = writer
        self.coordinator = coordinator
        self.layout = layout
    }

    // MARK: - Giriş

    /// Denemeyi başlatır ve **dayanıklı** olarak yazar.
    ///
    /// Klavye açılmadan **önce** çağrılmalı: `attemptStarted` kaybolursa
    /// vazgeçilen deneme abort oranının paydasından tamamen düşer (§12.6).
    public func begin(_ descriptor: CanonicalSession, at t: TimeInterval) throws {
        try require(.initializing)
        startTime = t
        promptTokenCount = descriptor.promptTokens.value?.count ?? 0
        try emit(.attemptStarted, descriptor)
        phase = .recording
    }

    /// Motor kurulduğunda çağrılır — paketler yüklenmeden bilinmiyor.
    public func configure(_ snapshot: CanonicalSession.EngineSnapshot) throws {
        try require(.recording)
        try emit(.engineConfigured, snapshot, durable: false)
    }

    /// Ham dokunma. **Komuttan önce** gelmek zorunda: harf zarfı onun
    /// kimliğine atıf yapıyor.
    public func record(_ touch: CanonicalSession.Touch) throws {
        try require(.recording)
        touches[touch.touchID] = touch
        try emit(.touch, touch, durable: false)
    }

    /// Kullanıcı eylemi — **tek** mutasyon noktası.
    @discardableResult
    public func perform(_ envelope: CommandEnvelope,
                        into editor: DocumentEditor) throws -> CanonicalSession.Action {
        // Faz **mutasyondan önce** kontrol ediliyor: sonra kontrol etmek,
        // reddedilen bir komutun belgeyi çoktan değiştirmiş olması demekti.
        try require(.recording)
        try validate(envelope)

        let before = document
        let action = try apply(envelope, into: editor)
        actions.append(action)
        SessionEventReducer.applyIncrementally(action, to: &state, touches: touches)
        do { try emit(.action, action, durable: false) }
        catch {
            // Yazma başarısızsa belge zaten değişti; kaydı sessizce tutarsız
            // bırakmak yerine denemeyi geçersiz sayıyoruz.
            document = before
            phase = .invalid
            throw IngressError.writeFailed("\(error)")
        }
        return action
    }

    /// Denemeyi kapatır. Terminal frame **dayanıklı** yazılır.
    @discardableResult
    public func finish(_ reason: TerminalReason, at t: TimeInterval,
                       finalText: String) throws -> Phase {
        try require(.recording, .finishing)
        phase = .finishing

        let resolved = resolve(reason)
        let terminal = Terminal(reason: resolved.rawValue, at: t - startTime,
                               finalText: finalText,
                               cursor: state.cursor,
                               promptTokenCount: promptTokenCount,
                               violations: state.violations.map(\.description),
                               unverifiable: state.unverifiable)
        try emit(.terminal, terminal)
        phase = resolved
        return resolved
    }

    /// Kurtarma: yarım kalmış bir kayıt **yalnız** `recording`'den kesintiye
    /// çevrilebilir.
    public func recover(at t: TimeInterval) throws {
        try require(.recording)
        try finish(.interrupted, at: t, finalText: document)
    }

    // MARK: - Tamamlanma koşulu

    /// `completed` şartı — **tam** eşitlik.
    ///
    /// `cursor > promptTokens.count` başarı **değil**: hedeften fazla token
    /// yazmak, hizalamanın kaydığı ya da kullanıcının fazladan kelime yazdığı
    /// anlamına geliyor ve o denemeyi tamamlanmış saymak, ölçülen şeyi
    /// bozardı.
    private func resolve(_ reason: TerminalReason) -> Phase {
        guard reason == .completed else {
            return Phase(rawValue: reason.rawValue) ?? .invalid
        }
        let ok = state.cursor == promptTokenCount
            && state.pending.isEmpty
            && state.violations.isEmpty
            && openTouches.isEmpty
        return ok ? .completed : .invalid
    }

    /// Henüz terminal fazına ulaşmamış dokunmalar.
    private var openTouches: [Int] {
        touches.values
            .filter { $0.phase != .ended && $0.phase != .cancelled }
            .map(\.touchID)
    }

    // MARK: - Uygulama

    private func apply(_ e: CommandEnvelope,
                       into editor: DocumentEditor) throws
        -> CanonicalSession.Action {
        let id = nextActionID
        nextActionID += 1
        let t = e.timestamp - startTime

        var kind: CanonicalSession.Action.Kind
        var effect: Epistemic<DestructiveEffect> = .notApplicable
        var commit: CanonicalSession.Action.Commit?
        var candidates: Epistemic<[CandidateSnapshot]> = .notApplicable
        var shown: Epistemic<[ShownSuggestion]> = .notApplicable

        switch e.command {
        case let .letter(baseKey, display, shifted):
            kind = .letter
            guard let touchID = e.touchID, let recorded = touches[touchID] else {
                throw IngressError.letterWithoutTouch
            }
            consumedTouches.insert(touchID)
            let sample = self.sample(from: recorded)
            if shifted {
                coordinator.insertUppercaseLetter(Character(baseKey),
                                                  uppercase: display,
                                                  touch: sample, into: editor)
            } else {
                coordinator.insertLetter(Character(baseKey), touch: sample,
                                         into: editor)
            }

        case let .symbol(s):
            kind = .symbol
            let report = coordinator.insertSymbol(Character(s), into: editor)
            commit = self.commit(from: report)
            effect = .known(.boundary)

        case .space:
            kind = .space
            // Aday görüntüsü **commit'ten önce** alınmalı: `space` beam'i
            // sıfırlıyor ve sonrasında liste boş çıkardı.
            (candidates, shown) = snapshotSuggestions()
            let report = coordinator.space(into: editor)
            commit = self.commit(from: report)
            effect = .known(.boundary)

        case .newline:
            kind = .newline
            (candidates, shown) = snapshotSuggestions()
            let report = coordinator.newline(into: editor)
            commit = self.commit(from: report)
            effect = .known(.boundary)

        case let .suggestionPick(_, surface, _):
            kind = .suggestionPick
            (candidates, shown) = snapshotSuggestions()
            let report = coordinator.pickSuggestion(surface, into: editor)
            commit = self.commit(from: report)
            effect = .known(.boundary)

        case .backspaceTap:
            kind = .backspaceTap
            effect = .known(coordinator.backspaceTap(into: editor))

        case .backspaceRepeat:
            kind = .backspaceRepeat
            effect = .known(coordinator.backspaceRepeat(into: editor))

        case .deleteWord:
            kind = .deleteWord
            effect = .known(coordinator.deleteWord(into: editor))

        case .planeChange:
            kind = .planeChange
        case .shift:
            kind = .shift
        }

        // Belge mutasyonu **çağrıdan sonra** okunuyor: kayıt, runtime'ın
        // fiilen ne yazdığını taşımalı, ne yazacağını tahmin etmemeli.
        let mutations = diff(from: document, to: editorText(editor))
        document = editorText(editor)

        return CanonicalSession.Action(
            actionID: id, t: t, kind: kind, touchID: e.touchID,
            event: .known(e.command), effect: effect,
            document: .known(.init(mutations: mutations,
                                   hashAfter: DocumentReconstruction.hash(document))),
            targetTokenIndex: state.cursor,
            targetToken: nil,
            candidates: candidates, shown: shown, commit: commit)
    }

    private func validate(_ e: CommandEnvelope) throws {
        guard case .letter = e.command else { return }
        guard let id = e.touchID else { throw IngressError.letterWithoutTouch }
        guard touches[id] != nil else { throw IngressError.unknownTouch(id) }
        guard !consumedTouches.contains(id) else {
            throw IngressError.touchAlreadyConsumed(id)
        }
    }

    private func snapshotSuggestions()
        -> (Epistemic<[CandidateSnapshot]>, Epistemic<[ShownSuggestion]>) {
        // **Tek çağrı**: `candidates()` ile `shownCandidates()` ayrı ayrı
        // çağrılırsa ikisi arasında beam değişebilir ve kayıt, hiç birlikte
        // var olmamış iki listeyi yan yana koyar.
        let all = coordinator.candidates(topK: 8)
        let best = all.first?.cost ?? 0
        let visible = all.filter { $0.cost - best <= coordinator.suggestionWindow }
        return (.known(all.map {
                    .init(id: .known("\($0.word)#\($0.source)"), word: $0.word,
                          cost: $0.cost, emitCount: .unknown,
                          source: Int($0.source), language: Int($0.language))
                }),
                .known(visible.prefix(3).map {
                    .init(id: .known("\($0.word)#\($0.source)"), surface: $0.word,
                          origin: .known(.candidate(id: "\($0.word)#\($0.source)")))
                }))
    }

    private func commit(from r: InputCoordinator.TokenCommitReport)
        -> CanonicalSession.Action.Commit? {
        guard r.kind != .empty else { return nil }
        return .init(
            kind: .init(rawValue: r.kind.rawValue) ?? .literal,
            tokenID: r.tokenID.map { Epistemic.known($0) } ?? .unknown,
            literal: r.literal, displayBefore: r.displayBefore,
            committed: r.committed,
            // JSON sonsuz taşıyamıyor; koruma durumu ayrı bayrakta.
            delta: r.delta?.isFinite == true ? r.delta : nil,
            theta: r.theta?.isFinite == true ? r.theta : nil,
            bestCost: r.bestCost, bestWord: r.bestWord,
            language: r.language.map(Int.init),
            touchCount: r.touchCount, casingApplied: r.casingApplied,
            literalProtected: r.theta?.isFinite == false,
            label: .init(source: .production, confidence: .weak,
                         targetWord: nil, matchesTarget: nil),
            cursorBefore: .known(state.cursor))
    }

    private func sample(from t: CanonicalSession.Touch) -> TouchSample {
        TouchSample(down: Point(x: t.decoderX ?? t.normX ?? 0,
                                y: t.decoderY ?? t.normY ?? 0),
                    timestamp: t.timestamp)
    }

    /// Belge farkı — **sonek koruyan** en basit gösterim.
    ///
    /// Ortak öneki bulup gerisini "sil + yaz" olarak yazıyor. Minimal düzenleme
    /// mesafesi aramıyoruz: aynı sonucu üreten birden çok mutasyon dizisi var
    /// ve hangisinin "gerçek" olduğunu bilmiyoruz. Belirlenimci ve
    /// doğrulanabilir olması yeterli — `documentHash` zaten sonucu sabitliyor.
    private func diff(from old: String, to new: String) -> [DocumentMutation] {
        if old == new { return [] }
        let common = zip(old, new).prefix { $0 == $1 }.count
        var out: [DocumentMutation] = []
        let deleted = old.count - common
        if deleted > 0 { out.append(.deleteBackward(count: deleted)) }
        let inserted = String(new.dropFirst(common))
        if !inserted.isEmpty { out.append(.insert(inserted)) }
        return out
    }

    private func editorText(_ editor: DocumentEditor) -> String {
        (editor.contextBeforeInput ?? "") + (editor.contextAfterInput ?? "")
    }

    // MARK: - Yazma

    private struct Terminal: Encodable {
        let reason: String
        let at: TimeInterval
        let finalText: String
        let cursor: Int
        let promptTokenCount: Int
        let violations: [String]
        let unverifiable: [Int]
    }

    private func emit<T: Encodable>(_ type: SessionJournal.FrameType, _ payload: T,
                                    durable: Bool = true) throws {
        let data: Data
        do { data = try encoder.encode(payload) }
        catch { throw IngressError.writeFailed("\(error)") }
        try writer.append(.init(type: type, payload: data), durable: durable)
    }

    private func require(_ allowed: Phase...) throws {
        guard allowed.contains(phase) else {
            throw IngressError.wrongPhase(expected: allowed, actual: phase)
        }
    }
}
