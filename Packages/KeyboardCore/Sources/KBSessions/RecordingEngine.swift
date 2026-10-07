import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBLearning
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
///
/// ## Dosya düzeni
///
/// Tipler (`Phase`, `IngressError`, `CommandEnvelope`) `+Types`'ta, uzantının
/// kalibrasyon/kişisel sözlük/okuma yüzeyi `+Production`'da, rapordan kayıt
/// parçası kuran dönüşümler `ActionBuilder`'da.
@MainActor
public final class RecordingEngine {

    // MARK: - Durum

    public private(set) var phase: Phase = .initializing
    /// Katlanmış görünüm — `completed` koşulu buna bakıyor.
    public private(set) var state = SessionEventReducer.State()

    private let writer: SessionJournalWriter
    private let encoder = SessionCodec.encoder
    var coordinator: InputCoordinator
    private let layout: KeyLayout

    private var touches: [Int: CanonicalSession.Touch] = [:]
    /// Bir harfe bağlanmış dokunmalar — ikinci kez bağlanamazlar.
    private var consumedTouches: Set<Int> = []
    private var actions: [CanonicalSession.Action] = []
    private var nextActionID = 0
    private var startTime: TimeInterval = 0
    /// Türetilen belge metni; `documentHash` bundan hesaplanıyor.
    private(set) var document = ""
    /// Gösterilen hedef dizisi; **bilinmiyorsa** `nil` ve tamamlanma ölçülemez.
    private var promptTokens: [String]?
    private var promptTokenCount: Int? { promptTokens?.count }
    /// §12.5: hedefli kayıtta niyet **protokolden** biliniyor.
    private var alignmentIsConstructed = false
    private var configured = false
    /// Kayıt koşulunun normatif politikası — **uygulanıyor**, yalnız
    /// kaydedilmiyor.
    ///
    /// `attemptStarted`'dan geliyor, `configure`'dan **değil**: aynı olguyu iki
    /// girişten almak, birinci frame'de A yazıp motoru B ile kurmayı mümkün
    /// kılıyordu ve hiçbir şey ikisinin eşit olduğunu kontrol etmiyordu.
    private(set) var policy = RecordingPolicy.behavior
    /// Host alanı literal'i koruyor mu (e-posta, URL, parola dışı özel alanlar).
    ///
    /// **Politikadan ayrı**: politika kayıt koşulunun normatif kuralı, bu ise
    /// o anki alanın özelliği. İkisini tek bayrağa indirmek `.behavior`
    /// politikasında e-posta alanının korumasını tamamen kaybettiriyordu —
    /// `InputCoordinator`'ın koruma testleri vardı ama üretim bağlantısı
    /// test edilmiyordu.
    public var fieldProtectsLiteral = false
    /// Derleme kimliği — yine `attemptStarted`'dan; aynı gerekçe.
    ///
    /// Bu olgular deneme **başlamadan** biliniyor ve motorun kurulmasını
    /// beklemiyor: yükleme bitmeden yarıda kalan bir deneme de hangi derlemeyle
    /// ve hangi koşulda koştuğunu söyleyebilmeli, yoksa vazgeçme analizinden
    /// düşer.
    private var identity: BuildIdentity?
    /// Deneme başlarken belge boş muydu.
    ///
    /// Boş değilse `finalText` **yazılmıyor**: türetilen metin host'un zaten
    /// yazılı olan içeriğini de taşırdı.
    private var baselineIsEmpty = true

    /// **Kayda girmeyen durum değişikliği denemeyi geçersiz kılıyor.**
    ///
    /// Seçim düzenlemesi ve composing iptali koordinatörün durumunu
    /// değiştiriyor ama `ReplayCommand`'ın kapalı kümesinde karşılıkları yok:
    /// action üretilmiyor, `state` güncellenmiyor. Sessizce devam etmek,
    /// katlamanın gerçekte olandan başka bir geçmişi anlatması demekti —
    /// `"ka"` yazıp composing iptal edip `"l"` + boşluk yapınca canlı taraf tek
    /// dokunmalı bir token commit ederken reducer üç dokunma bekliyordu.
    ///
    /// Bu yüzden bayrak işaretleniyor: çağıran denemeyi kapatıp yenisine geçmek
    /// zorunda. Kaybedilen bağlam, yanlış anlatılan bağlamdan iyi.
    public internal(set) var stateChangedOutsideTheLog = false

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
    /// - Parameter baseline: deneme **başlarken** belgede zaten duran metin.
    ///
    /// ## Neden gerekli
    ///
    /// `document` daima `""` başlıyordu. Üretimde host'ta zaten metin varsa ilk
    /// mutasyon onu **bizim yazdığımız gibi** kaydediyordu: kullanıcı
    /// WhatsApp'ta yazılı bir mesajın sonuna tek harf eklese, o mesajın tamamı
    /// `.insert(...)` olarak diske düşüyordu. Kayıt ekranında sorun değildi
    /// (tampon sıfırdan başlıyor), uzantıda **veri sızıntısı**.
    ///
    /// Taban **saklanmıyor**, yalnız farkın hesaplandığı nokta olarak
    /// kullanılıyor: mutasyonlar artık host metnini içermiyor. Taban boş
    /// değilse kaydın belge zinciri dışarıdan **doğrulanamaz** ve kayıt bunu
    /// söylüyor (`documentBaselineKnown == false`).
    public func begin(_ descriptor: CanonicalSession, at t: TimeInterval,
                      baseline: String = "") throws {
        try require(.initializing)
        document = baseline
        baselineIsEmpty = baseline.isEmpty
        // Politika ve derleme kimliği **buradan** alınıyor ve `configure`'da bir
        // daha sorulmuyor. İkinci bir giriş, kayda yazılanla motorun kurulduğu
        // politikanın ayrışmasına izin veriyordu — ve ayrıştığını hiçbir şey
        // kontrol etmiyordu.
        policy = try Self.policy(from: descriptor.engine.policy)
        identity = BuildIdentity(
            buildConfiguration: descriptor.engine.buildConfiguration,
            appVersion: descriptor.engine.appVersion,
            build: descriptor.engine.build)
        startTime = t
        promptTokens = descriptor.promptTokens.value
        alignmentIsConstructed = descriptor.isTargetedProtocol
        try emit(.attemptStarted, descriptor)
        phase = .awaitingConfiguration
    }

    /// Kaydedilen politikayı **uygulanabilir** hâle çevirir.
    ///
    /// Bilinmeyen bir alanda varsayılana düşmek en kötüsüydü: kayıt
    /// "bilmiyorum" derken motor `behavior` gibi kurulur ve replay farkı hiçbir
    /// zaman açıklanamazdı.
    private static func policy(
        from record: CanonicalSession.EngineSnapshot.PolicyRecord) throws
        -> RecordingPolicy {
        guard let feedback = record.feedbackVisible.value else {
            throw IngressError.policyUnknown("feedbackVisible")
        }
        guard let suggestions = record.suggestionsVisible.value else {
            throw IngressError.policyUnknown("suggestionsVisible")
        }
        guard let correction = record.correction.value else {
            throw IngressError.policyUnknown("correction")
        }
        return .init(feedbackVisible: feedback, suggestionsVisible: suggestions,
                     correction: correction, learning: record.learning)
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
    /// Politika `begin`'de alınmış olanı: kaydedip uygulamamak en kötüsüydü
    /// (`calibrationReplay` koşulunda `correction: .suppressed` yazılırken
    /// düzeltme fiilen çalışıyordu), ama iki ayrı girişten almak da aynı kapıya
    /// çıkıyordu — bu kez ayrışmayı kimse fark etmeden.
    /// - Parameter personal: kullanıcının kişisel sözlüğü (§8.7).
    ///   **Kurulumun parçası**, sonradan eklenen bir şey değil: motor kurulduktan
    ///   sonra uygulansaydı `engineConfigured` snapshot'ı leksikonu eksik
    ///   anlatırdı. Devretmede (`rollOver`) koordinatör sıfırdan kuruluyor,
    ///   dolayısıyla sözlüğün her denemede yeniden verilmesi zorunlu.
    /// - Parameter learner: öğrenilmiş kalibrasyon rezervuarı.
    ///
    ///   ## Neden burada, neden `applyCalibration` yetmiyor
    ///
    ///   `rollOver` koordinatörü **sıfırdan** kuruyor: yeni koordinatörün
    ///   rezervuarı boş ve uzamsal modeli kalibrasyonsuz. Uzantı
    ///   `applyCalibration`'ı yalnız paket yüklemesinde ve profil değişiminde
    ///   çağırıyordu, dolayısıyla 512 KB'lık tampon sınırına gelen kullanıcı
    ///   **öğrenilmiş sapmasını yürürlükten düşürüyordu** — dosya duruyordu ama
    ///   canlı motor kalibrasyonsuz koşuyordu.
    ///
    ///   Kurulumun parçası olması ayrıca snapshot'ı da düzeltiyor: kalibrasyon
    ///   `capture`'dan **önce** uygulandığı için kayıt motorun fiilen taşıdığı
    ///   sapmayı yazıyor, `applied: false` diye yalan söylemiyor.
    ///
    ///   `calibration` parametresiyle **birlikte verilmemeli**: biri kayıttan
    ///   gelen (replay), diğeri canlı öğrenme. İkisi aynı anda uygulanırsa
    ///   hangi sapmanın yürürlükte olduğu belirsizleşir.
    public func configure(loaded: PackLoader.Loaded,
                          calibration: CanonicalSession.EngineSnapshot
                                        .CalibrationSnapshot,
                          personal: PersonalLexicon = PersonalLexicon(),
                          learner: CalibrationLearner? = nil) throws {
        if learner != nil, calibration.applied {
            throw IngressError.calibrationUnusable(
                "kayıttan gelen kalibrasyon ile canlı öğrenici birlikte verilemez")
        }
        try require(.awaitingConfiguration)
        guard !configured else { throw IngressError.alreadyConfigured }
        // `begin` fazı geçirdiği için burada daima dolu; yine de sessiz bir
        // varsayılan yerine hata.
        guard let identity else { throw IngressError.policyUnknown("build") }

        // **Kalibrasyon burada da uygulanıyor** — replay ile aynı fonksiyon.
        //
        // Önce yalnız kaydediliyordu: `applied: true` verilen bir kayıtta canlı
        // motor kalibrasyonsuz koşarken kayıt "uygulandı" diyor, replay ise
        // uyguluyordu. Bugünkü UI daima `false` veriyor, yani tuzak gizliydi.
        //
        // İddia edilip uygulanamıyorsa deneme **başlamıyor**: yarısı kalibre bir
        // modelle kayıt almak, hangi motorun ölçüldüğünü söyleyememek demek.
        let decoder: Decoder
        do {
            decoder = try CanonicalSession.EngineSnapshot.calibrated(
                loaded.decoder, with: calibration, layout: layout)
        } catch {
            throw IngressError.calibrationUnusable(error.description)
        }
        coordinator.setEngine(.init(decoder: decoder,
                                    literalChannel: loaded.literalChannel,
                                    expansions: loaded.expansions))
        // Snapshot'tan **önce**: kişisel kaynak da leksikonun bir üyesi ve
        // `capture` onu koordinatörden okuyor.
        if !personal.isEmpty { coordinator.replacePersonalLexicon(personal) }
        // Aynı gerekçe: öğrenilmiş sapma da motorun bir parçası. `capture`
        // uzamsal modeli koordinatörden okuduğu için kayıt fiilen uygulanan
        // sapmayı yazıyor.
        if let learner, learner.sampleCount > 0 {
            coordinator.replaceCalibration(learner)
        }

        // Anlık görüntü **kurulan motordan** okunuyor: çağıranın verdiği
        // görüntü ile decoder'ın taşıdığı kalibrasyon ayrışabiliyordu.
        let snapshot = CanonicalSession.EngineSnapshot.capture(
            loaded: loaded, coordinator: coordinator,
            buildConfiguration: identity.buildConfiguration,
            appVersion: identity.appVersion,
            build: identity.build, policy: policy,
            calibration: CanonicalSession.EngineSnapshot
                .calibrationSnapshot(of: coordinator.spatialModel))
        try emit(.engineConfigured, snapshot, durable: false)
        configured = true
        phase = .recording
    }

    /// Denemenin saatiyle dokunma saatinin **aynı tabanda** olması için pay.
    ///
    /// Sıfır değil: `begin` çağrısı ile ilk `touchesBegan` arasında dokunma
    /// zamanının başlangıçtan bir tık önce görünmesi mümkün (aynı olay
    /// döngüsünde okunan iki değer). Bir saniye, taban karışıklığının
    /// büyüklüğüne (10⁸ s) göre bol bol dar.
    static let clockTolerance: TimeInterval = 1

    /// Ham dokunma. **Komuttan önce** gelmek zorunda: harf zarfı onun
    /// kimliğine atıf yapıyor.
    public func record(_ touch: CanonicalSession.Touch) throws {
        try require(.recording)
        // Taban kontrolü **yazmadan önce**: yanlış saatli bir dokunma diske
        // düştüğü anda kayıt kurtarılamaz hâle geliyor, çünkü hangi tabandan
        // geldiği sonradan bilinemez.
        guard touch.timestamp >= startTime - Self.clockTolerance else {
            throw IngressError.clockMismatch(touchID: touch.touchID,
                                             touch: touch.timestamp,
                                             start: startTime)
        }
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
        let touch = try validate(envelope)

        let action = try apply(envelope, touch: touch, into: editor)
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
    ///
    /// - Parameter finalText: **doğrulama** için; kayda motorun kendi belgesi
    ///   yazılıyor. Çağıranın metnini olduğu gibi kaydetmek, host'un gördüğüyle
    ///   kaydın ayrıştığı durumu görünmez yapardı.
    /// - Parameter note: kullanıcının "ne yazmak istedim, ne oldu" anlatısı.
    ///   **Ölçüm değil**; boş bırakılabilir.
    @discardableResult
    public func finish(_ reason: TerminalReason, at t: TimeInterval,
                       finalText: String, note: String? = nil) throws -> Phase {
        try require(.recording, .finishing)
        phase = .finishing

        let resolved = resolve(reason, claimedFinalText: finalText)
        let terminal = SessionJournal.Terminal(reason: resolved.rawValue, at: t - startTime,
                               // Taban bilinmiyorsa nihai metin **yazılmıyor**:
                               // host'un zaten orada olan içeriğini kayda
                               // koymak, kullanıcının bu dilimde yazmadığı şeyi
                               // saklamak olurdu.
                               finalText: baselineIsEmpty ? document : "",
                               cursor: state.cursor,
                               promptTokenCount: promptTokenCount ?? -1,
                               violations: state.violations.map(\.description),
                               unverifiable: state.unverifiable,
                               // Boş not **yok** demek; boş dize yazmak
                               // "yazdı ama bir şey söylemedi" gibi görünürdü.
                               note: note?.trimmingCharacters(in: .whitespacesAndNewlines)
                                   .isEmpty == false ? note : nil,
                               documentBaselineKnown: baselineIsEmpty)
        try emit(.terminal, terminal)
        phase = Phase(resolved)
        return phase
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
    ///
    /// - Returns: kayda yazılacak durum — terminal frame onu taşıyor.
    private func resolve(_ reason: TerminalReason,
                         claimedFinalText: String) -> CanonicalSession.Status {
        // Yalnız `completed` iddiası doğrulanıyor. `captured` **koşulsuz**:
        // üretimde hedef yok, dolayısıyla tamamlanma diye bir ölçüm de yok. Onu
        // `completed` kapısından geçirmek, ölçülmemiş bir şeyi ölçülmüş
        // göstermek olurdu.
        guard reason == .completed else { return reason.claimedStatus }
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
            // Taban bilinmiyorsa metin karşılaştırması anlamsız; ama o durumda
            // zaten hedefli bir deneme yok (`captured` yolu yukarıda çıkıyor).
            && (!baselineIsEmpty || claimedFinalText == document)
        return ok ? .completed : .invalid
    }

    /// Henüz terminal fazına ulaşmamış dokunmalar.
    private var openTouches: [Int] {
        touches.values.filter { !$0.phase.isTerminal }.map(\.touchID)
    }

    // MARK: - Uygulama

    /// Zarfı komut **uygulanmadan önce** doğrular.
    ///
    /// - Returns: harf komutunun uzamsal kanıtı; diğer komutlarda `nil`.
    private func validate(_ e: CommandEnvelope) throws -> TouchSample? {
        guard case .letter = e.command else { return nil }
        guard let id = e.touchID else { throw IngressError.letterWithoutTouch }
        guard let recorded = touches[id] else { throw IngressError.unknownTouch(id) }
        guard !consumedTouches.contains(id) else {
            throw IngressError.touchAlreadyConsumed(id)
        }
        // Noktası olmayan kayıtlı dokunma `(0,0)`'a düşüyor — üretimde harf
        // dokunmasının normalize noktası daima var; bu yalnız elle kurulmuş
        // kayıtlarda görülebilir ve davranış eskisiyle aynı.
        return recorded.decoderSample
            ?? TouchSample(down: Point(x: 0, y: 0), timestamp: recorded.timestamp)
    }

    private func apply(_ e: CommandEnvelope, touch: TouchSample?,
                       into editor: DocumentEditor) throws
        -> CanonicalSession.Action {
        let kind = e.command.actionKind
        var effect: Epistemic<DestructiveEffect> = .notApplicable
        var commit: CanonicalSession.Action.Commit?
        var candidates: Epistemic<[CandidateSnapshot]> = .notApplicable
        var shown: Epistemic<ShownSnapshot> = .notApplicable

        // Aday görüntüsü **commit'ten önce** alınmalı: sınır beam'i sıfırlıyor
        // ve sonrasında liste boş çıkardı.
        if kind.snapshotsSuggestions {
            (candidates, shown) = snapshotSuggestions()
        }
        // Kişisel sözlük kabulü commit'in **içinde** olabiliyor; sürüm
        // öncesinde okunuyor ki fark görülebilsin (§8.7).
        let personalBefore = coordinator.personalVersion

        let result: InputCoordinator.CommandResult
        do {
            // Komutu motora çeviren kural **koordinatörde** — golden replay ve
            // uzantının yedek yolu aynı dağıtımı kullanıyor.
            result = try coordinator.perform(
                e.command, touch: touch,
                // `calibrationReplay` koşulunda düzeltme **uygulanmıyor**;
                // `fieldProtectsLiteral` literal'i koruyan mevcut mekanizma.
                // Politikayı kaydedip uygulamamak, kaydın kendi anlattığından
                // başka bir klavyeyi ölçmesi demekti. İkisi de koruyabilir:
                // koşul düzeltmeyi bastırıyorsa **ya da** alan literal istiyorsa.
                fieldProtectsLiteral: policy.correction == .suppressed
                    || fieldProtectsLiteral,
                into: editor)
        } catch {
            // Bozuk komut **hiçbir şeyi** değiştirmedi: koordinatör doğrulamayı
            // mutasyondan önce yapıyor. Klavyeyi düşürmek yerine denemeyi
            // reddediyoruz.
            throw IngressError.malformedCommand(error.description)
        }
        if let id = e.touchID, case .letter = e.command { consumedTouches.insert(id) }

        switch result {
        case .input:
            break
        case let .boundary(report):
            commit = ActionBuilder.commit(from: report, label: label(for: report),
                                          cursor: state.cursor)
            // Etki **rapordan** geliyor, varsayımdan değil: kanıtı kopmuş bir
            // oturumda sınır işlemi gerçek bir no-op ve `.boundary` yazmak
            // reducer'a kopukluktan çıkıldığını söylerdi.
            effect = .known(report.effect)
        case let .destructive(e):
            effect = e
        }

        // Kelime kişisel sözlüğe kabul edildiyse leksikon değişti — **kayıt
        // dışı bir motor değişikliği**. `engineConfigured` snapshot'ı artık
        // motoru anlatmıyor (paket listesinde kişisel kaynak yok, ya da eski
        // özetiyle var). `applyCalibration` ile aynı durum, aynı çözüm: deneme
        // işaretleniyor ve çağıran `rollOverIfNeeded` ile yenisine geçiyor.
        if coordinator.personalVersion != personalBefore {
            stateChangedOutsideTheLog = true
        }

        // Belge mutasyonu **çağrıdan sonra** ve **bir kez** okunuyor: iki kez
        // okumak, mutasyon ile özetin farklı anlık görüntülerden çıkmasına
        // izin veriyordu (arada gelen bir host callback'i yeter).
        let after = editorText(editor)
        let mutations = DocumentReconstruction.mutations(from: document, to: after)
        document = after

        let id = nextActionID
        nextActionID += 1
        return CanonicalSession.Action(
            actionID: id, t: e.timestamp - startTime, kind: kind,
            touchID: e.touchID,
            event: .known(e.command), effect: effect,
            document: .known(.init(mutations: mutations,
                                   hashAfter: DocumentReconstruction.hash(document))),
            targetTokenIndex: state.cursor,
            targetToken: nil,
            candidates: candidates, shown: shown, commit: commit)
    }

    private func snapshotSuggestions()
        -> (Epistemic<[CandidateSnapshot]>, Epistemic<ShownSnapshot>) {
        // **Tek çağrı**: `candidates()` ile `shownCandidates()` ayrı ayrı
        // çağrılırsa ikisi arasında beam değişebilir ve kayıt, hiç birlikte
        // var olmamış iki listeyi yan yana koyar.
        let all = coordinator.candidates(topK: 8).map(ActionBuilder.candidate)
        // Öneri çubuğu gizliyse kullanıcı **hiçbir şey görmedi**. Pencere
        // içindeki adayları "gösterildi" yazmak, "kullanıcı öneriyi görüp
        // görmezden geldi" analizini yanıltırdı (§12.3).
        guard policy.suggestionsVisible else {
            return (.known(all), .known(.init(items: [], completeness: .complete)))
        }
        return (.known(all), .known(ActionBuilder.shown(coordinator.suggestions(limit: 3))))
    }

    /// §12.5 etiketi.
    ///
    /// > `calibrationReplay` koşulunda, hedef kelime **kelime kelime**
    /// > gösterilmişse ve `literal == hedef` ise, o token **`strong`**
    /// > sayılabilir — çünkü niyet gözlemden değil **protokolden** bilinir.
    ///
    /// Koşulsuz `strong` yazmak etiketi sözleşmeden güçlü yapardı; `production`
    /// yazmak ise hedefli kaydın bütün değerini atardı. Kural `Commit.Label.make`
    /// içinde: golden replay de onu çağırıyor.
    private func label(for r: InputCoordinator.TokenCommitReport)
        -> CanonicalSession.Action.Commit.Label {
        .make(literal: r.literal, promptTokens: promptTokens,
              cursor: state.cursor,
              alignmentIsConstructed: alignmentIsConstructed,
              diverged: state.diverged)
    }

    private func editorText(_ editor: DocumentEditor) -> String {
        (editor.contextBeforeInput ?? "") + (editor.contextAfterInput ?? "")
    }

    // MARK: - Yazma

    private func emit<T: Encodable>(_ type: SessionJournal.FrameType, _ payload: T,
                                    durable: Bool = true) throws {
        let data: Data
        do { data = try encoder.encode(payload) }
        catch { throw IngressError.writeFailed("\(error)") }
        try writer.append(.init(type: type, payload: data), durable: durable)
    }

    func require(_ allowed: Phase...) throws {
        guard allowed.contains(phase) else {
            throw IngressError.wrongPhase(expected: allowed, actual: phase)
        }
    }
}
