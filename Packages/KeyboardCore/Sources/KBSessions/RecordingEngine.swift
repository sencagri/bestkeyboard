import Foundation
import KBAssembly
import KBDecoder
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
@MainActor
public final class RecordingEngine {

    /// Deneme durum makinesi.
    ///
    /// Terminal durumlar **değişmez**. Kurtarma yalnız `recording →
    /// interrupted`: tamamlanmış bir denemeyi sonradan kesintiye çevirmek,
    /// geçmişe dönük olarak veriyi yeniden yorumlamak olurdu.
    public enum Phase: String, Equatable, Sendable {
        case initializing
        /// Deneme diske düştü ama paketler henüz yüklenmedi.
        ///
        /// Ayrı bir faz olmak zorunda: bu aralıkta gelen bir komut, motoru
        /// kurulmadan sürerdi ve kayıt hangi konfigürasyonla üretildiğini
        /// söyleyemezdi.
        case awaitingConfiguration
        case recording, finishing
        case completed, aborted, invalid, interrupted

        public var isTerminal: Bool {
            switch self {
            case .initializing, .awaitingConfiguration, .recording, .finishing:
                return false
            case .completed, .aborted, .invalid, .interrupted:
                return true
            }
        }
    }

    public enum IngressError: Error, Equatable, CustomStringConvertible {
        case wrongPhase(expected: [Phase], actual: Phase)
        /// Motor iki kez yapılandırıldı.
        ///
        /// İkinci kurulum, önceki eylemlerin **başka** bir motorla üretildiği
        /// anlamına gelir; kayıt tek bir konfigürasyon iddia ederken iki
        /// tanesiyle koşmuş olurdu.
        case alreadyConfigured
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
            case .alreadyConfigured:            return "motor zaten yapılandırıldı"
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
    /// Hedef token sayısı; **bilinmiyorsa** `nil` ve tamamlanma ölçülemez.
    private var promptTokenCount: Int?
    private var configured = false
    /// Kayıt koşulunun normatif politikası — **uygulanıyor**, yalnız
    /// kaydedilmiyor.
    private var policy = RecordingPolicy.behavior

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
        promptTokenCount = descriptor.promptTokens.value?.count
        try emit(.attemptStarted, descriptor)
        phase = .awaitingConfiguration
    }

    /// Motoru **kurar** ve aynı kaynaktan üretilen anlık görüntüyü yazar.
    ///
    /// ## Neden hazır bir snapshot almıyor
    ///
    /// Önceki hâli yalnız verilen anlık görüntüyü yazıyordu; koordinatör
    /// dışarıda kurulduğu için kayda **B** yazılırken motor **A** ile
    /// koşabiliyordu. İkisini aynı `PackLoader.Loaded`'dan üretmek bu ihtimali
    /// tiple kapatıyor: yazılan konfigürasyon, kurulan motorun ta kendisi.
    ///
    /// Politika da burada uygulanıyor. Kaydedip uygulamamak en kötüsüydü:
    /// `calibrationReplay` koşulunda `correction: .suppressed` yazılırken
    /// düzeltme fiilen çalışıyor ve kayıt kendi anlattığından başka bir
    /// klavyeyi ölçüyordu.
    public func configure(loaded: PackLoader.Loaded,
                          policy: RecordingPolicy,
                          buildConfiguration: String,
                          appVersion: String,
                          build: CanonicalSession.EngineSnapshot.BuildManifest,
                          calibration: CanonicalSession.EngineSnapshot
                                        .CalibrationSnapshot) throws {
        try require(.awaitingConfiguration)
        guard !configured else { throw IngressError.alreadyConfigured }

        coordinator.setEngine(.init(decoder: loaded.decoder,
                                    literalChannel: loaded.literalChannel,
                                    expansions: loaded.expansions))
        self.policy = policy

        let snapshot = CanonicalSession.EngineSnapshot.capture(
            loaded: loaded, coordinator: coordinator,
            buildConfiguration: buildConfiguration, appVersion: appVersion,
            build: build, policy: policy, calibration: calibration)
        try emit(.engineConfigured, snapshot, durable: false)
        configured = true
        phase = .recording
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

        let action = try apply(envelope, into: editor)
        actions.append(action)
        SessionEventReducer.applyIncrementally(action, to: &state, touches: touches)
        do { try emit(.action, action, durable: false) }
        catch {
            // Yazma başarısız: belge, koordinatör ve katlanmış durum **zaten**
            // değişti ve geri alınamaz (host'a yazılanı geri almak yeni bir
            // mutasyon olurdu). Belgeyi eski hâline "geri saymak" kaydı daha da
            // tutarsız yapardı — kayıtta olmayan bir metin belgede kalırdı.
            //
            // Dürüst tepki: denemeyi zehirlemek. `.invalid` terminal ve
            // sonrasında hiçbir giriş kabul edilmiyor.
            phase = .invalid
            throw IngressError.writeFailed("\(error)")
        }
        return action
    }

    /// Denemeyi kapatır. Terminal frame **dayanıklı** yazılır.
    @discardableResult
    /// - Parameter finalText: **doğrulama** için; kayda motorun kendi belgesi
    ///   yazılıyor. Çağıranın metnini olduğu gibi kaydetmek, host'un gördüğüyle
    ///   kaydın ayrıştığı durumu görünmez yapardı.
    public func finish(_ reason: TerminalReason, at t: TimeInterval,
                       finalText: String) throws -> Phase {
        try require(.recording, .finishing)
        phase = .finishing

        let resolved = resolve(reason, claimedFinalText: finalText)
        let terminal = Terminal(reason: resolved.rawValue, at: t - startTime,
                               finalText: document,
                               cursor: state.cursor,
                               promptTokenCount: promptTokenCount ?? -1,
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
    private func resolve(_ reason: TerminalReason,
                         claimedFinalText: String) -> Phase {
        guard reason == .completed else {
            return Phase(rawValue: reason.rawValue) ?? .invalid
        }
        // Hedef dizisi bilinmiyorsa tamamlanma **ölçülemez**. `?? 0` ile boş
        // hedefe düşmek, hiçbir şey yazılmamış bir denemeyi "tamamlandı"
        // saymaktı.
        guard let expected = promptTokenCount else { return .invalid }
        let ok = state.cursor == expected
            && state.pending.isEmpty
            // Açık bir composing token varken tamamlandı demek, ölçülmemiş bir
            // kelimeyi ölçülmüş saymak. `pending` boş olabilir ama kanıtı
            // kopmuş bir yüzey hâlâ açık olabilir.
            && !coordinator.session.isComposing
            && !coordinator.session.isEditingSelection
            && state.violations.isEmpty
            // Doğrulanamayan olgular varsa "fark yok" denemez.
            && state.unverifiable.isEmpty
            && openTouches.isEmpty
            && configured
            // Çağıranın gördüğü metin ile motorun belgesi ayrışmışsa kayıt
            // host'un gösterdiğini anlatmıyor demektir.
            && claimedFinalText == document
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
        var shown: Epistemic<ShownSnapshot> = .notApplicable

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
            // Etki **rapordan** geliyor, varsayımdan değil: kanıtı kopmuş bir
            // oturumda sınır işlemi gerçek bir no-op ve `.boundary` yazmak
            // reducer'a kopukluktan çıkıldığını söylerdi.
            effect = .known(report.effect)

        case .space:
            kind = .space
            // Aday görüntüsü **commit'ten önce** alınmalı: `space` beam'i
            // sıfırlıyor ve sonrasında liste boş çıkardı.
            (candidates, shown) = snapshotSuggestions()
            // `calibrationReplay` koşulunda düzeltme **uygulanmıyor**;
            // `fieldProtectsLiteral` literal'i koruyan mevcut mekanizma.
            // Politikayı kaydedip uygulamamak, kaydın kendi anlattığından
            // başka bir klavyeyi ölçmesi demekti.
            let report = coordinator.space(
                into: editor,
                fieldProtectsLiteral: policy.correction == .suppressed)
            commit = self.commit(from: report)
            effect = .known(report.effect)

        case .newline:
            kind = .newline
            (candidates, shown) = snapshotSuggestions()
            let report = coordinator.newline(into: editor)
            commit = self.commit(from: report)
            effect = .known(report.effect)

        case let .suggestionPick(_, surface, _):
            kind = .suggestionPick
            (candidates, shown) = snapshotSuggestions()
            let report = coordinator.pickSuggestion(surface, into: editor)
            commit = self.commit(from: report)
            effect = .known(report.effect)

        case .backspaceTap:
            kind = .backspaceTap
            effect = coordinator.backspaceTap(into: editor)

        case .backspaceRepeat:
            kind = .backspaceRepeat
            effect = coordinator.backspaceRepeat(into: editor)

        case .deleteWord:
            kind = .deleteWord
            effect = coordinator.deleteWord(into: editor)

        case .planeChange:
            kind = .planeChange
        case .shift:
            kind = .shift
        }

        // Belge mutasyonu **çağrıdan sonra** ve **bir kez** okunuyor: iki kez
        // okumak, mutasyon ile özetin farklı anlık görüntülerden çıkmasına
        // izin veriyordu (arada gelen bir host callback'i yeter).
        let after = editorText(editor)
        let mutations = diff(from: document, to: after)
        document = after

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
        -> (Epistemic<[CandidateSnapshot]>, Epistemic<ShownSnapshot>) {
        // **Tek çağrı**: `candidates()` ile `shownCandidates()` ayrı ayrı
        // çağrılırsa ikisi arasında beam değişebilir ve kayıt, hiç birlikte
        // var olmamış iki listeyi yan yana koyar.
        let all = coordinator.candidates(topK: 8)
        // Öneri çubuğu gizliyse kullanıcı **hiçbir şey görmedi**. Pencere
        // içindeki adayları "gösterildi" yazmak, "kullanıcı öneriyi görüp
        // görmezden geldi" analizini yanıltırdı (§12.3).
        guard policy.suggestionsVisible else {
            return (.known(all.map(Self.snapshot)),
                    .known(.init(items: [], completeness: .complete)))
        }
        // Gösterilen yüzeyler **UI'ın kullandığı tek kaynaktan** geliyor:
        // burada yeniden hesaplamak, genişletme yüzeylerini (§4.D) atlayıp
        // listeyi eksik ama "eksiksiz" diye yazmak olurdu.
        let surfaces = coordinator.suggestionSurfaces(limit: 3)
        let byWord = Dictionary(all.map { ($0.word, $0) },
                                uniquingKeysWith: { a, _ in a })
        return (.known(all.map(Self.snapshot)),
                .known(.init(
                    items: surfaces.map { surface in
                        // Aday listesinde yoksa bu bir **genişletme** (§4.D):
                        // ayrı bir teklif, sıralama adayı değil.
                        if let c = byWord[surface] {
                            return .init(id: .known(Self.id(of: c)),
                                         surface: surface,
                                         origin: .known(.candidate(
                                            id: Self.id(of: c))))
                        }
                        return .init(id: .known("expansion:\(surface)"),
                                     surface: surface,
                                     origin: .known(.expansion(
                                        trigger: coordinator.session.display)))
                    },
                    // Yerel kayıt **eksiksiz**: gösterilen yüzeylerin tamamı
                    // UI ile aynı çağrıdan geliyor.
                    completeness: .complete)))
    }

    private static func id(of c: DecodeResult) -> String {
        "\(c.word)#\(c.source)"
    }

    private static func snapshot(_ c: DecodeResult) -> CandidateSnapshot {
        // `emitCount` **biliniyor**: decoder onu üretiyor. `.unknown` yazmak
        // bilinen bir olguyu atmaktı — omission/insertion teşhisi buna bakıyor.
        .init(id: .known(id(of: c)), word: c.word, cost: c.cost,
              emitCount: .known(c.emitCount),
              source: Int(c.source), language: Int(c.language))
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
