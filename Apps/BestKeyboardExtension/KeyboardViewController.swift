import UIKit
import CoreText
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions

/// Klavye uzantısı — **ince adaptör**.
///
/// Karar mantığının tamamı `KBRuntime.InputCoordinator`'da: commit kararı
/// (`Δ > θ`), kalibrasyon öğrenmesi, dil durumu, seçim kipi. Burada kalanlar
/// yalnız UIKit'e ait olanlar — görünüm, dokunma, yaşam döngüsü, dosya sistemi.
///
/// Ayrım test edilebilirlik içindi: `UIInputViewController` içindeki hiçbir şey
/// `swift test` altında koşmuyor, dolayısıyla uçtan uca doğrulama yazılamıyordu.
final class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var suggestionBar: SuggestionBar!
    private var settingsPanel: KeyboardSettingsPanel?
    private var keyboardHeight: NSLayoutConstraint!

    /// Bir **harf satırının** yüksekliği: 4 satırlık klavyenin 216 pt'si.
    /// Sayı sırası açılınca ya da boşluk satırı uzayınca klavye **büyür**;
    /// satırları sıkıştırmak tuş merkezlerini birbirine yaklaştırıp uzamsal
    /// ayrımı zayıflatırdı (`KeyboardMetrics.heightUnits`).
    private static let rowHeightPoints: CGFloat = 54

    private var settings: KeyboardSettings
    private var layout: KeyLayout
    /// **Motor koordinatörü sahipleniyor.**
    ///
    /// Uzantı önce `InputCoordinator`'ı doğrudan tutuyordu; o zaman kaydın
    /// görmediği bir mutasyon her zaman mümkündü. Kayıt ekranı bu yüzden
    /// `RecordingEngine`'e geçmişti, üretim yolu geride kalmıştı.
    ///
    /// `nil` = paketler henüz yüklenmedi. O aralıkta tuşlar bekliyor: motoru
    /// kurulmadan sürmek, hangi konfigürasyonla yazıldığı bilinmeyen bir
    /// eylem üretirdi.
    private var recorder: ProductionRecorder?
    /// Kısayol — motorun kendisi.
    private var input: RecordingEngine? { recorder?.engine }

    /// **Kayıt yokken bile yazabilmek için** yedek koordinatör.
    ///
    /// Paket yüklemesi başarısız olursa (bozuk kurulum, disk hatası) klavye
    /// kayıt tutamaz — ama yazmaya devam etmek **zorunda**: bu kullanıcının
    /// günlük klavyesi. Motorsuz `InputCoordinator` literal yazıyor, öneri
    /// vermiyor; eski davranışın aynısı.
    ///
    /// Bu ikinci yol yalnız **bozulmuş** durumda koşuyor. Normalde
    /// `recorder != nil` ve tek mutasyon noktası motorda.
    private var fallback = InputCoordinator(layout: TurkishQ.layout())
    /// Shift durum makinesi — çift dokunuşla kilit, harften sonra düşme,
    /// cümle başı otomatiği. Politika `KBRuntime`'da, burada yalnız bağlanıyor.
    private var shift = ShiftPolicy()

    override init(nibName: String?, bundle: Bundle?) {
        let s = KeyboardSettingsStore.load()
        // Layout ve koordinatör **aynı** ölçüden kuruluyor: decoder'ın uzamsal
        // modeli ile çizilen geometri ayrışamaz.
        let l = TurkishQ.layout(metrics: s.metrics)
        self.settings = s
        self.layout = l
        super.init(nibName: nibName, bundle: bundle)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Kendi düzenlemelerimiz sırasında `textDidChange` gelir; o sırada host
    /// uzlaştırmasını çalıştırmak kendi ürettiğimiz ara hâllere bakmak olurdu.
    private var isEditingDocument = false

    private var loadReport = "yükleniyor…"

    /// Optimize edilmemiş derlemeyi **görünür** kılar.
    ///
    /// Gerekçe ölçülmüş bir hata: `deploy.sh` uzun süre varsayılan olarak Debug
    /// kuruyordu ve decoder saf Swift beam search olduğu için `-Onone` altında
    /// tuş başına p50 12.44 ms / p95 19.21 ms veriyordu — Release'te 0.95 /
    /// 1.41 ms. **13 kat**, ve sözleşmenin p99 < 8 ms bütçesini 2.4 kat aşıyor.
    /// Klavye "biraz yavaş" hissettiriyordu ama hiçbir yerde hangi derlemenin
    /// kurulu olduğu yazmıyordu; teşhis edilemeyen bir yavaşlık en pahalısı.
    private static let configurationTag: String = {
        #if DEBUG
        return "⚠︎DEBUG · "
        #else
        return ""
        #endif
    }()
    /// Seçili kelime düzenleniyorsa yüzeyi — durum satırı için.
    private var selectionNote: String?

    // MARK: Kalibrasyon kalıcılığı
    //
    // Depo **daima uzantı sandbox'ında**: Tam Erişim açılıp kapanabildiği için
    // iki yazılabilir depo split-brain üretir (plan §7). Tek yazar biziz.
    private var calibrationProfile: CalibrationStore.ProfileKey?
    /// Aktif token sürerken profil değişirse beklemeye alınır — eski geometride
    /// toplanan dokunmalar yeni profile yazılmamalı.
    private var pendingProfile: CalibrationStore.ProfileKey?

    private static var calibrationDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("calibration", isDirectory: true)
    }

    // MARK: - Yaşam döngüsü

    override func viewDidLoad() {
        super.viewDidLoad()

        suggestionBar = SuggestionBar()
        suggestionBar.onPick = { [weak self] word in self?.pick(word) }
        // Ayar girişi öneri çubuğunda: tuş ızgarasında ona ayıracak yer yok ve
        // uzun basmaya gizlemek keşfedilemez kılardı.
        suggestionBar.onSettings = { [weak self] in self?.toggleSettingsPanel() }
        suggestionBar.onCapture = { [weak self] in self?.captureSlice() }

        keyboardView = KeyboardView(layout: layout, metrics: settings.metrics)
        keyboardView.cadence = settings.cadence
        // Eylem `touchesEnded`'de kesinleşir (sürükleme/iptal karakter üretmez).
        keyboardView.onKeyCommit = { [weak self] hit in self?.handle(hit) }
        keyboardView.onKeyRepeat = { [weak self] hit, stage in self?.handleRepeat(hit, stage) }
        // Globe sözleşmesi: gösterim `needsInputModeSwitchKey`'e bağlı,
        // uzun basma sistem input-mode listesini açar.
        keyboardView.showsGlobeKey = needsInputModeSwitchKey
        keyboardView.onGlobeLongPress = { [weak self] view, event in
            self?.handleInputModeList(from: view, with: event ?? UIEvent())
        }

        for v in [suggestionBar as UIView, keyboardView as UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        keyboardHeight = keyboardView.heightAnchor.constraint(
            equalToConstant: Self.rowHeightPoints * CGFloat(settings.metrics.heightUnits))
        // Zorunlu değil (999): sayı sırası + uzun boşluk satırı en fazla
        // 5.75 satır istiyor ve dar bir yatay ekranda sistem bu kadar yer
        // vermeyebilir. Zorunlu bırakmak constraint kırılması demekti; 999 ile
        // kısıt esniyor ve klavye sığdığı kadarını alıyor.
        //
        // Geometri bundan zarar görmüyor: `KeyboardView` her şeyi **kendi
        // bounds'una** göre normalize ediyor, yani çizim ve dokunma hizalı
        // kalıyor — yalnız tuşlar kısalıyor.
        keyboardHeight.priority = .required - 1

        // Auto Layout yalnız kurulumda; yazma sırasında hiç çalışmaz.
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: view.topAnchor),
            suggestionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionBar.heightAnchor.constraint(equalToConstant: 44),

            keyboardView.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor),
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardHeight,
        ])

        // Katmanlara `cgColor` yazıldığı için dinamik renk çözülmüyor; kip
        // değişimini açıkça dinleyip temayı yeniden uyguluyoruz.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (vc: KeyboardViewController, _: UITraitCollection) in vc.applyTheme()
        }
        applyTheme()

        loadPackAsync()
        updateAutoCapitalization()
    }

    // MARK: - Tema ve ayarlar

    private var resolvedTheme: KeyboardTheme {
        settings.theme.resolved(for: traitCollection)
    }

    private func applyTheme() {
        let t = resolvedTheme
        keyboardView.theme = t
        suggestionBar.apply(theme: t)
        settingsPanel?.apply(theme: t)
    }

    private func toggleSettingsPanel() {
        if let p = settingsPanel {
            p.removeFromSuperview()
            settingsPanel = nil
            // Bekleyen ağır kurulum burada kesinleşiyor: panel kapanır kapanmaz
            // yazılabiliyor ve o an decoder yeni geometriyle kurulmuş olmalı.
            rebuildModel()
            return
        }
        // Panel klavyenin üstünü kaplıyor ama **zaten basılı** parmaklar
        // olaylarını almaya devam ediyor: ⌫'yi basılı tutarken ikinci parmakla
        // ⚙︎'ye basmak panelin arkasında silmeyi sürdürüyordu.
        keyboardView.cancelInteraction()
        // Yazılmakta olan token burada kapanıyor. Ayar geometriyi
        // değiştirebilir ve tampondaki dokunmalar eski normalize uzayda
        // kaydedilmiş olur; onları yeni tuş merkezlerine göre skorlamak
        // sistematik bir sapma uygulamak demekti.
        withOwnEdit { try? input?.invalidateComposing() }
        selectionNote = nil
        // Token kapandı: bekleyen profil geçişi ve kalibrasyon kaydı burada
        // karşılanmalı. Yoksa composition sırasında cihaz döndürülüp panel
        // açıldığında `pendingProfile` asılı kalıyor ve panelden sonraki ilk
        // kelime **eski** yönelimin kalibrasyonuyla işleniyordu.
        afterTokenBoundary()
        refreshUI()

        let p = KeyboardSettingsPanel(settings: settings,
                                      theme: resolvedTheme,
                                      showsGlobe: needsInputModeSwitchKey)
        p.onChange = { [weak self] s in self?.apply(settings: s) }
        p.onClose = { [weak self] in self?.toggleSettingsPanel() }
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: view.topAnchor),
            p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            p.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        settingsPanel = p
    }

    /// Ayar değişimi — sürgünün her tikinde çağrılıyor.
    ///
    /// Ucuz olan her şey (çizim, yükseklik, tema, zamanlama, kayıt) burada
    /// **anında**; pahalı olan (`KeyLayout` + `InputCoordinator` + decoder)
    /// `scheduleModelRebuild()` ile sürükleme durana kadar erteleniyor.
    ///
    /// Ağır yol yalnız **harf geometrisi** değişince gerekiyor. Boşluk
    /// genişliği harf merkezlerine dokunmuyor; onu da yeniden yükleme sayması,
    /// boşluğu bir kademe genişleten kullanıcının kalibrasyonunu çöpe atardı
    /// (`sharesLetterGeometry`).
    private func apply(settings new: KeyboardSettings) {
        let old = settings
        settings = new
        KeyboardSettingsStore.save(new)

        if new.theme != old.theme { applyTheme() }
        // Zamanlama geometri değil: ne kalibrasyon profili ne decoder etkilenir.
        if new.cadence != old.cadence { keyboardView.cadence = new.cadence }
        guard new.metrics != old.metrics else { return }

        keyboardHeight.constant = Self.rowHeightPoints * CGFloat(new.metrics.heightUnits)

        // Çizim **her zaman anında**: sürgüyü sürükleyen kullanıcı sonucu
        // gecikmeli görmemeli.
        keyboardView.apply(layout: layout, metrics: new.metrics)
        view.setNeedsLayout()

        guard !new.metrics.sharesLetterGeometry(with: old.metrics) else { return }
        scheduleModelRebuild()
    }

    // MARK: Ağır yeniden kurulum
    //
    // Harf geometrisi değişince `KeyLayout`, `InputCoordinator` ve decoder
    // yeniden kurulmalı: uzamsal model tuş merkezlerinden türüyor, eski
    // modelle yeni tuşlara basmak sistematik bir sapma demekti.
    //
    // Ama bu iş **sürgü tikine bağlanamaz**: 0.05 kademeyle shift'i baştan sona
    // sürüklemek 30 paket yüklemesi demek. Kuşak koruması doğruluğu sağlıyor
    // ama iptal edilemeyen o yüklemeler yine de tamamlanıyor — bellek
    // sınırlaması yüzünden öldürülmeye açık bir klavye uzantısında ödenecek
    // bedel değil. Sürükleme durunca bir kez yapılıyor.

    private var modelRebuild: Timer?
    private static let modelRebuildDelay: TimeInterval = 0.35

    private func scheduleModelRebuild() {
        modelRebuild?.invalidate()
        let t = Timer(timeInterval: Self.modelRebuildDelay, repeats: false) { [weak self] _ in
            self?.rebuildModel()
        }
        RunLoop.main.add(t, forMode: .common)
        modelRebuild = t
    }

    /// Bekleyen yeniden kurulumu hemen yapar; temizse hiçbir şey yapmaz.
    ///
    /// "Kirli" bilgisi **zamanlayıcıda tutulmuyor**: `layout.id` ile ayarın
    /// ürettiği kimliğin farkı zaten tam olarak o bilgi. Bayrağı zamanlayıcıya
    /// bağlamak bir delik açıyordu — klavye değişimden sonraki 350 ms içinde
    /// kapanırsa `viewWillDisappear` zamanlayıcıyı iptal ediyor ve bekleyen
    /// kurulum sessizce kayboluyordu; klavye geri geldiğinde görünüm yeni
    /// ölçüde, decoder eski geometride kalıyordu.
    private func rebuildModel() {
        modelRebuild?.invalidate()
        modelRebuild = nil
        guard layout.id != TurkishQ.layout(metrics: settings.metrics).id else { return }

        saveCalibration()          // eski profilin verisi kaybolmasın
        layout = TurkishQ.layout(metrics: settings.metrics)
        // Geometri değişti: **yeni bir deneme**. Tampondaki dokunmalar eski
        // normalize uzayda kaydedildi ve onları yeni tuş merkezleriyle aynı
        // kayda koymak, iki farklı klavyeyi tek dosyada anlatmak olurdu.
        recorder = nil
        loadPackAsync()
        keyboardView.apply(layout: layout, metrics: settings.metrics)
        // Profil anahtarı `layout.id`'yi taşıyor; geometri değişince
        // `refreshCalibrationProfile` yeni kovaya geçiyor. Yeni profil
        // `viewDidLayoutSubviews`'te kuruluyor: burada klavyenin yeni boyutu
        // henüz ölçülmedi ve profil anahtarı ölçüyü de taşıyor.
        calibrationProfile = nil
        pendingProfile = nil
        view.setNeedsLayout()
        loadPackAsync()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Kapanırken ertelenmiş bir kurulum kalmış olabilir; temizse no-op.
        rebuildModel()
        // Alan değişmiş olabilir: klavye her açılışta **yeniden** soruyor.
        dropBufferIfSecure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshCalibrationProfile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Yalnız zamanlayıcı iptal ediliyor; "kirli" bilgisi `layout.id`
        // farkında duruyor ve `viewWillAppear` onu topluyor.
        modelRebuild?.invalidate()
        modelRebuild = nil
        saveCalibration()          // biriken örnekler kaybolmasın
    }

    // MARK: - Paket yükleme

    /// Yükleme kuşağı. Ölçü değişimi yeni bir yükleme başlatıyor ve eskisi
    /// iptal edilemiyor; kuşak kontrolü olmadan **geç biten eski** yükleme,
    /// yeni geometriyle kurulmuş motoru eskisiyle eziyordu — çizilen tuşlarla
    /// skorlanan tuşlar ayrışırdı.
    private var loadGeneration = 0

    /// İki aşamalı init (§11.A): tuşlar önce çizilir ve anında yazılabilir;
    /// leksikon arka planda yüklenir, öneriler hazır olunca yanar.
    private func loadPackAsync() {
        loadGeneration += 1
        let generation = loadGeneration
        // Layout ana thread'de yakalanıyor: arka planda `self.layout` okumak
        // ayarla eşzamanlı değişimde veri yarışı olurdu.
        let layout = self.layout
        let bundle = Bundle(for: Self.self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let loaded = try PackLoader.load(layout: layout, bundle: bundle)
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    // Kanal yapılandırması `PackLoader` içinde — burada
                    // tekrarlanmıyor ki kayıt ekranıyla ayrışmasın.
                    self.startRecorder(with: loaded)
                    self.loadReport = loaded.report
                    // Profil layout sırasında, motordan ÖNCE kurulmuştu;
                    // kaydedilmiş kalibrasyon ancak burada uygulanabilir.
                    self.input?.applyCalibration()
                    self.refreshUI()
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    self.suggestionBar.setStatus("paket yüklenemedi: \(error)")
                }
            }
        }
    }

    // MARK: - Girdi

    private func handle(_ hit: KeyboardView.KeyHit) {
        switch hit {
        case let .letter(index, point):
            let ch = layout.keys[index].char
            // **Tek saat.** `CFAbsoluteTimeGetCurrent()` duvar saati;
            // `ProductionRecorder.now` (= `systemUptime`) `UITouch.timestamp`
            // ile aynı taban. İkisini karıştırmak kaydın zaman çizgisini çöpe
            // çeviriyordu — kayıt ekranında ölçülmüştü (`t = −806 576 468`) ve
            // uzantıya geçerken aynı hata tekrarlanmıştı.
            let t = TouchSample(down: point, timestamp: ProductionRecorder.now)
            selectionNote = nil
            // Dokunma **komuttan önce** kaydediliyor: harf zarfı onun kimliğine
            // atıf yapıyor.
            let id = nextTouchID; nextTouchID += 1
            lastFallbackPoint = point
            perform(touch: recordedTouch(id: id, index: index, point: point,
                                         at: t.timestamp),
                    command: .letter(baseKey: String(ch),
                                     display: shift.isUppercase
                                        ? InputCoordinator.uppercase(ch, locale: "tr")
                                        : String(ch),
                                     shifted: shift.isUppercase),
                    touchID: id, at: t.timestamp)
            shift.didEmitLetter()
            syncKeyboardState()

        // Rakam/sembol kod çözmeye girmez — üst sayı sırası da aynı yoldan
        // geçiyor, yalnız vurgusu ayrı bir katman kümesine gidiyor.
        case let .symbol(ch), let .digit(ch):
            selectionNote = nil
            perform(command: .symbol(String(ch)))
            shift.didInterruptChain()
            afterTokenBoundary()
            updateAutoCapitalization()

        case let .function(fk):
            switch fk {
            case .space:
                perform(command: .space)
                selectionNote = nil
                shift.didInterruptChain()
                afterTokenBoundary()
                updateAutoCapitalization()
            case .backspace:
                perform(command: .backspaceTap)
                shift.didInterruptChain()
                // Metin başına silmek ya da cümle sonlandırıcısını silmek
                // otomatik büyük harfi değiştirir; yeniden okunmalı.
                updateAutoCapitalization()
            case .ret:
                perform(command: .newline)
                selectionNote = nil
                afterTokenBoundary()
                updateAutoCapitalization()
            case .globe:
                advanceToNextInputMode()   // kısa dokunma; uzun basma view'da

            case .shift:
                shift.tapShift(at: CACurrentMediaTime())
                syncKeyboardState()

            // Düzlem geçişleri de çift dokunuş zincirini keser: hızlı
            // `shift → 123 → ABC → shift` yanlışlıkla caps-lock açardı.
            case .numbers:
                shift.didInterruptChain()
                keyboardView.plane = .numbers
            case .symbols:
                shift.didInterruptChain()
                keyboardView.plane = .symbols
            case .letters:
                shift.didInterruptChain()
                keyboardView.plane = .letters
                updateAutoCapitalization()
            }
        }
        refreshUI()
    }

    /// Basılı tutma tekrarı: önce karakter, uzun tutulursa kelime.
    private func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit else { return }
        withOwnEdit {
            switch stage {
            case .character: perform(command: .backspaceRepeat)
            case .word:      perform(command: .deleteWord)
            }
        }
        updateAutoCapitalization()
        refreshUI()
    }

    private func pick(_ word: String) {
        // Kimlik ve kaynak **motordan**: `id = yüzey` uydurmak genişletmeyi
        // aday seçimi diye kaydediyordu.
        guard let picked = input?.visibleSuggestions()
                .first(where: { $0.surface == word }) else { return }
        perform(command: .suggestionPick(id: picked.id, surface: picked.surface,
                                         origin: picked.origin))
        selectionNote = nil
        // Öneri seçimi de token'ı kapatıyor: boşluk yolundaki iki adım burada
        // da gerekli, yoksa cümle başındaki one-shot shift açık kalıp sonraki
        // kelimeyi de büyük başlatırdı.
        shift.didInterruptChain()
        afterTokenBoundary()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Alan türü literal'i koruyor mu (§8 `θ = ∞`).
    private var fieldProtectsLiteral: Bool {
        switch textDocumentProxy.keyboardType {
        case .some(.emailAddress), .some(.URL), .some(.numberPad), .some(.decimalPad):
            return true
        default:
            return false
        }
    }

    /// Shift durumunu görünüme yansıtır.
    private func syncKeyboardState() {
        keyboardView.isUppercase = shift.isUppercase
        keyboardView.isShiftLocked = shift.mode == .locked
    }

    /// Cümle/kelime başı otomatiği — **token sınırında**.
    ///
    /// Karar metinden okunuyor, sayaçtan değil: host metni bizim bilmediğimiz
    /// bir şekilde değiştirmiş olabilir (§8, tampon spekülatiftir).
    private func updateAutoCapitalization() {
        let type: ShiftPolicy.Autocapitalization
        switch textDocumentProxy.autocapitalizationType {
        case .some(.words):         type = .words
        case .some(.sentences):     type = .sentences
        case .some(.allCharacters): type = .allCharacters
        default:                    type = .none
        }
        shift.autoCapitalize(
            ShiftPolicy.shouldCapitalize(context: textDocumentProxy.documentContextBeforeInput,
                                         type: type))
        syncKeyboardState()
    }

    // MARK: - Üretim kaydı

    /// Kayıtların yazıldığı dizin — uzantının **kendi** konteyneri.
    ///
    /// Uygulamanınkiyle paylaşmak app group gerektiriyor, o da klavyeye
    /// "Full Access" verdirir (ağ erişimi + iOS'un uyarısı). Gerekmiyor:
    /// `devicectl` uzantının konteynerine erişebiliyor ve `pull-sessions.sh`
    /// oradan çekiyor.
    static var captureDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("typing-sessions", isDirectory: true)
    }

    /// Paketler geldi: kaydedici kuruluyor ve klavye yazmaya açılıyor.
    private func startRecorder(with loaded: PackLoader.Loaded) {
        let l = layout
        let m = settings.metrics
        do {
            recorder = try ProductionRecorder(
                makeDescriptor: { id in
                    Self.productionDescriptor(id: id, layout: l, metrics: m)
                },
                build: { writer in
                    RecordingEngine(writer: writer,
                                    coordinator: InputCoordinator(layout: l),
                                    layout: l)
                },
                configure: { engine in
                    try engine.configure(
                        loaded: loaded,
                        // Üretimde kalibrasyon **uygulanıyor** ama kayda
                        // `applied: false` yazmak yalan olurdu; gerçek durum
                        // aşağıda `applyCalibration` ile kuruluyor ve snapshot
                        // onu anlatıyor.
                        calibration: .init(applied: false, strongSamples: 0,
                                           biasX: [], biasY: [],
                                           hierarchical: .init(globalX: 0, globalY: 0,
                                                               rowX: [], rowY: [],
                                                               keyX: [], keyY: []),
                                           sigma: .known(.init(x: [], y: []))))
                },
                baseline: { [weak self] in
                    // Host'ta zaten duran metin: **fark** buradan hesaplanıyor,
                    // kayda girmiyor. Vermezsek kullanıcının bu dilimde
                    // yazmadığı içerik ilk mutasyona sızıyordu.
                    guard let self else { return "" }
                    return (self.textDocumentProxy.documentContextBeforeInput ?? "")
                        + (self.textDocumentProxy.documentContextAfterInput ?? "")
                })
            recorderFailure = nil
        } catch {
            recorder = nil
            recorderFailure = "\(error)"
        }
        // Yedek yol da **aynı** motoru ve geometriyi kullanıyor: bozulmuş
        // durumda bile klavye başka bir klavye olmamalı.
        fallback = InputCoordinator(layout: l)
        fallback.setEngine(.init(decoder: loaded.decoder,
                                 literalChannel: loaded.literalChannel,
                                 expansions: loaded.expansions))
    }

    /// Üretim denemesinin tanımı — **hedef yok**.
    ///
    /// `alignmentSource: .none`: kullanıcının ne yazmak istediğini yalnız kendisi
    /// biliyor ve o da nota yazıyor. `promptTokens` boş olamaz (§2.3), bu yüzden
    /// tek elemanlı bir yer tutucu; hizalama zaten `constructed` olmadığı için
    /// kalibrasyon kapısı bu kayıtları eliyor.
    private static func productionDescriptor(id: String, layout: KeyLayout,
                                             metrics: KeyboardMetrics)
        -> CanonicalSession {
        CanonicalSession(
            attemptID: id, participantID: "device", sessionOrdinal: 0,
            condition: .behavior, status: .recording,
            promptID: "production", promptText: "", promptSource: .manual,
            // **Hedef yok**, boş hedef değil: `.known(["-"])` yazmak olmayan
            // bir hedefi varmış gibi göstermek ve tokenizer kanonikliği
            // (§2.3) o yer tutucuyu haklı olarak reddediyordu.
            split: "none", promptTokens: .notApplicable,
            alignmentSource: .none, startedAt: Date(),
            engine: .unconfigured(
                buildConfiguration: Self.buildConfiguration,
                appVersion: Self.appVersion,
                build: .init(codeRevision: .unknown, provenance: .unknown),
                policy: .init(RecordingPolicy.behavior)),
            geometry: .init(layoutID: layout.id,
                            layoutFingerprint: .known(layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 0, boundsHeight: 0,
                            frameInScreenX: 0, frameInScreenY: 0,
                            frameInScreenWidth: 0, frameInScreenHeight: 0,
                            safeAreaBottom: 0, screenScale: UIScreen.main.scale,
                            interfaceOrientation: "portrait",
                            deviceModel: UIDevice.current.model,
                            systemVersion: UIDevice.current.systemVersion))
    }

    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
    static var appVersion: String {
        Bundle(for: KeyboardViewController.self)
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Kullanıcı düğmeye bastı: bellekteki dilim diske düşüyor.
    private func captureSlice() {
        // Güvenli alanda **hiçbir koşulda** yazılmıyor.
        guard !fieldIsSecure else {
            suggestionBar.setStatus("parola alanında kayıt yok")
            return
        }
        guard let recorder, let dir = Self.captureDirectory else {
            suggestionBar.setStatus("kayıt hazır değil")
            return
        }
        do {
            _ = try recorder.capture(note: nil, to: dir)
            suggestionBar.setStatus("kaydedildi ✓")
        } catch {
            suggestionBar.setStatus("kaydedilemedi: \(error)")
        }
    }

    // MARK: - Tek mutasyon noktası

    private var nextTouchID = 0

    /// Klavyenin **tek** belge mutasyon yolu.
    ///
    /// Motor kurulmadan hiçbir şey yapılmıyor: konfigürasyonu bilinmeyen bir
    /// eylem üretmek, kaydın hangi klavyeyi anlattığını söyleyememek demek.
    /// Alan **parola alanı** mı.
    ///
    /// Güvenli alanda hiçbir şey tamponlanmıyor: klavye orada yazılanı belleğe
    /// bile almamalı. Bu bir tercih değil — kayıt özelliğinin var olabilmesinin
    /// koşulu.
    ///
    /// `isSecureTextEntry` `Optional<Bool>`: host söylemiyorsa **güvenli
    /// varsayılıyor** değil, çünkü o zaman çoğu alanda kayıt hiç çalışmazdı.
    /// Söylenmediğinde normal alan sayılıyor; iOS parola alanlarında bunu
    /// bildiriyor.
    private var fieldIsSecure: Bool {
        textDocumentProxy.isSecureTextEntry == true
    }

    private func perform(touch: CanonicalSession.Touch? = nil,
                         command: ReplayCommand,
                         touchID: Int? = nil,
                         at time: TimeInterval? = nil) {
        guard let recorder, let engine = input else {
            // Kayıt yok ama klavye çalışmak zorunda.
            withOwnEdit { applyToFallback(command, at: time) }
            return
        }
        let t = time ?? ProductionRecorder.now
        withOwnEdit {
            do {
                if let touch { try engine.record(touch) }
                try engine.perform(.init(command: command, touchID: touchID,
                                         timestamp: t), into: self)
                // Sınıra **eylemden sonra** bakılıyor: ortasında devretmek yarım
                // bir mutasyonu iki denemeye bölerdi.
                try recorder.rollOverIfNeeded()
            } catch {
                // Kayıt bozulursa klavye çalışmaya devam etmeli: kullanıcının
                // günlük aracı bu. Kaydedici bırakılıyor, tampon atılıyor.
                self.recorder = nil
                self.recorderFailure = "\(error)"
            }
        }
    }

    private var recorderFailure: String?

    /// Yedek yolun komut uygulaması.
    ///
    /// Motorun `apply`'ıyla **aynı kümeyi** karşılıyor; ayrışırsa bozulmuş
    /// durumda klavye başka bir klavye olurdu.
    private func applyToFallback(_ command: ReplayCommand, at time: TimeInterval?) {
        switch command {
        case let .letter(baseKey, display, shifted):
            guard let ch = baseKey.first else { return }
            let sample = TouchSample(down: lastFallbackPoint,
                                     timestamp: time ?? ProductionRecorder.now)
            if shifted {
                fallback.insertUppercaseLetter(ch, uppercase: display,
                                               touch: sample, into: self)
            } else {
                fallback.insertLetter(ch, touch: sample, into: self)
            }
        case let .symbol(sym):
            if let ch = sym.first { fallback.insertSymbol(ch, into: self) }
        case .space:
            fallback.space(into: self, fieldProtectsLiteral: fieldProtectsLiteral)
        case .newline:        fallback.newline(into: self)
        case let .suggestionPick(_, surface, _):
            fallback.pickSuggestion(surface, into: self)
        case .backspaceTap:   fallback.backspaceTap(into: self)
        case .backspaceRepeat: fallback.backspaceRepeat(into: self)
        case .deleteWord:     fallback.deleteWord(into: self)
        case .planeChange, .shift: break
        }
    }

    /// Yedek yolda son dokunma noktası — uzamsal kanıt yine gerçek.
    private var lastFallbackPoint = Point(x: 0.5, y: 0.5)

    /// `withOwnEdit`'in değer döndüren hâli.
    private func withOwnEditResult<T>(_ body: () -> T) -> T {
        isEditingDocument = true
        defer { isEditingDocument = false }
        return body()
    }

    /// Kaydedilen dokunma — kayıt ekranındakiyle **aynı alanlar**.
    private func recordedTouch(id: Int, index: Int, point: Point,
                               at time: TimeInterval) -> CanonicalSession.Touch {
        .init(touchID: id, phase: .ended, outcome: .committed,
              rawX: point.x * Double(keyboardView.bounds.width),
              rawY: point.y * Double(keyboardView.bounds.height),
              normX: point.x, normY: point.y,
              decoderX: point.x, decoderY: point.y,
              timestamp: time, majorRadius: 0, majorRadiusTolerance: 0,
              plane: "letters",
              shift: shift.isUppercase
                ? (shift.mode == .locked ? "locked" : "shifted") : "off",
              hitKind: "letter", key: String(layout.keys[index].char),
              keyIndex: index)
    }

    private func withOwnEdit(_ body: () -> Void) {
        isEditingDocument = true
        body()
        isEditingDocument = false
    }

    // MARK: - Host uzlaştırması (§8)

    /// Alan değişti: güvenli alana girildiyse tampon **atılıyor**.
    ///
    /// Yalnız yazmayı durdurmak yetmezdi — o ana kadarki tampon bellekte
    /// kalırdı ve kullanıcı parola alanındayken düğmeye bassa diske düşerdi.
    private func dropBufferIfSecure() {
        guard fieldIsSecure, recorder != nil else { return }
        recorder = nil
        recorderFailure = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        dropBufferIfSecure()
        guard !isEditingDocument else { return }
        // §8.4: `selectionDidChange` HİÇ çağrılmıyor; seçim değişimi de dahil
        // her şey buradan geliyor. Ayrıca proxy bu anda henüz yeni durumu
        // yansıtmıyor — okuma bir run loop turu ertelenmeli.
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isEditingDocument else { return }
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    private func readSelection() {
        guard !isEditingDocument else { return }
        selectionNote = withOwnEditResult {
            try? input?.selectionChanged(textDocumentProxy.selectedText, into: self)
        } ?? nil
        afterTokenBoundary()
        // Host metni değiştirmiş ya da imleç taşınmış olabilir; "karar host
        // metninden okunur" garantisi ancak burada da okunursa geçerli.
        updateAutoCapitalization()
        refreshUI()
    }

    // MARK: - Görünüm

    private func refreshUI() {
        // Bozulmuş durumda da öneri gösteriliyor: boş çubuk "aday yok" demek
        // olurdu, oysa yalnız kayıt yok.
        suggestionBar.setCandidates(
            input?.suggestionSurfaces() ?? fallback.suggestionSurfaces())

        if let word = selectionNote {
            // Türetilmiş kanıtta otomatik uygulama yok — kullanıcıya ne yapması
            // gerektiği yazılı.
            suggestionBar.setStatus(input?.selectionHasRealEvidence == true
                ? "seçili: \(word)"
                : "seçili: \(word) — öneriye dokunun")
            return
        }

        guard let input else { return }
        let e = input.calibration.estimate(layout: layout)
        let cal = e.isApplicable
            ? String(format: " · kal %d örn (%+.3f,%+.3f)",
                     e.strongSamples, e.globalBiasX, e.globalBiasY)
            : (input.calibration.strongCount > 0
               ? " · kal \(input.calibration.strongCount)/\(CalibrationLearner.minStrongSamples)"
               : "")
        suggestionBar.setStatus(Self.configurationTag + loadReport + cal)
    }

    // MARK: - Kalibrasyon kalıcılığı

    /// Token sınırında: bekleyen profil değişimi ve kaydetme isteği burada
    /// karşılanır. Model değişimi **yalnız** burada olur (§5b snapshot swap).
    private func afterTokenBoundary() {
        if input?.wantsCalibrationSave == true {
            saveCalibration()
            input?.calibrationSaved()
        }
        if let p = pendingProfile,
           (input?.isComposing ?? fallback.session.isComposing) != true {
            switchProfile(to: p)
        }
    }

    private func refreshCalibrationProfile() {
        let size = keyboardView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let key = CalibrationStore.ProfileKey(
            // Ölçüler `layout.id`'de: shift genişleyince 3. satırın bütün
            // merkezleri kayıyor, o geometride öğrenilen sapma burada yanlış.
            layoutID: layout.id,
            idiom: isPad ? "pad" : "phone",
            isLandscape: size.width > size.height,
            height: Double(size.height),
            width: Double(size.width),
            placement: Self.placement(keyboardWidth: size.width,
                                      screenWidth: view.window?.screen.bounds.width,
                                      isPad: isPad),
            oneHanded: "off",     // iOS uzantıya tek el modunu bildirmiyor
            scale: Int(traitCollection.displayScale.rounded()))
        guard key != calibrationProfile else { return }

        if (input?.isComposing ?? fallback.session.isComposing) == true {
            pendingProfile = key
        } else {
            switchProfile(to: key)
        }
    }

    /// Yerleşim tespiti.
    ///
    /// iOS klavye uzantısına floating/split durumunu **bildirmiyor**. Ölçüden
    /// çıkarım güvenilir değil; yalnız emin olduğumuz durumda karar veriyoruz,
    /// gerisi `.unknown` ve kendi kovasında kalıyor.
    private static func placement(keyboardWidth: CGFloat, screenWidth: CGFloat?,
                                  isPad: Bool) -> CalibrationStore.ProfileKey.Placement {
        guard isPad else { return .docked }        // iPhone'da tek yerleşim
        guard let sw = screenWidth, sw > 0 else { return .unknown }
        let ratio = keyboardWidth / sw
        if ratio > 0.95 { return .docked }
        if ratio < 0.55 { return .floating }
        return .unknown                             // split olabilir, emin değiliz
    }

    private func switchProfile(to key: CalibrationStore.ProfileKey) {
        saveCalibration()                 // ÖNCEKİ profilin verisi önce diske
        calibrationProfile = key
        pendingProfile = nil
        if let dir = Self.calibrationDirectory {
            input?.replaceCalibration(CalibrationStore.loadOrEmpty(from: dir, profile: key))
        }
        refreshUI()
    }

    private func saveCalibration() {
        guard let dir = Self.calibrationDirectory, let p = calibrationProfile,
              let input, input.calibration.sampleCount > 0 else { return }
        try? CalibrationStore.save(input.calibration, to: dir, profile: p)
    }
}

/// `InputCoordinator`'ın belgeye açılan penceresi.
extension KeyboardViewController: DocumentEditor {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var contextAfterInput: String? { textDocumentProxy.documentContextAfterInput }
    var selectedText: String? { textDocumentProxy.selectedText }
}

/// Üç yuvalı öneri çubuğu + geliştirme HUD'u (§11.E debug HUD).
///
/// ## Neden `CATextLayer`, `UILabel`/`UIButton` değil
///
/// Bu yüzey **her tuş vuruşunda** güncelleniyor (`refreshUI`). İlk sürüm her
/// vuruşta üç `UIButton` yıkıp yeniden yaratıyordu; ikinci sürüm yalnız
/// `setTitle`/`isHidden` yazıyordu. İkisi de §11.B'yi deliyor: `setTitle`
/// intrinsic content size'ı, `isHidden` `UIStackView` yerleşimini
/// geçersizleştiriyor — yani yazma yolunda Auto Layout tetikleniyor.
///
/// Tuş yüzeyi bu disiplini baştan beri tutuyordu; çubuk tutmuyordu. Artık
/// aynı çözüm: çerçeveler yalnız boyut değişiminde hesaplanıyor, vuruş başına
/// değişen tek şey `CATextLayer.string`.
///
/// Ayar düğmesi `UIButton` olarak kalıyor: yazarken hiç değişmiyor.
final class SuggestionBar: UIView {
    var onPick: ((String) -> Void)?
    var onSettings: (() -> Void)?
    /// Kullanıcı "bunu kaydet" dedi.
    var onCapture: (() -> Void)?

    private static let slotCount = 3
    private static let rowHeight: CGFloat = 32
    private static let gearWidth: CGFloat = 34
    /// Kayıt düğmesi de aynı genişlikte.
    ///
    /// **Harf geometrisine dokunmuyor**: tuş satırlarına bir düğme eklemek
    /// bütün merkezleri kaydırır, `layoutID` değişir ve öğrenilmiş kalibrasyon
    /// başka bir kovaya düşerdi.
    private static let captureWidth: CGFloat = 34

    private var slots: [CATextLayer] = []
    private var slotWords: [String] = Array(repeating: "", count: slotCount)
    private var slotFrames: [CGRect] = []
    private let status = CATextLayer()
    private let settingsButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private var theme: KeyboardTheme = .light

    override init(frame: CGRect) {
        super.init(frame: frame)

        for _ in 0..<Self.slotCount {
            let t = CATextLayer()
            t.alignmentMode = .center
            t.contentsScale = UIScreen.main.scale
            t.fontSize = 16
            t.truncationMode = .end
            layer.addSublayer(t)
            slots.append(t)
        }

        status.alignmentMode = .center
        status.contentsScale = UIScreen.main.scale
        status.fontSize = 9
        // `CATextLayer.font` `UIFont` kabul etmiyor. İsimle (`CTFontCreateWithName`)
        // aramak sistem fontlarında çalışmıyor — adları `.SFUI-Regular` gibi
        // private ve arama Helvetica'ya düşüyor. Descriptor `CTFontDescriptor`
        // ile toll-free köprülü, doğru yol bu.
        status.font = CTFontCreateWithFontDescriptor(
            UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular).fontDescriptor
                as CTFontDescriptor, 9, nil)
        status.isWrapped = true
        layer.addSublayer(status)

        captureButton.setImage(UIImage(systemName: "record.circle"), for: .normal)
        captureButton.accessibilityIdentifier = "key.capture"
        captureButton.accessibilityLabel = "Son yazılanı kaydet"
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addAction(UIAction { [weak self] _ in self?.onCapture?() },
                                for: .touchUpInside)
        addSubview(captureButton)

        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.accessibilityIdentifier = "key.settings"
        settingsButton.accessibilityLabel = "Klavye ayarları"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.addAction(UIAction { [weak self] _ in self?.onSettings?() },
                                 for: .touchUpInside)
        addSubview(settingsButton)

        // Tek Auto Layout kullanıcısı ayar düğmesi; yazarken hiç dokunulmuyor.
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: topAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            settingsButton.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            settingsButton.widthAnchor.constraint(equalToConstant: Self.gearWidth),

            captureButton.topAnchor.constraint(equalTo: topAnchor),
            captureButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor),
            captureButton.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            captureButton.widthAnchor.constraint(equalToConstant: Self.captureWidth),
        ])
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }

        let usable = max(0, W - Self.gearWidth - Self.captureWidth - 6)
        let slotW = usable / CGFloat(Self.slotCount)
        slotFrames = (0..<Self.slotCount).map {
            CGRect(x: CGFloat($0) * slotW, y: 0, width: slotW, height: Self.rowHeight)
        }
        for (i, t) in slots.enumerated() {
            let f = slotFrames[i]
            // `CATextLayer` metni üstten hizalar; dikeyde tek geçişte ortalanıyor.
            let line = t.fontSize * 1.2
            t.frame = CGRect(x: f.minX, y: f.midY - line / 2, width: f.width, height: line)
        }
        status.frame = CGRect(x: 0, y: Self.rowHeight,
                              width: W, height: max(0, H - Self.rowHeight))
        rebuildAccessibilityElements()
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.barFace
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for t in slots { t.foregroundColor = theme.barText.cgColor }
        status.foregroundColor = theme.barSecondaryText.cgColor
        CATransaction.commit()
        settingsButton.tintColor = theme.barSecondaryText
        captureButton.tintColor = theme.barSecondaryText
    }

    func setCandidates(_ words: [String]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var changed = false
        for i in 0..<Self.slotCount {
            let w = i < words.count ? words[i] : ""
            guard slotWords[i] != w else { continue }
            slotWords[i] = w
            slots[i].string = w
            changed = true
        }
        if changed { rebuildAccessibilityElements() }
    }

    func setStatus(_ s: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        status.string = s
        CATransaction.commit()
    }

    // MARK: - Dokunma
    //
    // Tuş yüzeyiyle aynı sözleşme: eylem `touchesEnded`'de kesinleşir, parmak
    // yuvadan çıkarsa hiçbir şey seçilmez.

    private var pressedSlot: Int?

    private func slot(at p: CGPoint) -> Int? {
        guard let i = slotFrames.firstIndex(where: { $0.contains(p) }),
              !slotWords[i].isEmpty else { return nil }
        return i
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        pressedSlot = slot(at: t.location(in: self))
        setPressed(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let cur = pressedSlot else { return }
        if slot(at: t.location(in: self)) != cur { setPressed(false); pressedSlot = nil }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressedSlot = nil }
        setPressed(false)
        guard let t = touches.first, let i = pressedSlot,
              slot(at: t.location(in: self)) == i else { return }
        onPick?(slotWords[i])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(false)
        pressedSlot = nil
    }

    private func setPressed(_ on: Bool) {
        guard let i = pressedSlot, i < slots.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots[i].foregroundColor = (on ? theme.barSecondaryText : theme.barText).cgColor
        CATransaction.commit()
    }

    // MARK: - Erişilebilirlik
    //
    // `UIButton` bunu bedava veriyordu; katmana geçince elle kuruluyor —
    // tuş yüzeyindeki `rebuildAccessibilityElements` ile aynı yaklaşım.

    private func rebuildAccessibilityElements() {
        var elements: [Any] = []
        for (i, w) in slotWords.enumerated() where !w.isEmpty && i < slotFrames.count {
            let e = ActivatableElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "suggestion.\(i)"
            e.accessibilityLabel = w
            e.accessibilityTraits = .button
            e.accessibilityFrameInContainerSpace = slotFrames[i]
            e.onActivate = { [weak self] in self?.onPick?(w) }
            elements.append(e)
        }
        elements.append(settingsButton)
        accessibilityElements = elements
    }
}

/// Etkinleştirilebilir erişilebilirlik öğesi.
///
/// `UIButton` bunu bedava veriyordu; katmana geçince kaybolan tek şey buydu.
/// Düz `UIAccessibilityElement` etiketi **okutuyor** ama çift dokunuşu hiçbir
/// yere iletmiyor — VoiceOver kullanıcısı öneriyi duyup seçemiyordu.
private final class ActivatableElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
