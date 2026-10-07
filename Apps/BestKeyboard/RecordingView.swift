import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions

/// Gerçek yazım kaydı — sözleşme §12.
///
/// ## Neden kalibrasyon UYGULANMADAN kaydediyor
///
/// İlk tasarım ürün yolunu (kalibrasyon açık) kullanacaktı. Bu, ölçülmek istenen
/// şeyi ölçüm setinin içine gömüyordu: *"kalibrasyon işe yarıyor mu"* sorusu,
/// kalibrasyonun zaten açık olduğu bir kayıtla sorulamaz.
///
/// Çözüm daha basit ve daha güçlü: **ham modelle kaydet, kalibrasyonu replay'de
/// uygula.** Tek bir kayıttan §8.6'nın üç kolu da (kalsız / global / hiyerarşik)
/// offline ölçülebilir ve kayıt hiçbirine taraf olmaz.
///
/// Öğrenme de kapalı: bu `InputCoordinator` örneği kendine ait, `.bkl`'ye hiç
/// yazmıyor ve `applyCalibration()` hiç çağrılmıyor. Kullanıcının gerçek profili
/// hedefli yazım örnekleriyle kirlenmiyor.
final class RecorderViewController: UIViewController {

    private let prompt: PromptCorpus.Prompt
    private let condition: CanonicalSession.Condition
    private let posture: CanonicalSession.Posture
    private let participantID: String
    private let sessionOrdinal: Int
    private let onFinish: () -> Void

    init(prompt: PromptCorpus.Prompt, condition: CanonicalSession.Condition,
         posture: CanonicalSession.Posture, participantID: String,
         sessionOrdinal: Int, onFinish: @escaping () -> Void) {
        self.prompt = prompt
        self.condition = condition
        self.posture = posture
        self.participantID = participantID
        self.sessionOrdinal = sessionOrdinal
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Durum

    /// Kayıt ekranı **kullanıcının kendi ölçülerinde** yazdırıyor.
    ///
    /// Kaydın amacı gerçek yazım davranışını yakalamak; kullanıcının günlük
    /// kullanmadığı bir geometride ölçüm almak o amacı boşa çıkarıyordu.
    /// Kayıttan çıkarılan kalibrasyon da ancak böyle **onun kullandığı
    /// profile** gidiyor: profil anahtarı `layout.id`'yi taşıyor ve varsayılan
    /// geometride alınan bir kayıt başka bir kovaya düşerdi.
    ///
    /// Kayıtlar arası karşılaştırılabilirlik kaybolmuyor, açık hâle geliyor:
    /// `layoutID` kimliği, `layoutFingerprint` tuş sırası ve geometriyi kayda
    /// yazıyor, dolayısıyla iki kaydın aynı zeminde olup olmadığı **okunabilir**
    /// bir olgu. Sabit geometri varsayımı bunu yalnız örtüyordu.
    private let settings = KeyboardSettingsStore.load()
    private lazy var layout = TurkishQ.layout(metrics: settings.metrics)

    /// Bir harf satırının yüksekliği — uzantı ve tezgahla aynı.
    /// Hedef dizisi **bir kez** üretiliyor.
    ///
    /// UI'ın gösterdiği ile kayda yazılan dizinin aynı olması şart (§2.3):
    /// her çağrıda yeniden hesaplamak, tokenizer'ın davranışı değişirse ikisinin
    /// ayrışmasına izin verirdi ve validator bunu "gösterilen ≠ kaydedilen" diye
    /// yakalamak zorunda kalırdı.
    private lazy var promptTokens: [String] = prompt.words(layout: layout)
    private var shift = ShiftPolicy()

    /// Kaydı **sahiplenen** motor.
    ///
    /// `InputCoordinator` artık burada değil: dışarıdan erişilebildiği sürece
    /// kaydın görmediği bir mutasyon mümkündü ve olay günlüğü belgeyle
    /// ayrışabiliyordu. Tuş işleme tek bir `perform` çağrısından geçiyor.
    private var engine: RecordingEngine!
    private var writer: FileJournalWriter?
    private var attemptID = ""
    /// Yazma hatası **yutulmuyor** — kullanıcıya ve duruma taşınıyor.
    private var failure: String?

    /// Belge tamponu — host yok.
    private var buffer = ""
    /// Hangi hedef kelimedeyiz — **motorun katlanmış durumundan** okunuyor.
    ///
    /// VC'de ayrı bir sayaç tutmak aynı olgunun iki yerde tutulması demekti ve
    /// sınır kuralları (boş token ilerletmez, geri açma geri alır) iki yerde
    /// ayrı ayrı uygulanıyordu. Şimdi tek kaynak reducer.
    private var wordIndex: Int { engine?.state.cursor ?? 0 }
    /// Kaydın **tek** saati.
    ///
    /// `UITouch.timestamp` sistem açılışına göre ölçülüyor ve onu
    /// değiştiremiyoruz. Komutlar için duvar saati (`CFAbsoluteTimeGetCurrent`)
    /// kullanmak iki farklı tabanı **aynı alanda** karıştırıyordu: cihazdan
    /// çekilen gerçek bir kayıtta harf action'larının `t` değeri
    /// −806 576 468 çıktı, yani kaydın kendi zaman çizgisi çöptü.
    ///
    /// `startedAt` duvar saati kalıyor: o "deneme ne zaman oldu" olgusu, süre
    /// değil. `t` ve `at` ise **süre** ve iki tabanda da aynı.
    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// **Tüketilmemiş** terminal dokunma kimliği.
    ///
    /// Harf komutu bu kimliği taşıyan bir zarfla gidiyor; "son dokunmaya"
    /// örtük bağlanmak kimlik korunumunu zayıflatıyordu (iki parmak üst üste
    /// bindiğinde harf yanlış dokunmaya bağlanıyor ve kalibrasyon o yanlış
    /// koordinatı öğreniyordu).
    private var lastTouchID: Int?
    private var engineReady = false
    /// Son kaydedilen dokunmanın **kayıttaki** zaman damgası.
    ///
    /// Decoder'a `CFAbsoluteTimeGetCurrent()` verilirken kayda
    /// `UITouch.timestamp` yazılıyordu: iki farklı saat. `τ_fast` yakınında
    /// insertion sınıfı bu farkla değişebilir, yani replay kaydı birebir
    /// üretemezdi. Artık ikisi de aynı değeri görüyor (Codex turu).
    private var lastTouchTimestamp: TimeInterval?

    // MARK: - Görünüm

    private let promptLabel = UILabel()
    private let progressLabel = UILabel()
    private let typedLabel = UILabel()
    private let logLabel = UILabel()
    private let statusLabel = UILabel()
    private let suggestionStack = UIStackView()
    private var keyboardView: KeyboardView!
    private var keyLog: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // **Çubuk SwiftUI tarafında.**
        //
        // Burada `navigationItem`'a düğme koymak hiçbir şey göstermiyordu: VC
        // bir `UIViewControllerRepresentable` içinde ve `NavigationStack`'in
        // gösterdiği bar, sarmalanan çocuğun `navigationItem`'ını değil kendi
        // barındırma denetleyicisininkini okuyor. Sonuç: "Vazgeç" ve "Kaydet"
        // hiç görünmüyor ve kayıt ekranından çıkış yolu kalmıyordu.

        buildViews()
        startSession()
        loadEngine()
    }

    // MARK: - Oturum yaşam döngüsü

    private func startSession() {
        attemptID = Self.attemptID()
        let url = RecordingLibrary.directory
            .appendingPathComponent("\(attemptID).\(RecordingLibrary.journalExtension)")
        do {
            // §12.6: deneme **başlar başlamaz** diske düşer ve `attemptStarted`
            // fsync'lenir. Yalnız tamamlananları saklamak seçim yanlılığı;
            // üstelik ilk frame kaybolursa vazgeçilen deneme abort oranının
            // paydasından tamamen düşer.
            let w = try FileJournalWriter(url: url)
            writer = w
            engine = RecordingEngine(writer: w,
                                     coordinator: InputCoordinator(layout: layout),
                                     layout: layout)
            try engine.begin(descriptor(), at: Self.clock)
        } catch {
            fail("kayıt başlatılamadı: \(error)")
        }
    }

    private func descriptor() -> CanonicalSession {
        CanonicalSession(
            attemptID: attemptID,
            participantID: participantID,
            sessionOrdinal: sessionOrdinal,
            condition: condition,
            promptID: prompt.id,
            promptText: prompt.text,
            promptSource: prompt.id.hasPrefix("manual") ? .manual : .builtin,
            split: prompt.split.rawValue,
            // Gösterilen dizi **kayda giriyor**: tokenizer ileride değişse eski
            // replay değişmesin.
            promptTokens: .known(promptTokens),
            alignmentSource: condition == .calibrationReplay
                ? .constructed : .sequential,
            startedAt: Date(),
            posture: posture,
            // Paketler henüz yüklenmedi; yer tutucu uydurmak yerine
            // `configure` üzerine yazacak.
            engine: .unconfigured(buildConfiguration: RecordingSnapshot.buildConfiguration,
                                  appVersion: RecordingSnapshot.appVersion(.main),
                                  build: RecordingSnapshot.buildManifest(.main),
                                  policy: .init(Self.policy(for: condition))),
            geometry: geometrySnapshot())
    }

    /// Kayıt koşulunun **normatif** politikası — motor bunu uyguluyor.
    private static func policy(for condition: CanonicalSession.Condition)
        -> RecordingPolicy {
        condition == .calibrationReplay ? .calibration : .behavior
    }

    /// Hata **yutulmuyor**: kullanıcıya görünüyor ve deneme geçersiz sayılıyor.
    private func fail(_ message: String) {
        failure = message
        statusLabel.text = message
        keyboardView?.isUserInteractionEnabled = false
    }

    /// Vazgeç — SwiftUI çubuğundan çağrılıyor.
    func abort(note: String? = nil) {
        finish(.aborted, note: note)
    }

    /// Kaydet — SwiftUI çubuğundan çağrılıyor.
    func complete(note: String? = nil) {
        // Tamamlanma koşulunu **motor** ölçüyor: cursor hedefe tam eşit mi,
        // açık token var mı, ihlal var mı. VC'nin ayrı bir kontrol yapması
        // aynı kuralın iki yerde tutulması olurdu.
        finish(.completed, note: note)
    }

    private func finish(_ reason: RecordingEngine.TerminalReason,
                        note: String?) {
        defer { onFinish() }
        guard let engine, failure == nil else { return }
        do {
            let phase = try engine.finish(reason, at: Self.clock,
                                          finalText: buffer, note: note)
            if reason == .completed, phase != .completed {
                statusLabel.text = "deneme tamamlanmadı: \(phase.rawValue)"
            }
        } catch {
            fail("kapatılamadı: \(error)")
        }
        try? writer?.closeFile()
    }

    private static func attemptID() -> String { ProductionRecorder.attemptID() }

    // MARK: - Motor

    /// Paket yüklenmeden yazmaya **başlanmaz**: aksi hâlde aynı denemenin ilk ve
    /// ikinci yarısı farklı modelle çalışır ve replay tekrarlanamaz olur.
    private func loadEngine() {
        statusLabel.text = "paket yükleniyor…"
        keyboardView.isUserInteractionEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Paket hash'leri YALNIZ kayıt için: replay'in birebirliği buna
            // bağlı ama üretim yolunun ihtiyacı yok.
            let loaded = try? PackLoader.load(layout: self.layout, bundle: .main,
                                              computeHashes: true)
            Task { @MainActor in
                guard let loaded else {
                    self.fail("paket yüklenemedi — kayıt geçersiz")
                    return
                }
                do {
                    // Motoru **kuran** ve anlık görüntüyü **yazan** tek çağrı:
                    // ikisi ayrı olduğunda kayda B yazılırken motor A ile
                    // koşabiliyordu.
                    // Politika ve derleme kimliği **`begin`'den** geliyor:
                    // aynı olguyu ikinci kez geçmek, kayda yazılanla motorun
                    // kurulduğu politikanın ayrışmasına izin veriyordu.
                    try self.engine.configure(
                        loaded: loaded,
                        calibration: Self.calibrationSnapshot())
                } catch {
                    self.fail("motor kurulamadı: \(error)")
                    return
                }
                self.keyboardView.isUserInteractionEnabled = true
                self.statusLabel.text = loaded.report
                self.refresh()
            }
        }
    }

    /// Kayıt **kalibrasyonsuz** modelle alınıyor; kalibrasyon replay'de
    /// uygulanıyor (§12.3: öğrenme donmuş).
    private static func calibrationSnapshot()
        -> CanonicalSession.EngineSnapshot.CalibrationSnapshot {
        .init(applied: false, strongSamples: 0, biasX: [], biasY: [],
              hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                  keyX: [], keyY: []),
              sigma: .known(.init(x: [], y: [])))
    }

    private func applyTheme() {
        let t = settings.theme.resolved(for: traitCollection)
        keyboardView?.theme = t
        view.overrideUserInterfaceStyle = t.userInterfaceStyle
    }

    private func geometrySnapshot() -> CanonicalSession.Geometry {
        RecordingSnapshot.geometry(layout: layout, keyboard: keyboardView, host: view)
    }

    // MARK: - Görünüm kurulumu

    private func buildViews() {
        for (l, size, weight) in [(promptLabel, 22.0, UIFont.Weight.semibold),
                                  (progressLabel, 12.0, .regular),
                                  (typedLabel, 17.0, .regular),
                                  (logLabel, 12.0, .regular),
                                  (statusLabel, 11.0, .regular)] {
            l.font = size == 12.0 || size == 11.0
                ? .monospacedSystemFont(ofSize: size, weight: weight)
                : .systemFont(ofSize: size, weight: weight)
            l.numberOfLines = 0
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
        }
        progressLabel.textColor = .secondaryLabel
        statusLabel.textColor = .tertiaryLabel
        logLabel.textColor = .secondaryLabel
        typedLabel.textColor = .label

        suggestionStack.axis = .horizontal
        suggestionStack.distribution = .fillEqually
        suggestionStack.spacing = 4
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestionStack)
        // Öneri çubuğu **yalnız davranış kipinde** var ve dokunulabilir.
        // Kalibrasyon kipinde görünmez bir çubuk göstermek "gerçek davranış"
        // taklidi olurdu; ya gerçek ya hiç.
        for _ in 0..<3 {
            let b = UIButton(type: .system)
            b.titleLabel?.font = .systemFont(ofSize: 16)
            b.addTarget(self, action: #selector(pickSuggestion(_:)), for: .touchUpInside)
            suggestionStack.addArrangedSubview(b)
        }
        suggestionStack.isHidden = condition == .calibrationReplay

        keyboardView = KeyboardView(layout: layout, metrics: settings.metrics)
        keyboardView.cadence = settings.cadence
        keyboardView.theme = settings.theme.resolved(for: traitCollection)
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.showsGlobeKey = false
        // Kayıt ekranında erişilebilirlik etkinleştirmesi **karakter
        // üretmiyor**: buranın amacı gerçek yazım davranışını ölçmek ve
        // türetilmiş bir dokunmayı kayda sokmak, ölçmek için var olan veri
        // kümesine uydurulmuş bir gözlem koymak olurdu (§8.9). Tuşlar
        // okunmaya devam ediyor; çift dokunuş yalnız reddediliyor.
        keyboardView.allowsAccessibilityActivation = false
        keyboardView.onKeyCommit = { [weak self] hit, _ in self?.handle(hit) }
        // Virgül burada da yazılabilmeli: kayıt ekranı günlük yazımı ölçüyor ve
        // klavyenin bir tuşunu ölçüm dışı bırakmak, ölçtüğü şeyi kullanıcının
        // gerçekte kullandığı klavyeden ayırırdı.
        keyboardView.onPeriodLongPress = { [weak self] in self?.handle(.symbol(",")) }
        keyboardView.onKeyRepeat = { [weak self] hit, stage in self?.handleRepeat(hit, stage) }
        keyboardView.onTouchRecord = { [weak self] r in self?.record(r) }
        view.addSubview(keyboardView)

        // Katmanlara `cgColor` yazıldığı için dinamik renk çözülmüyor; kip
        // değişimi açıkça dinleniyor. Ekranın kendisi de klavyenin kipine
        // geçiyor: koyu klavyeyi beyaz bir sayfanın üstünde yazmak, "günlük
        // kullandığın klavyede ölç" amacını yine bozardı.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (vc: RecorderViewController, _: UITraitCollection) in vc.applyTheme()
        }
        applyTheme()

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            promptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            promptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            progressLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            progressLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            typedLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 14),
            typedLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            typedLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            logLabel.topAnchor.constraint(equalTo: typedLabel.bottomAnchor, constant: 14),
            logLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            logLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            statusLabel.bottomAnchor.constraint(equalTo: suggestionStack.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            suggestionStack.bottomAnchor.constraint(equalTo: keyboardView.topAnchor, constant: -6),
            suggestionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            suggestionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            suggestionStack.heightAnchor.constraint(equalToConstant: 44),

            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            keyboardView.heightAnchor.constraint(
                equalToConstant: KeyboardView.height(for: settings.metrics)),
        ])
        refresh()
    }

    // MARK: - Dokunma kaydı

    private func record(_ r: KeyboardView.TouchRecord) {
        guard let engine, failure == nil else { return }
        var t = CanonicalSession.Touch(
            touchID: r.touchID,
            phase: .init(rawValue: r.phase.rawValue) ?? .ended,
            outcome: .init(rawValue: r.outcome.rawValue) ?? .pending,
            rawX: r.raw.x, rawY: r.raw.y,
            normX: r.normalized?.x, normY: r.normalized?.y,
            decoderX: nil, decoderY: nil,
            timestamp: r.timestamp,
            majorRadius: r.majorRadius, majorRadiusTolerance: r.majorRadiusTolerance,
            plane: String(describing: r.plane),
            shift: shift.isUppercase ? (shift.mode == .locked ? "locked" : "shifted") : "off",
            hitKind: nil, key: nil, keyIndex: nil)

        switch r.hit {
        case let .letter(index, point):
            t.hitKind = "letter"
            t.key = String(layout.keys[index].char)
            t.keyIndex = index
            // Decoder'a **fiilen verilen** nokta. Ham noktayla aynı olmayabilir
            // (normalizasyon bounds origin'ini de çıkarıyor) ve replay'in
            // birebir eşleşmesi için gereken bu değerdir.
            t.decoderX = point.x
            t.decoderY = point.y
        // Üst sayı sırası ve sembol düzlemi kayıtta **aynı tür**: ikisi de
        // doğrudan yazım, ikisi de `insertSymbol`'e gidiyor, ikisinin de
        // uzamsal kanıtı kod çözmeye girmiyor. Ayrı yüzey oldukları `plane`
        // alanından okunuyor — sayı sırası harf düzleminde de basılabiliyor.
        case let .symbol(ch), let .digit(ch):
            t.hitKind = "symbol"; t.key = String(ch)
        case let .function(fk):
            t.hitKind = "function"; t.key = String(describing: fk)
        case nil:
            break
        }
        do { try engine.record(t) } catch { fail("dokunma yazılamadı: \(error)") }
        if r.phase == .ended || r.phase == .cancelled {
            lastTouchID = r.touchID
            lastTouchTimestamp = r.timestamp
        }
    }

    // MARK: - Tuş işleme

    private func handle(_ hit: KeyboardView.KeyHit) {
        guard let engine, failure == nil, engine.phase == .recording else { return }
        let now = Self.clock

        switch hit {
        case let .letter(index, point):
            let ch = layout.keys[index].char
            let shifted = shift.isUppercase
            // Harf, **tüketilmemiş terminal dokunma kimliği** taşıyan bir
            // zarfla gidiyor: "son dokunmaya" örtük bağlanmak iki parmak üst
            // üste bindiğinde harfi yanlış dokunmaya bağlıyordu.
            perform(.init(command: .letter(baseKey: String(ch),
                                           display: shifted
                                            ? TurkishText.uppercased(ch)
                                            : String(ch),
                                           shifted: shifted),
                          touchID: lastTouchID,
                          // Kayıttaki zaman damgasının **aynısı** decoder'a
                          // gidiyor; iki farklı saat `τ_fast` yakınında
                          // insertion sınıfını değiştirebiliyordu.
                          timestamp: lastTouchTimestamp ?? now))
            keyLog.append(shifted ? "⇧" + String(ch) : String(ch))
            shift.didEmitLetter()
            _ = point

        case let .symbol(ch), let .digit(ch):
            perform(.init(command: .symbol(String(ch)), timestamp: now))
            keyLog.append(String(ch))
            shift.didInterruptChain()

        case let .function(fk):
            switch fk {
            case .space:
                // Düzeltmenin bastırılması artık **politikadan** geliyor:
                // `calibrationReplay` koşulunda motor `fieldProtectsLiteral`
                // uyguluyor. VC'nin ayrıca karar vermesi, kaydedilen politika
                // ile uygulananın ayrışmasına açık kapı bırakıyordu.
                perform(.init(command: .space, timestamp: now))
                keyLog.append("␣")
                shift.didInterruptChain()
            case .backspace:
                perform(.init(command: .backspaceTap, timestamp: now))
                keyLog.append("⌫")
                shift.didInterruptChain()
            case .ret:
                perform(.init(command: .newline, timestamp: now))
                keyLog.append("⏎")
            case .shift:
                shift.tapShift(at: CACurrentMediaTime())
                perform(.init(command: .shift(shift.isUppercase
                                                ? (shift.mode == .locked
                                                    ? "locked" : "shifted")
                                                : "off"),
                              timestamp: now))
                keyLog.append("⇧")
            case .numbers:
                keyboardView.plane = .numbers; shift.didInterruptChain()
                perform(.init(command: .planeChange("numbers"), timestamp: now))
            case .symbols:
                keyboardView.plane = .symbols; shift.didInterruptChain()
                perform(.init(command: .planeChange("symbols"), timestamp: now))
            case .letters:
                keyboardView.plane = .letters; shift.didInterruptChain()
                perform(.init(command: .planeChange("letters"), timestamp: now))
            case .globe:
                break

            // Nokta sembol komutu olarak kaydediliyor: kayıt **ne yazıldığını**
            // tutuyor, hangi tuşun hangi düzlemde durduğunu değil. `123`'ten
            // yazılan nokta ile buradan yazılan aynı komutu üretmeli, yoksa
            // replay iki farklı yol görürdü.
            case .period:
                handle(.symbol("."))
            }
        }
        syncKeyboardState()
        refresh()
    }

    /// Tek mutasyon noktası — belge, motor ve günlük **birlikte** ilerliyor.
    private func perform(_ envelope: RecordingEngine.CommandEnvelope) {
        guard let engine else { return }
        do { try engine.perform(envelope, into: self) }
        catch { fail("eylem yazılamadı: \(error)") }
    }

    private func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit,
              let engine, failure == nil, engine.phase == .recording else { return }
        // Kademe kayda **ayrı** yazılıyor: kelime silmede tüm bekleyen
        // dokunmalar düşüyor, tek dokunma düşürmek kalanları bir sonraki
        // token'a taşırdı.
        let command: ReplayCommand = stage == .character
            ? .backspaceRepeat : .deleteWord
        perform(.init(command: command, timestamp: Self.clock))
        keyLog.append("⌫·")
        refresh()
    }

    @objc private func pickSuggestion(_ sender: UIButton) {
        guard let engine, failure == nil, engine.phase == .recording,
              let word = sender.title(for: .normal), !word.isEmpty else { return }
        // Kimlik ve kaynak **motordan**: burada `id = yüzey`,
        // `origin = .candidate` uydurmak, `slm → selam` genişletmesini aday
        // seçimi diye kaydetmek oluyordu. Metin doğru çıktığı için hiçbir test
        // görmüyordu.
        guard let picked = engine.visibleSuggestions()
                .first(where: { $0.surface == word }) else { return }
        perform(.init(command: .suggestionPick(id: picked.id,
                                               surface: picked.surface,
                                               origin: picked.origin),
                      timestamp: Self.clock))
        keyLog.append("[\(word)]")
        refresh()
    }

    /// Log satırını karaktersizleştirir: olay türü görünür, ne yazıldığı değil.
    private static func anonymize(_ entry: String) -> String {
        switch entry {
        case "␣", "⌫", "⌫·", "⏎", "⇧": return entry
        default: return entry.hasPrefix("[") ? "[öneri]" : "·"
        }
    }

    private func syncKeyboardState() {
        keyboardView.isUppercase = shift.isUppercase
        keyboardView.isShiftLocked = shift.mode == .locked
    }

    // MARK: - Çizim

    private func refresh() {
        switch condition {
        case .calibrationReplay:
            // Hedef **kelime kelime**: hangi dokunmanın hangi kelimeye ait
            // olduğu böylece bir çıkarım değil, UI durumunun kaydı oluyor.
            promptLabel.text = wordIndex < promptTokens.count
                ? promptTokens[wordIndex] : "— bitti —"
            progressLabel.text = "\(min(wordIndex + 1, promptTokens.count))/\(promptTokens.count)"
                + " · yazıp boşluğa bas · yazdığın GÖRÜNMÜYOR (bilerek)"
            // Yazılan metin gizli: kullanıcı kendi hatasını görürse düzeltmeye
            // çalışır ve düzeltme sonrası harfler daha dikkatli basılır.
            typedLabel.text = String(repeating: "•",
                                     count: engine?.composingLength ?? 0)
        case .behavior:
            promptLabel.text = prompt.text
            progressLabel.text = "kelime \(min(wordIndex + 1, promptTokens.count))/\(promptTokens.count)"
            typedLabel.text = buffer
            let s = (engine?.visibleSuggestions() ?? []).map(\.surface)
            for (i, b) in suggestionStack.arrangedSubviews.enumerated() {
                let btn = b as? UIButton
                btn?.setTitle(i < s.count ? s[i] : "", for: .normal)
                btn?.isHidden = i >= s.count
            }
        }
        // Kalibrasyon kipinde log **karakter göstermez**.
        //
        // `typedLabel` maskeliydi ama `keyLog` gerçek harfleri ekrana basıyordu;
        // yani "yazılan metin gizli" protokolü fiilen bozuluyordu ve kullanıcı
        // hatasını görüp düzeltmeye çalışabiliyordu. Codex turunda yakalandı.
        logLabel.text = condition == .calibrationReplay
            ? "\(keyLog.count) tuş · son olaylar: "
                + keyLog.suffix(20).map(Self.anonymize).joined(separator: " ")
            : keyLog.suffix(60).joined(separator: " ")
    }
}

// MARK: - Belge tamponu

extension RecorderViewController: DocumentEditor {
    func insertText(_ text: String) { buffer += text }
    func deleteBackward() { if !buffer.isEmpty { buffer.removeLast() } }
    var contextBeforeInput: String? { buffer }
    var contextAfterInput: String? { "" }
    /// Kayıt ekranında seçim yok — host yok, imleç daima sonda.
    var selectedText: String? { nil }
}

// MARK: - SwiftUI sarmalayıcı

/// SwiftUI çubuğunun VC'ye uzanan tutamağı.
///
/// Ekranı kapatan iki eylem (`Vazgeç`, `Kaydet`) motorun sahibi olan VC'de
/// yaşıyor ve orada kalmalı: terminal frame'i yazan, dosyayı kapatan ve
/// tamamlanma koşulunu ölçen o. Çubuğun SwiftUI'da olması gerekiyor çünkü
/// `NavigationStack` sarmalanan VC'nin `navigationItem`'ını okumuyor.
@MainActor
final class RecorderHandle: ObservableObject {
    fileprivate weak var controller: RecorderViewController?

    /// Kullanıcı kapatmak istedi; **not sorulacak**.
    ///
    /// Kapatma iki adım: önce niyet, sonra not. Notu terminalden sonra yazmak
    /// mümkün değil (append-only günlükte terminal son frame), dolayısıyla
    /// deneme not alınana kadar açık kalıyor.
    @Published fileprivate(set) var pendingReason: RecordingEngine.TerminalReason?

    func requestAbort() { pendingReason = .aborted }
    func requestComplete() { pendingReason = .completed }

    /// Not alındı — deneme şimdi kapanıyor.
    func confirm(note: String) {
        guard let reason = pendingReason else { return }
        pendingReason = nil
        switch reason {
        case .aborted:  controller?.abort(note: note)
        case .completed: controller?.complete(note: note)
        case .invalid, .interrupted, .captured: break
        }
    }
}

struct RecorderView: UIViewControllerRepresentable {
    let prompt: PromptCorpus.Prompt
    let condition: CanonicalSession.Condition
    let posture: CanonicalSession.Posture
    let participantID: String
    let sessionOrdinal: Int
    let onFinish: () -> Void
    let handle: RecorderHandle

    func makeUIViewController(context: Context) -> RecorderViewController {
        let vc = RecorderViewController(
            prompt: prompt, condition: condition, posture: posture,
            participantID: participantID, sessionOrdinal: sessionOrdinal,
            onFinish: onFinish)
        handle.controller = vc
        return vc
    }
    func updateUIViewController(_ vc: RecorderViewController, context: Context) {}
}

/// Kayıt ekranı ve **çubuğu**.
///
/// Tutamak burada `@StateObject`: her sunum kendi tutamağını alıyor, yoksa
/// ikinci bir kayıt ilkinin VC'sine bağlı kalırdı.
struct RecorderScreen: View {
    let prompt: PromptCorpus.Prompt
    let condition: CanonicalSession.Condition
    let posture: CanonicalSession.Posture
    let participantID: String
    let sessionOrdinal: Int
    let onFinish: () -> Void

    @StateObject private var handle = RecorderHandle()
    @State private var note = ""

    var body: some View {
        RecorderView(prompt: prompt, condition: condition, posture: posture,
                     participantID: participantID,
                     sessionOrdinal: sessionOrdinal,
                     onFinish: onFinish, handle: handle)
            .ignoresSafeArea(.keyboard)
            .navigationTitle(condition == .calibrationReplay
                             ? "Kalibrasyon kaydı" : "Davranış kaydı")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { handle.requestAbort() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Tamamlanma koşulunu **motor** ölçüyor; düğme yalnız
                    // niyeti bildiriyor.
                    Button("Kaydet") { handle.requestComplete() }.bold()
                }
            }
            // Not **kapatmadan önce** alınıyor: append-only günlükte terminal
            // son frame ve sonrasına yazılamıyor.
            .sheet(isPresented: .init(get: { handle.pendingReason != nil },
                                      set: { if !$0 { handle.confirm(note: note) } })) {
                RecordingNoteSheet(note: $note) { handle.confirm(note: note) }
                    .interactiveDismissDisabled()
            }
    }
}

// MARK: - Liste ekranı

/// Kayıt oturumlarının listesi — §12'nin 3 adımının birincisi.
///
/// Abort oranı burada **görünür**: yalnız tamamlananları göstermek, kullanıcıya
/// da analize de tarafsız bir popülasyon varmış izlenimi verirdi (§12.6).
struct RecordingListView: View {
    /// Kayıtlar **tek okuyucudan** geliyor: eski `*.json` ve yeni `.bkj`
    /// birlikte listeleniyor. Yalnız birine bakmak, kullanıcının topladığı
    /// verinin yarısını görünmez yapardı.
    @State private var entries: [RecordingLibrary.Entry] = []
    /// Okunamayan dosyalar — **gizlenmiyor**. Sessizce atlamak bozuk bir kaydı
    /// hiç var olmamış gibi gösterip abort oranını bozardı.
    @State private var failures: [RecordingLibrary.Failure] = []
    @State private var showingNew = false
    @State private var active: ActiveRecording?
    @State private var confirmDeleteAll = false
    /// Notu düzenlenen kayıt.
    @State private var annotating: RecordingLibrary.Entry?
    @State private var annotationText = ""


    private struct ActiveRecording: Identifiable {
        let id = UUID()
        let prompt: PromptCorpus.Prompt
        let condition: CanonicalSession.Condition
        let posture: CanonicalSession.Posture
        let ordinal: Int
    }

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("Henüz kayıt yok. Sağ üstteki + ile başla.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.url) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.session.promptText).lineLimit(1)
                            Spacer()
                            Text(statusMark(entry.session.status))
                                .foregroundStyle(color(entry.session.status))
                        }
                        Text(summary(entry))
                            .font(.caption).foregroundStyle(.secondary)
                        // Not **listede görünüyor**: kayda girip görünmeyen bir
                        // şey, yazmaya değmediği izlenimi verirdi.
                        if let note = entry.session.note {
                            Text(note).font(.caption).italic()
                                .foregroundStyle(.orange).lineLimit(3)
                        }
                        // **Sonradan** eklenen not ayrı renkte: "o an mı yazdı,
                        // sonradan mı" sorusu listede de cevaplı kalıyor.
                        if let a = entry.annotation {
                            Text(a).font(.caption).italic()
                                .foregroundStyle(.blue).lineLimit(3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { annotating = entry }
                }
                .onDelete { idx in
                    for i in idx { try? RecordingLibrary.delete(entries[i]) }
                    reload()
                }
                ForEach(failures, id: \.url) { f in
                    Text("okunamadı: \(f.description)")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Kayıtlar — \(completedCount)/\(entries.count) tamamlandı")
            } footer: {
                Text("Vazgeçilen denemeler de kayıtta kalır: yalnız tamamlananları "
                     + "saklamak seçim yanlılığı üretir (§12.6).")
            }

            Section {
                let done = completedPromptIDs
                Text("\(done.count)/\(PromptCorpus.all.count) prompt tamamlandı")
                    .font(.caption)
                let missing = collectedUnderCovered
                if missing.isEmpty && !done.isEmpty {
                    Text("Toplanan veride her tuş eşiği geçti.")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    // §12.10: bitiş ölçütü ÖLÇÜLÜR, tahmin edilmez. Önceki
                    // sürüm korpusun statik potansiyelini gösteriyordu —
                    // toplanan veriyle ilgisi yoktu.
                    Text("Toplanan veride eşiğin (20) altında: "
                         + (missing.isEmpty ? "—" : missing.map(String.init).joined(separator: " ")))
                        .font(.caption)
                }
                Text("q, w, x Türkçede yok; eşiği hiç geçmeyecekler ve kendi "
                     + "katmanları açılmayacak (satır/global katmandan beslenirler).")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("Toplama ilerlemesi (§12.10)")
            }

            Section {
                Button("Tüm kayıtları sil", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("Kayıtlar ham dokunma koordinatı içerir ve kişisel veridir; "
                     + "yedeğe gitmez, cihaz kilitliyken korunur (§12.9).")
            }
        }
        .navigationTitle("Yazım kayıtları")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewRecordingSheet(suggested: nextUnrecorded) { prompt, condition, posture in
                showingNew = false
                active = ActiveRecording(prompt: prompt, condition: condition,
                                         posture: posture, ordinal: RecordingIdentity.nextOrdinal())
            }
        }
        .fullScreenCover(item: $active) { rec in
            NavigationStack {
                RecorderScreen(prompt: rec.prompt, condition: rec.condition,
                               posture: rec.posture,
                               participantID: RecordingIdentity.participantID,
                               sessionOrdinal: rec.ordinal) {
                    active = nil
                    reload()
                }
            }
        }
        .sheet(item: $annotating) { entry in
            RecordingNoteSheet(note: $annotationText) {
                try? RecordingLibrary.setAnnotation(annotationText, for: entry)
                annotating = nil
                reload()
            }
            .onAppear { annotationText = entry.annotation ?? "" }
        }
        .alert("Tüm kayıtlar silinsin mi?", isPresented: $confirmDeleteAll) {
            Button("Sil", role: .destructive) { try? RecordingLibrary.deleteAll(); reload() }
            Button("Vazgeç", role: .cancel) {}
        }
        .onAppear {
            // Çökme sonrası yarım kalanlar burada kapanır.
            // Yarım kalmış kayıtlar **işaretlenmiyor**: append-only bir
            // günlükte dosyayı yerinde değiştirmek mümkün değil ve olmamalı da.
            // Liste onları `recording` olarak gösteriyor — dürüst olan bu.
            reload()
        }
    }

    /// Kuyruk eksikliği **görünür**: güç kaybında kaybolan bir action'ı
    /// gizlemek, kaydı olduğundan sağlam göstermek olurdu.
    private func summary(_ e: RecordingLibrary.Entry) -> String {
        let s = e.session
        return "\(s.condition.rawValue) · \(s.split) · "
            + "\(s.touches.count) dokunma · \(s.actions.count) eylem"
            + (e.truncatedTail ? " · kuyruk eksik" : "")
    }

    private var completedCount: Int {
        entries.filter { $0.session.status == .completed }.count
    }
    /// Kurtarma **okumadan önce** koşuyor.
    ///
    /// Uygulama arka planda öldürüldüğünde terminal frame hiç yazılmıyor ve
    /// kayıt sonsuza dek `recording` kalıyor: ne tamamlanmış ne vazgeçilmiş
    /// sayılabiliyor, yani §12.6'nın vazgeçme oranı onu hangi kovaya koyacağını
    /// söyleyemiyor. Cihazda tam olarak bu gözlendi.
    ///
    /// `finalText` uydurulmuyor: mutasyon zincirinden türetiliyor ve zincir her
    /// adımda kendi özetini tutturuyor. Türetilemiyorsa kayıt **kapatılmıyor** ve
    /// sebebi listede görünüyor.
    private func reload() {
        let recovery = RecordingRecovery.closeStale(in: RecordingLibrary.directory)
        let listing = RecordingLibrary.list()
        entries = listing.entries
        // Kapatılamayan kayıtlar da okunamayanlarla aynı yerde görünüyor:
        // sessizce `recording` kalan bir deneme sayılamaz bir veri noktası.
        failures = listing.failures + recovery.skipped.map {
            .init(url: $0.url, reason: "kapatılamadı: \($0.reason)")
        }
    }

    /// Tamamlanmış denemelerin prompt kimlikleri.
    private var completedPromptIDs: Set<String> {
        Set(entries.map(\.session).filter { $0.status == .completed }.map(\.promptID))
    }

    /// **Toplanan** veride eşiğin altında kalan tuşlar.
    private var collectedUnderCovered: [Character] {
        let layout = TurkishQ.layout()
        var counts: [Int: Int] = [:]
        for e in entries where e.session.status == .completed {
            for smp in CalibrationExtraction.extract(e.session, layout: layout).samples {
                counts[smp.keyIndex, default: 0] += 1
            }
        }
        return layout.keys.indices
            .filter { (counts[$0] ?? 0) < HierarchicalCalibration.minKeySamples }
            .map { layout.keys[$0].char }
    }

    /// Sıradaki **kayıtsız** prompt — manifest sırasıyla (§12.10).
    ///
    /// Varsayılan `all[0]` idi; kullanıcı farkında olmadan aynı prompt'u
    /// tekrar tekrar yazabiliyordu ve eksik ancak import'ta anlaşılıyordu.
    var nextUnrecorded: PromptCorpus.Prompt {
        let done = completedPromptIDs
        return PromptCorpus.all.first { !done.contains($0.id) } ?? PromptCorpus.all[0]
    }

    private func statusMark(_ s: CanonicalSession.Status) -> String {
        switch s {
        case .completed: return "tamam"
        case .aborted: return "vazgeçildi"
        case .interrupted: return "kesildi"
        case .invalid: return "geçersiz"
        // Üretimde saklanan dilim: hedef yok, tamamlanma ölçülmüyor.
        case .captured: return "yakalandı"
        // Yarım kalmış kayıt **işaretlenmiyor**, olduğu gibi gösteriliyor:
        // append-only bir günlükte dosyayı yerinde değiştirmek mümkün değil
        // ve kurtarma kararı zaman/bağlam gerektiriyor.
        case .recording: return "yarım"
        }
    }
    private func color(_ s: CanonicalSession.Status) -> Color {
        s == .completed ? .green : (s == .invalid ? .red : .orange)
    }
}

/// Yeni kayıt — §12'nin 2. adımı: koşul, duruş ve hedef seçimi.
struct NewRecordingSheet: View {
    /// Manifest sırasındaki ilk kayıtsız prompt.
    let suggested: PromptCorpus.Prompt
    let onStart: (PromptCorpus.Prompt, CanonicalSession.Condition, CanonicalSession.Posture) -> Void

    @State private var condition: CanonicalSession.Condition = .calibrationReplay
    @State private var hands: CanonicalSession.Posture.Hands = .twoThumbs
    @State private var mobility: CanonicalSession.Posture.Mobility = .seated
    @State private var useManual = false
    @State private var manualText = ""
    @State private var selected: PromptCorpus.Prompt?
    @Environment(\.dismiss) private var dismiss

    private var unsupported: [Character] {
        PromptCorpus.unsupportedCharacters(in: manualText, layout: TurkishQ.layout())
    }

    /// Hedefte **yazılabilir harf** var mı.
    ///
    /// `unsupported` yetmiyordu: sembol ve rakamlar "yazılabilir" sayıldığı için
    /// `---` o kapıdan geçiyor, ama tokenizer boş dizi üretiyor.
    private var manualIsTypable: Bool {
        PromptTokenizer(layout: TurkishQ.layout()).isTypable(manualText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Koşul", selection: $condition) {
                        Text("Kalibrasyon").tag(CanonicalSession.Condition.calibrationReplay)
                        Text("Davranış").tag(CanonicalSession.Condition.behavior)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(condition == .calibrationReplay
                         ? "Hedef kelime kelime gelir, yazdığın GÖRÜNMEZ ve düzeltme "
                           + "uygulanmaz. Kendi hatanı göremediğin için düzeltmeye "
                           + "çalışmazsın — dokunma dağılımı temiz kalır."
                         : "Gerçek klavye: öneriler dokunulabilir, düzeltme uygulanır. "
                           + "Karar davranışını ölçmek için.")
                }

                Section("Duruş") {
                    Picker("El", selection: $hands) {
                        Text("İki başparmak").tag(CanonicalSession.Posture.Hands.twoThumbs)
                        Text("Tek başparmak").tag(CanonicalSession.Posture.Hands.oneThumb)
                        Text("İşaret parmağı").tag(CanonicalSession.Posture.Hands.indexFinger)
                    }
                    Picker("Hareket", selection: $mobility) {
                        Text("Otururken").tag(CanonicalSession.Posture.Mobility.seated)
                        Text("Ayakta").tag(CanonicalSession.Posture.Mobility.standing)
                        Text("Yürürken").tag(CanonicalSession.Posture.Mobility.walking)
                    }
                }

                Section("Hedef") {
                    Toggle("Kendi cümlemi yazayım", isOn: $useManual)
                    if useManual {
                        TextField("hedef cümle", text: $manualText, axis: .vertical)
                            .lineLimit(2...5)
                            .autocorrectionDisabled()
                        if !unsupported.isEmpty {
                            Text("Bu klavyede yazılamayan karakter: "
                                 + unsupported.map(String.init).joined(separator: " "))
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Picker("Cümle", selection: Binding(
                            get: { selected ?? suggested },
                            set: { selected = $0 })) {
                            ForEach(PromptCorpus.all) { p in
                                Text("\(p.id) · \(p.text)").tag(p)
                            }
                        }
                        Text("Öneri: \(suggested.id) — manifest sırasındaki ilk "
                             + "kayıtsız prompt. Aynı prompt'u tekrar yazmak ezber "
                             + "yanlılığı üretir (§12.10).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Yeni kayıt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Başla") {
                        let p = useManual
                            ? PromptCorpus.Prompt(id: "manual-\(UUID().uuidString.prefix(4))",
                                                  text: manualText.trimmingCharacters(in: .whitespaces),
                                                  split: .dev)
                            : (selected ?? suggested)
                        onStart(p, condition,
                                .init(hands: hands, mobility: mobility))
                    }
                    // **Yazılabilir harf yoksa deneme başlamıyor** (§2.3):
                    // `---` gibi bir hedefte tokenizer boş dizi veriyor ve
                    // tamamlanma koşulu (`cursor == 0 == hedef sayısı`) daha
                    // başlamadan sağlanıyor — deneme hiçbir şey ölçmeden
                    // `completed` oluyordu.
                    .disabled(useManual && (manualText.trimmingCharacters(in: .whitespaces).isEmpty
                                            || !unsupported.isEmpty
                                            || !manualIsTypable))
                }
            }
        }
    }
}
