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
import KBFoundation

/// Klavye uzantısı — **ince adaptör**.
///
/// Karar mantığının tamamı `KBRuntime.InputCoordinator`'da: commit kararı
/// (`Δ > θ`), kalibrasyon öğrenmesi, dil durumu, seçim kipi. Burada kalanlar
/// yalnız UIKit'e ait olanlar — görünüm, dokunma, yaşam döngüsü, dosya sistemi.
///
/// Ayrım test edilebilirlik içindi: `UIInputViewController` içindeki hiçbir şey
/// `swift test` altında koşmuyor, dolayısıyla uçtan uca doğrulama yazılamıyordu.
final class KeyboardViewController: UIInputViewController {

    var keyboardView: KeyboardView!
    var suggestionBar: SuggestionBar!
    /// Klavyenin üstünü kaplayan paneller — aynı anda bir tane.
    lazy var panels = PanelSlot(host: view)
    /// Son kullanılan emoji — açılışta diskten okunuyor.
    lazy var emojiRecents = EmojiRecentsStore.load()
    private var keyboardHeight: NSLayoutConstraint!
    var suggestionBarTop: NSLayoutConstraint!

    /// Bir **harf satırının** yüksekliği: 4 satırlık klavyenin 216 pt'si.
    /// Sayı sırası açılınca ya da boşluk satırı uzayınca klavye **büyür**;
    /// satırları sıkıştırmak tuş merkezlerini birbirine yaklaştırıp uzamsal
    /// ayrımı zayıflatırdı (`KeyboardMetrics.heightUnits`).

    var settings: KeyboardSettings
    var layout: KeyLayout
    /// Girdi oturumu: kaydedici, yedek yol ve aralarındaki geçiş kuralları.
    /// Denetleyici hangi yolun yazdığını bilmiyor, yalnız buna soruyor.
    lazy var session = InputSession(host: self, layout: layout, metrics: settings.metrics)

    /// Shift durum makinesi — çift dokunuşla kilit, harften sonra düşme,
    /// cümle başı otomatiği. Politika `KBRuntime`'da, burada yalnız bağlanıyor.
    var shift = ShiftPolicy()

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
    var isEditingDocument = false

    private var loadReport = "yükleniyor…"

    /// Optimize edilmemiş derlemeyi **görünür** kılar.
    ///
    /// Gerekçe ölçülmüş bir hata: `deploy.sh` uzun süre varsayılan olarak Debug
    /// kuruyordu ve decoder saf Swift beam search olduğu için `-Onone` altında
    /// tuş başına p50 12.44 ms / p95 19.21 ms veriyordu — Release'te 0.95 /
    /// 1.41 ms. **13 kat**, ve sözleşmenin p99 < 8 ms bütçesini 2.4 kat aşıyor.
    /// Klavye "biraz yavaş" hissettiriyordu ama hiçbir yerde hangi derlemenin
    /// kurulu olduğu yazmıyordu; teşhis edilemeyen bir yavaşlık en pahalısı.
    private static let configurationTag = RecordingSnapshot.buildConfiguration == "Debug" ? "⚠︎DEBUG · " : ""
    /// Seçili kelime düzenleniyorsa yüzeyi — durum satırı için.
    var selectionNote: String?

    // MARK: - Yaşam döngüsü

    override func viewDidLoad() {
        super.viewDidLoad()
        AILog.prepare()

        suggestionBar = SuggestionBar()
        suggestionBar.onPick = { [weak self] word in self?.pick(word) }
        // Ayar girişi öneri çubuğunda: tuş ızgarasında ona ayıracak yer yok ve
        // uzun basmaya gizlemek keşfedilemez kılardı.
        // ⚙︎ doğrudan uygulamayı açıyor: bütün ayarlar orada, iki ayrı ayar
        // yüzeyi birbirini tutmuyordu. Tam Erişim yoksa uygulama ne açılabiliyor
        // ne de ayarları klavyeye ulaşabiliyor — o zaman eski hızlı panel.
        suggestionBar.onSettings = { [weak self] in
            guard let self else { return }
            if self.hasFullAccess, self.openHome() { return }
            self.togglePanel(.settings)
        }
        suggestionBar.onApp = { [weak self] id in self?.openApp(id) }
        suggestionBar.onAI = { [weak self] in self?.togglePanel(.ai) }
        suggestionBar.onFonts = { [weak self] in self?.toggleFancy() }
        suggestionBar.onStylePick = { [weak self] i in self?.pickFancyStyle(i) }
        suggestionBar.onMic = { [weak self] in
            guard let self, let url = DeepLink.url(.dictation) else { return }
            if !self.openURL(url) { self.showToast(CommonText.fullAccess(open: "Sesle yazma")) }
        }
        suggestionBar.onShortcut = { [weak self] in self?.applyShortcut() }
        suggestionBar.setApps(settings.aiApps)
        suggestionBar.onClipChip = { [weak self] in self?.useRecentClip() }
        suggestionBar.onEmoji = { [weak self] in self?.togglePanel(.emoji) }
        suggestionBar.onDismiss = { [weak self] in self?.dismissWithPanels() }

        suggestionBar.showsStatus = settings.showsDiagnostics

        keyboardView = KeyboardView(layout: layout, metrics: settings.metrics)
        keyboardView.apply(settings)
        // Eylem `touchesEnded`'de kesinleşir (sürükleme/iptal karakter üretmez).
        keyboardView.onKeyCommit = { [weak self] hit, how in self?.handle(hit, how) }
        // **Gerçek dokunma yaşam döngüsü.** Önce yalnız harfler için sonradan
        // tek bir `.ended/.committed` dokunma uyduruluyordu: boşluk, backspace,
        // sembol, iptal, `neverHit` ve `leftBounds` kanıtı hiç kayda girmiyordu.
        // Yani "motor boşluğu yuttu" ile "dokunma tuşa hiç isabet etmedi" ayırt
        // edilemiyordu — kullanıcının asıl sorusu tam da bu.
        keyboardView.onTouchRecord = { [weak self] r in
            guard let self else { return }
            self.session.record(r, shift: self.shift.recordingLabel)
        }
        keyboardView.onKeyRepeat = { [weak self] hit, stage in self?.handleRepeat(hit, stage) }
        // Globe sözleşmesi: gösterim `needsInputModeSwitchKey`'e bağlı,
        // uzun basma sistem input-mode listesini açar.
        keyboardView.showsGlobeKey = needsInputModeSwitchKey
        keyboardView.onGlobeLongPress = { [weak self] view, event in
            self?.handleInputModeList(from: view, with: event ?? UIEvent())
        }
        // Nokta basılı tutulunca virgül. Yine sembol yolundan: virgül de
        // token'ı kapatıyor ve deftere işleniyor — tek farkı cümle
        // sonlandırıcı olmaması, o ayrımı da `InputCoordinator` yapıyor.
        keyboardView.onPeriodLongPress = { [weak self] in
            self?.handle(.symbol(","))
        }
        keyboardView.onSpaceDragBegan = { [weak self] in self?.beginCursorDrag() }
        keyboardView.onSpaceDragChanged = { [weak self] dx, dy, t in
            self?.updateCursorDrag(dx: Double(dx), dy: Double(dy), time: t) ?? 0
        }
        keyboardView.onSpaceDragEnded = { [weak self] in self?.endCursorDrag() }
        keyboardView.onSpaceDragStep = { [weak self] dir in
            self?.stepCursorByWord(dir) ?? false
        }
        // VoiceOver kayıt tutulup tutulamayacağını **belirliyor** (§8.9), ve
        // kullanıcı onu klavye açıkken de açıp kapatabiliyor. Durumu yalnız
        // kurulumda okumak, kipin ortasında değişmesini görmezden gelmek olurdu.
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil)

        // Ortak arka plan **ilk** alt görünüm: öneri çubuğu ve tuşlar
        // saydam, gradyan/fotoğraf ikisinin arkasında kesintisiz.
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        keyboardView.drawsBackdrop = false
        for v in [suggestionBar as UIView, keyboardView as UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        keyboardHeight = keyboardView.heightAnchor.constraint(
            equalToConstant: KeyboardView.height(for: settings.metrics))
        // Zorunlu değil (999): sayı sırası + uzun boşluk satırı en fazla
        // 5.75 satır istiyor ve dar bir yatay ekranda sistem bu kadar yer
        // vermeyebilir. Zorunlu bırakmak constraint kırılması demekti; 999 ile
        // kısıt esniyor ve klavye sığdığı kadarını alıyor.
        //
        // Geometri bundan zarar görmüyor: `KeyboardView` her şeyi **kendi
        // bounds'una** göre normalize ediyor, yani çizim ve dokunma hizalı
        // kalıyor — yalnız tuşlar kısalıyor.
        keyboardHeight.priority = .required - 1
        // Yapay zeka kartı açılınca klavye **yukarı** uzuyor: çubuğun üstü
        // aşağı itiliyor, giriş görünümü bu kadar büyüyor.
        suggestionBarTop = suggestionBar.topAnchor.constraint(equalTo: view.topAnchor)

        // Auto Layout yalnız kurulumda; yazma sırasında hiç çalışmaz.
        NSLayoutConstraint.activate([
            suggestionBarTop,
            suggestionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // İki satır: üstte araç satırı (uygulamalar, emoji, ⚙︎), altta
            // tam genişlikte öneriler. Tek satırda logolar önerileri
            // sıkıştırıyordu (kullanıcı geri bildirimi).
            suggestionBar.heightAnchor.constraint(equalToConstant: SuggestionBar.height),

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

    var resolvedTheme: KeyboardTheme {
        settings.theme.resolved(for: traitCollection)
    }

    let backdrop = ThemeBackdropView()

    func applyTheme() {
        let t = resolvedTheme
        backdrop.apply(t)
        keyboardView.theme = t
        suggestionBar.apply(theme: t)
        panels.apply(theme: t)
    }

    // MARK: - Bileşenler ve durum
    //
    // Davranış `+Panels`, `+Shortcuts` ve `+Input` dosyalarında; uzantılar
    // saklı özellik tutamadığı için durumları burada.

    // Kısayollar (`+Shortcuts`).
    /// Çubukta gösterilen kısayol ve onu tetikleyen metin.
    var activeShortcut: (trigger: String, item: TextShortcut)?
    /// `/` ile başlayan son kelimeye uyan yapay zeka tuşları.
    var activeCommands: [AIAction] = []
    var commandToken = ""
    static let commandMark = "✦ "
    /// Küçük resimler önbellekte: kısayol her tuşta yeniden aranıyor ve
    /// diskten okumak her basışa bir dosya okuması eklerdi.
    var thumbCache: [String: UIImage] = [:]

    // Yazma geçmişi, dikte ve fontlu yazı (`+Input`, `+Shortcuts`).
    let history = TypingHistory()
    var predictedNext: [String] = []
    lazy var dictation = DictationReceiver { [weak self] in self?.consumeDictation() }
    var fancy = FancyTextMode()

    // Yapay zeka kartı, pano ve bilgi balonu (`+Panels`).
    lazy var aiCard = AICardController(host: self)

    private(set) lazy var clipboard: ClipboardWatcher = {
        let c = ClipboardWatcher()
        c.onChange = { [weak self] in
            guard let self else { return }
            self.panels.current(ClipboardPanel.self)?.update(items: self.clipboard.store.items)
            self.refreshClipChip()
        }
        return c
    }()

    lazy var toast = Toast(in: view)

    // Boşlukta imleç sürükleme (`+Input`).
    /// Jestin belgeye bağlanmış hâli. Bağlam okuması, ivme ve satır
    /// aritmetiği **çekirdekte** (`CursorTrackpad`); burada kalan tek iş
    /// ofseti proxy'ye vermek.
    var cursorDrag: CursorTrackpad?
    var cursorDragMoved = false

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
    /// `persist: false` — depodan yeni okunan değer geri yazılmıyor: okuma ile
    /// yazma arasında uygulama kaydederse onun değişikliği ezilirdi.
    func apply(settings new: KeyboardSettings, persist: Bool = true) {
        let old = settings
        settings = new
        if persist { KeyboardSettingsStore.save(new) }

        if new.theme != old.theme { applyTheme() }
        suggestionBar.showsStatus = new.showsDiagnostics
        suggestionBar.setApps(new.aiApps)
        // Zamanlama geometri değil: ne kalibrasyon profili ne decoder etkilenir.
        keyboardView.apply(new)
        guard new.metrics != old.metrics else { return }

        keyboardHeight.constant = KeyboardView.height(for: new.metrics)

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
        let t = Timer.onMainLoop(after: Self.modelRebuildDelay) { [weak self] in self?.rebuildModel() }
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
    func rebuildModel() {
        modelRebuild?.invalidate()
        modelRebuild = nil
        guard layout.id != TurkishQ.layout(metrics: settings.metrics).id else { return }

        layout = TurkishQ.layout(metrics: settings.metrics)
        // Geometri değişti: **yeni bir deneme** (kaydedici, yedek yol ve
        // kalibrasyon profili yeni geometriye geçiyor; bkz. `InputSession.reset`).
        session.reset(layout: layout, metrics: settings.metrics)
        keyboardView.apply(layout: layout, metrics: settings.metrics)
        // Profil anahtarı `layout.id`'yi taşıyor; geometri değişince
        // `refreshCalibrationProfile` yeni kovaya geçiyor. Yeni profil
        // `viewDidLayoutSubviews`'te kuruluyor: burada klavyenin yeni boyutu
        // henüz ölçülmedi ve profil anahtarı ölçüyü de taşıyor.
        view.setNeedsLayout()
        loadPackAsync()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Uygulamada yapılan ayarlar ortak depodan geliyor (Tam Erişim +
        // App Group). Her açılışta yeniden okunuyor: kullanıcı uygulamada
        // bir şey değiştirip klavyeye döndüğünde görmeli.
        KeyboardSettingsStore.sharingAllowed = hasFullAccess
        let stored = KeyboardSettingsStore.load()
        if stored != settings { apply(settings: stored, persist: false) }
        dictation.start()
        // Kapanırken ertelenmiş bir kurulum kalmış olabilir; temizse no-op.
        rebuildModel()
        // Alan değişmiş olabilir: klavye her açılışta **yeniden** soruyor.
        session.dropIfSecure()
        checkPasteboard()
        session.resumeAfterSecureField()
        // Kapanışta bırakılan kaydedici, denetleyici yeniden gösterilince geri
        // geliyor (paketler yüklüyse; koşullar `InputSession.start`'ta).
        session.restart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshCalibrationProfile()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Bekleyen dikte burada: `viewWillAppear`'da klavye henüz yazı alanına
        // bağlanmamış olabiliyor, yazılan metin kayboluyor ve dosya da
        // silindiği için bir daha gelmiyordu. Kısa bir gecikme de bağlantı için.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.consumeDictation() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tampon **atılıyor**: bir sonraki açılış başka bir uygulamada, başka
        // bir alanda olabilir ve önceki bağlamın tamponunu taşımak,
        // kullanıcının orada yazdığını burada yakalanabilir yapardı.
        // Kalibrasyon **önce**: motor bırakılınca kaydedilecek örnek kalmıyordu
        // (son token sınırından beri öğrenilenler kayboluyordu).
        session.suspend()
        // Yalnız zamanlayıcı iptal ediliyor; "kirli" bilgisi `layout.id`
        // farkında duruyor ve `viewWillAppear` onu topluyor.
        modelRebuild?.invalidate()
        modelRebuild = nil
        history.flush()
        // Panel açık kalırsa bir sonraki açılışta açık gelirdi (kartla klavye de uzun).
        closePanel(byUser: false)
    }

    // MARK: - Paket yükleme

    private let packs = PackLoading()

    /// Layout ana thread'de yakalanıyor: arka planda `self.layout` okumak
    /// ayarla eşzamanlı değişimde veri yarışı olurdu.
    private func loadPackAsync() {
        packs.load(layout, bundle: Bundle(for: Self.self)) { [weak self] result in
            switch result {
            case let .success(loaded): self?.didLoad(loaded)
            case let .failure(error): self?.suggestionBar.setStatus("paket yüklenemedi: \(error)")
            }
        }
    }

    private func didLoad(_ loaded: PackLoader.Loaded) {
        // Kanal yapılandırması `PackLoader` içinde — burada
        // tekrarlanmıyor ki kayıt ekranıyla ayrışmasın.
        session.didLoad(loaded)
        loadReport = loaded.report
        refreshUI()
    }

    // MARK: - Görünüm

    func refreshUI() {
        refreshClipChip()
        refreshShortcut()
        // Bozulmuş durumda da öneri gösteriliyor: boş çubuk "aday yok" demek
        // olurdu, oysa yalnız kayıt yok.
        let engineWords = session.suggestionSurfaces()
        predictedNext = engineWords.isEmpty ? nextWordPredictions() : []
        suggestionBar.highlightsFirst = !activeCommands.isEmpty
        if !activeCommands.isEmpty {
            suggestionBar.setCandidates(activeCommands.map { Self.commandMark + $0.name })
        } else {
            suggestionBar.setCandidates(engineWords.isEmpty ? predictedNext : engineWords)
        }

        if let word = selectionNote {
            // Türetilmiş kanıtta otomatik uygulama yok — kullanıcıya ne yapması
            // gerektiği yazılı.
            suggestionBar.setStatus(session.selectionHasRealEvidence
                ? "seçili: \(word)"
                : "seçili: \(word) — öneriye dokunun")
            return
        }

        guard let input = session.engine else {
            // Kaydedici yokken durum satırı eskiden **hiç** güncellenmiyordu:
            // ekranda son yazılan cümle kalıyor ve kullanıcı kaydın neden
            // durduğunu görmüyordu. Sebep zaten tutuluyordu, yalnız okunmuyordu.
            if let why = session.failure {
                suggestionBar.setStatus(Self.configurationTag + " · kayıt yok: \(why)")
            }
            return
        }
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
    func afterTokenBoundary() {
        observeHistory()
        // Kişisel sözlük burada **değil**: yazma devretmeden önce olmak zorunda
        // ve o an `perform`'un içinde (bkz. oradaki not). Sayaç da yok — kabul
        // ender bir olay ve kaybedilirse kullanıcı kelimeyi baştan öğretir.
        if session.calibrationAtBoundary() { calibrationDidSwitch() }
    }

    private func refreshCalibrationProfile() {
        guard let key = CalibrationPersistence.profileKey(
            layoutID: layout.id, size: keyboardView.bounds.size,
            isPad: traitCollection.userInterfaceIdiom == .pad,
            screenWidth: view.window?.screen.bounds.width, scale: traitCollection.displayScale)
        else { return }
        if session.requestCalibrationProfile(key) { calibrationDidSwitch() }
    }

    /// Profil değişti: motor yeni kalibrasyonla çalışıyor, deneme devrediliyor.
    private func calibrationDidSwitch() {
        session.rollOver()
        refreshUI()
    }

    // MARK: - Kişisel sözlük kalıcılığı (§8.7)

    /// Bu alandaki metinden kelime öğrenir (§8.7 korpus içe aktarımı).
    ///
    /// ## Kaynak: alanın kendisi, pano değil
    ///
    /// Panoyu okumak Tam Erişim istiyor ve iOS her okumada sistem onayı
    /// gösteriyor. Alandaki metni klavye zaten izinsiz görüyor: kullanıcı
    /// kendi yazdığı bir metni bir yere yapıştırıp bu düğmeye basıyor.
    ///
    /// ## Gördüğü kadarı
    ///
    /// `documentContext` iOS'un verdiği **pencere** — belgenin tamamı değil.
    /// Rapor bu yüzden token sayısını söylüyor: "hepsini okudum" iddiası
    /// doğrulanamaz ve kullanıcı metni parça parça verebilmeli.
    ///
    /// Parola alanında çalışmıyor; koordinatör de ayrıca reddediyor.
    func importPersonalFromField()
        -> (added: [String], all: [String], note: String) {
        guard !fieldIsSecure else { return ([], session.personalWords, "parola alanında öğrenme yok") }
        let text = documentBaseline
        // Yazma geçmişi de bu metinden öğreniyor (sonraki kelime, hatırlama).
        history.ingest(text: text)
        let tokens = PromptTokenizer(layout: layout).tokens(of: text)
        guard !tokens.isEmpty else { return ([], session.personalWords, "bu alanda okunacak metin yok") }

        let effective = session.ingestPersonal(tokens: tokens)

        let all = session.personalWords
        let note: String
        if effective.admitted.isEmpty {
            note = "\(effective.tokens) kelime okundu · yeni kelime yok "
                 + "(bir kelimenin öğrenilmesi için metinde en az üç kez geçmeli)"
        } else {
            note = "\(effective.tokens) kelime okundu · \(effective.admitted.count) "
                 + "yeni kelime öğrenildi"
        }
        return (effective.admitted, all, note)
    }

}

