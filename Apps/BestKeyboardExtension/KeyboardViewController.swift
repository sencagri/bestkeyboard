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
    private var emojiPanel: EmojiPanel?
    /// Son kullanılan emoji — açılışta diskten okunuyor.
    private lazy var emojiRecents = EmojiRecentsStore.load()
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

    /// Kişisel sözlük (§8.7) — kalibrasyonla **aynı sandbox**, ayrı dizin.
    ///
    /// Profil yok: öğrenilen şey bir yüzey, tuş merkezlerine bağlı değil.
    private static var personalDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("personal", isDirectory: true)
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
        suggestionBar.onEmoji = { [weak self] in self?.toggleEmojiPanel() }
        // `dismissKeyboard()` uzantının kendi kapanma yolu; host'a "işim bitti"
        // demenin desteklenen tek biçimi. Açık paneli önce kapatmak gerekiyor:
        // panel `view`'ın alt görünümü ve klavye kapanınca ekranda kalmıyor ama
        // bir sonraki açılışta **açık** geliyordu.
        suggestionBar.onDismiss = { [weak self] in
            guard let self else { return }
            if settingsPanel != nil { toggleSettingsPanel() }
            if emojiPanel != nil { toggleEmojiPanel() }
            dismissKeyboard()
        }

        keyboardView = KeyboardView(layout: layout, metrics: settings.metrics)
        keyboardView.cadence = settings.cadence
        // Eylem `touchesEnded`'de kesinleşir (sürükleme/iptal karakter üretmez).
        keyboardView.onKeyCommit = { [weak self] hit, how in self?.handle(hit, how) }
        // **Gerçek dokunma yaşam döngüsü.** Önce yalnız harfler için sonradan
        // tek bir `.ended/.committed` dokunma uyduruluyordu: boşluk, backspace,
        // sembol, iptal, `neverHit` ve `leftBounds` kanıtı hiç kayda girmiyordu.
        // Yani "motor boşluğu yuttu" ile "dokunma tuşa hiç isabet etmedi" ayırt
        // edilemiyordu — kullanıcının asıl sorusu tam da bu.
        keyboardView.onTouchRecord = { [weak self] r in self?.record(r) }
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
        keyboardView.onSpaceDragChanged = { [weak self] dx, dy in
            self?.updateCursorDrag(dx: Double(dx), dy: Double(dy)) ?? false
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
            overlayPanelDidChange(nil)
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
        // Kayda girmeyen durum değişikliği denemeyi kapatıyor.
        try? recorder?.rollOverIfNeeded()
        selectionNote = nil
        // Token kapandı: bekleyen profil geçişi ve kalibrasyon kaydı burada
        // karşılanmalı. Yoksa composition sırasında cihaz döndürülüp panel
        // açıldığında `pendingProfile` asılı kalıyor ve panelden sonraki ilk
        // kelime **eski** yönelimin kalibrasyonuyla işleniyordu.
        afterTokenBoundary()
        refreshUI()

        let p = KeyboardSettingsPanel(
            settings: settings,
            theme: resolvedTheme,
            showsGlobe: needsInputModeSwitchKey,
            // Liste **motordan** okunuyor, diskten değil: kullanıcı o an
            // klavyenin bildiği kelimeleri görmeli. Kaydedici bozuksa yedek
            // yolun sözlüğü de aynı dosyadan yüklendi.
            personalWords: (input?.personal ?? fallback.personal).admitted)
        p.onChange = { [weak self] s in self?.apply(settings: s) }
        p.onClose = { [weak self] in self?.toggleSettingsPanel() }
        p.onForgetPersonal = { [weak self] word in self?.forgetPersonal(word) }
        p.onImportPersonal = { [weak self] in
            self?.importPersonalFromField() ?? ([], [], "klavye hazır değil")
        }
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: view.topAnchor),
            p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            p.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        settingsPanel = p
        overlayPanelDidChange(p)
    }

    // MARK: - Emoji yüzeyi

    /// Emoji panelini açar/kapatır.
    ///
    /// Ayar paneliyle **aynı sınır işlemleri**: yazılmakta olan token
    /// kapanıyor, kayda girmeyen durum değişikliği denemeyi kapatıyor ve
    /// bekleyen profil geçişi karşılanıyor. Emoji girişi token sınırı olduğu
    /// için panel açıkken composing'in sürmesi tutarsız olurdu.
    private func toggleEmojiPanel() {
        if let p = emojiPanel {
            p.removeFromSuperview()
            emojiPanel = nil
            overlayPanelDidChange(nil)
            refreshUI()
            return
        }
        keyboardView.cancelInteraction()
        withOwnEdit { try? input?.invalidateComposing() }
        try? recorder?.rollOverIfNeeded()
        selectionNote = nil
        afterTokenBoundary()
        refreshUI()

        let p = EmojiPanel(theme: resolvedTheme, recents: emojiRecents)
        p.onPick = { [weak self] emoji in self?.insertEmoji(emoji) }
        p.onBackspace = { [weak self] in self?.emojiBackspace() }
        p.onClose = { [weak self] in self?.toggleEmojiPanel() }
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: view.topAnchor),
            p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            p.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        emojiPanel = p
        overlayPanelDidChange(p)
    }

    /// Emoji **sembol yolundan** giriyor.
    ///
    /// Doğrudan `textDocumentProxy.insertText` çağırmak kaydın görmediği bir
    /// mutasyon üretirdi (§12.6) ve defter belgeyle ayrışırdı. Sembolle aynı
    /// yol olması ayrıca doğru semantiği veriyor: emoji bir **token sınırı**,
    /// kod çözmeye girmiyor ve düzeltme denenmiyor.
    private func insertEmoji(_ emoji: String) {
        // Güvenli alanda emoji de yazılabilmeli; `perform` tamponu zaten
        // düşürüyor, yazma yolu değişmiyor.
        perform(command: .symbol(emoji))
        shift.didInterruptChain()
        afterTokenBoundary()
        startPendingRecorderIfAtBoundary()
        updateAutoCapitalization()
        refreshUI()

        if emojiRecents.use(emoji) {
            EmojiRecentsStore.save(emojiRecents)
            emojiPanel?.update(recents: emojiRecents)
        }
    }

    private func emojiBackspace() {
        perform(command: .backspaceTap)
        shift.didInterruptChain()
        updateAutoCapitalization()
        refreshUI()
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
        // Fallback de **yeni** geometriye geçiyor: eski layout'la çalışmaya
        // devam etmek, çizilen tuşlarla decoder'ın uzamsal modelini
        // ayrıştırırdı.
        fallback = InputCoordinator(layout: layout)
        loadPackAsync()
        keyboardView.apply(layout: layout, metrics: settings.metrics)
        // Profil anahtarı `layout.id`'yi taşıyor; geometri değişince
        // `refreshCalibrationProfile` yeni kovaya geçiyor. Yeni profil
        // `viewDidLayoutSubviews`'te kuruluyor: burada klavyenin yeni boyutu
        // henüz ölçülmedi ve profil anahtarı ölçüyü de taşıyor.
        calibrationProfile = nil
        pendingProfile = nil
        // Geometri değişti: eski profilde öğrenilen sapma bu geometride
        // **yanlış**. Canlı kopya da düşüyor, yoksa yeni profil kurulana
        // kadar araya giren bir devretme onu geri getirirdi.
        liveCalibration = nil
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
        resumeAfterSecureFieldIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshCalibrationProfile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tampon **atılıyor**: bir sonraki açılış başka bir uygulamada, başka
        // bir alanda olabilir ve önceki bağlamın tamponunu taşımak,
        // kullanıcının orada yazdığını burada yakalanabilir yapardı.
        recorder = nil
        suspendedForSecureField = false
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
                    // Bekleyen profil **önce** uygulanıyor: yoksa boş öğrenici
                    // kaydedilmiş kalibrasyonun üstüne yazardı.
                    if let pending = self.pendingLearner {
                        self.input?.replaceCalibration(pending)
                        self.pendingLearner = nil
                    }
                    self.input?.applyCalibration()
                    // Kalibrasyon motoru değiştirdi: mevcut denemenin snapshot'ı
                    // artık onu anlatmıyor, yenisine geçiliyor.
                    try? self.recorder?.rollOverIfNeeded()
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

    private func handle(_ hit: KeyboardView.KeyHit,
                        _ how: KeyboardView.KeyActivation = .touch) {
        // Türetilmiş kanıt yalnız **harf** yolunda anlam taşıyor: rakam, sembol
        // ve işlev tuşları zaten kod çözmeye girmiyor ve hiçbir uzamsal iddiada
        // bulunmuyorlar.
        let synthetic = how == .accessibility
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
            lastFallbackPoint = point
            // Dokunma **zaten kaydedildi** (`onTouchRecord`); zarf yalnız
            // kimliğine atıf yapıyor. Ayrıca uydurmak, aynı dokunmayı iki kez
            // farklı olgularla yazmak olurdu.
            perform(command: .letter(baseKey: String(ch),
                                     display: shift.isUppercase
                                        ? InputCoordinator.uppercase(ch, locale: "tr")
                                        : String(ch),
                                     shifted: shift.isUppercase),
                    touchID: synthetic ? nil : lastTouchID, at: t.timestamp,
                    synthetic: synthetic)
            shift.didEmitLetter()
            syncKeyboardState()

        // Rakam/sembol kod çözmeye girmez — üst sayı sırası da aynı yoldan
        // geçiyor, yalnız vurgusu ayrı bir katman kümesine gidiyor.
        case let .symbol(ch), let .digit(ch):
            selectionNote = nil
            perform(command: .symbol(String(ch)))
            shift.didInterruptChain()
            afterTokenBoundary()
            startPendingRecorderIfAtBoundary()
            updateAutoCapitalization()

        case let .function(fk):
            switch fk {
            case .space:
                // Alan koruması **motora** bildiriliyor: eskiden yalnız fallback
                // yolunda kullanılıyordu ve `.behavior` politikasında e-posta
                // alanı korumasız kalıyordu.
                input?.fieldProtectsLiteral = fieldProtectsLiteral
                // Parola alanı **ayrı** bir olgu: `fieldProtectsLiteral`
                // e-posta/URL için de açık ama onlar güvenli alan değil.
                // Kişisel sözlük güvenli alanda hiçbir şey öğrenmiyor ve bunu
                // başka bir katmanın tamponu düşürmesine bırakmıyor.
                input?.fieldIsSecure = fieldIsSecure
                fallback.fieldIsSecure = fieldIsSecure
                perform(command: .space)
                selectionNote = nil
                shift.didInterruptChain()
                afterTokenBoundary()
                startPendingRecorderIfAtBoundary()
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

            // Nokta **sembol yoluna** giriyor, kendi dalını açmıyor.
            //
            // `123`'e geçip `.`'ya basmakla harf düzleminden basmak arasında
            // hiçbir fark olmamalı: ikisi de token'ı kapatıyor, ikisi de cümle
            // sonlandırıcı (`endsSentence`) ve ikisi de aynı öğrenme kanıtını
            // üretiyor. Ayrı bir dal açmak o davranışı ikinci bir yerde
            // tekrarlamak, yani ayrışmaya davet olurdu.
            case .period:
                handle(.symbol("."), how)
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
        // Kaydedici bozuksa **fallback'ten** aranıyor: eskiden yalnız `input`
        // sorulduğu için çubukta görünen adaya dokunmak no-op oluyordu.
        let picked = input?.visibleSuggestions()
            .first(where: { $0.surface == word })
            ?? fallback.suggestions().first(where: { $0.surface == word })
        guard let picked else { return }
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
        loadedPacks = loaded
        // Güvenli alanda **kurulmuyor**: devam eden bir paket yükü, başarılı
        // bir drop'tan sonra bile kaydediciyi geri getirebiliyordu.
        guard !fieldIsSecure else {
            recorder = nil
            suspendedForSecureField = true
            recorderFailure = "parola alanı"
            return
        }
        // VoiceOver açıkken **hiç kurulmuyor**. Ekran okuyucuyla yazılan her
        // harf türetilmiş kanıt taşıyor (§8.9) ve kayıt onu bir dokunma olgusu
        // olarak yazamaz. Kurup ilk harfte bırakmak, kullanıcıya kayıt
        // tuttuğunu sanan bir düğme göstermek olurdu.
        guard !UIAccessibility.isVoiceOverRunning else {
            recorder = nil
            recorderFailure = "VoiceOver açık"
            return
        }
        // **Token ortasında kurulmuyor.** Yeni koordinatör fallback'in
        // composing'ini taşımıyor: paketler `"kal"` yazılırken gelirse kullanıcı
        // `"em"` için aday görürdü, `"kalem"` için değil. Sınırda kurmak hiçbir
        // şey kaybettirmiyor — o ana kadar zaten kayıt yoktu.
        guard !fallback.session.isComposing else {
            pendingRecorderStart = true
            return
        }
        pendingRecorderStart = false
        let l = layout
        let m = settings.metrics
        do {
            recorder = try ProductionRecorder(
                makeDescriptor: { [weak self] id in
                    Self.productionDescriptor(
                        id: id, layout: l, metrics: m,
                        geometry: self?.geometrySnapshot()
                            ?? Self.emptyGeometry(layout: l))
                },
                build: { writer in
                    RecordingEngine(writer: writer,
                                    coordinator: InputCoordinator(layout: l),
                                    layout: l)
                },
                configure: { [weak self] engine in
                    try engine.configure(
                        loaded: loaded,
                        // Kayıttan gelen kalibrasyon **yok**: üretimde motor
                        // canlı öğreniciyle kuruluyor (`learner:` aşağıda) ve
                        // snapshot onu okuyor. Bu alan replay yolunun girişi.
                        calibration: .init(applied: false, strongSamples: 0,
                                           biasX: [], biasY: [],
                                           hierarchical: .init(globalX: 0, globalY: 0,
                                                               rowX: [], rowY: [],
                                                               keyX: [], keyY: []),
                                           sigma: .known(.init(x: [], y: []))),
                        // Devretmede koordinatör sıfırdan kuruluyor: sözlük
                        // **her denemede** yeniden veriliyor, yoksa bayt
                        // sınırında kullanıcı kendi kelimelerini kaybederdi.
                        personal: Self.loadPersonalLexicon(),
                        // **Devretme öğrenilmiş sapmayı düşürmemeli.**
                        //
                        // `rollOver` koordinatörü sıfırdan kuruyor.
                        // `applyCalibration` yalnız paket yüklemesinde ve profil
                        // değişiminde çağrılıyordu, dolayısıyla 512 KB'lık
                        // tampon sınırına gelen kullanıcı kalibrasyonunu
                        // yürürlükten düşürüyordu — dosya duruyor ama canlı
                        // motor kalibrasyonsuz koşuyordu.
                        //
                        // Rezervuar **canlı kopyadan**, diskten değil: son
                        // kaydetmeden sonra biriken örnekler de taşınsın.
                        // `input` burada okunamaz — devretme sırasında o çoktan
                        // yeni (boş) motoru gösteriyor.
                        learner: self?.liveCalibration ?? self?.loadedCalibration())
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
        // Kişisel sözlük paketlerden gelmiyor: taze kurulan her leksikonun
        // üstüne **burada** biniyor. Kaydedici token sınırında yeniden
        // kurulduğunda da (`startPendingRecorderIfAtBoundary`) geçerli olsun
        // diye çağrı yükleme yolunda değil, kurulumun kendisinde.
        applyPersonalLexicon()
    }

    /// Üretim denemesinin tanımı — **hedef yok**.
    ///
    /// `alignmentSource: .none`: kullanıcının ne yazmak istediğini yalnız kendisi
    /// biliyor ve o da nota yazıyor. `promptTokens` boş olamaz (§2.3), bu yüzden
    /// tek elemanlı bir yer tutucu; hizalama zaten `constructed` olmadığı için
    /// kalibrasyon kapısı bu kayıtları eliyor.
    private static func productionDescriptor(id: String, layout: KeyLayout,
                                             metrics: KeyboardMetrics,
                                             geometry: CanonicalSession.Geometry)
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
            geometry: geometry)
    }

    /// Klavyenin **gerçek** geometrisi.
    ///
    /// Önce sıfır bounds ve daima `portrait` yazılıyordu: landscape'te
    /// `rawX = 700` olan bir dokunma `boundsWidth = 0, portrait` diyen bir
    /// kayda giriyor ve normalize uzay yeniden kurulamıyordu.
    private func geometrySnapshot() -> CanonicalSession.Geometry {
        let b = keyboardView?.bounds ?? .zero
        let frame = keyboardView?.superview.map {
            $0.convert(b, to: nil)
        } ?? .zero
        let orientation: String
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: orientation = "landscape"
        case .portraitUpsideDown:             orientation = "portraitUpsideDown"
        case .portrait:                       orientation = "portrait"
        default:                              orientation = "unknown"
        }
        return .init(layoutID: layout.id,
                     layoutFingerprint: .known(layout.fingerprint),
                     boundsX: Double(b.origin.x), boundsY: Double(b.origin.y),
                     boundsWidth: Double(b.width), boundsHeight: Double(b.height),
                     frameInScreenX: Double(frame.origin.x),
                     frameInScreenY: Double(frame.origin.y),
                     frameInScreenWidth: Double(frame.width),
                     frameInScreenHeight: Double(frame.height),
                     safeAreaBottom: Double(view.safeAreaInsets.bottom),
                     screenScale: UIScreen.main.scale,
                     interfaceOrientation: orientation,
                     deviceModel: UIDevice.current.model,
                     systemVersion: UIDevice.current.systemVersion)
    }

    /// VC yokken kullanılan yer tutucu — pratikte erişilmiyor.
    private static func emptyGeometry(layout: KeyLayout)
        -> CanonicalSession.Geometry {
        .init(layoutID: layout.id,
              layoutFingerprint: .known(layout.fingerprint),
              boundsX: 0, boundsY: 0, boundsWidth: 0, boundsHeight: 0,
              frameInScreenX: 0, frameInScreenY: 0,
              frameInScreenWidth: 0, frameInScreenHeight: 0,
              safeAreaBottom: 0, screenScale: UIScreen.main.scale,
              interfaceOrientation: "unknown",
              deviceModel: UIDevice.current.model,
              systemVersion: UIDevice.current.systemVersion)
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
        // Sonuç **hem** duruma yazılıyor hem duyuruluyor: durum satırı ekran
        // okuyucuya görünmüyor, duyuru da ekranda iz bırakmıyor. İkisi aynı
        // cümleyi iki kanaldan söylüyor.
        func report(_ text: String) {
            suggestionBar.setStatus(text)
            announce(text)
        }
        // Güvenli alanda **hiçbir koşulda** yazılmıyor.
        guard !fieldIsSecure else {
            report("parola alanında kayıt yok")
            return
        }
        guard let recorder, let dir = Self.captureDirectory else {
            // Sebep biliniyorsa söyleniyor: "hazır değil" kullanıcıya beklemek
            // mi başka bir şey yapmak mı gerektiğini bildirmiyor.
            report(recorderFailure.map { "kayıt yok: \($0)" } ?? "kayıt hazır değil")
            return
        }
        do {
            _ = try recorder.capture(note: nil, to: dir)
            report("kaydedildi ✓")
        } catch {
            report("kaydedilemedi: \(error)")
        }
    }

    // MARK: - Tek mutasyon noktası

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

    /// - Parameter synthetic: harf bir **erişilebilirlik etkinleştirmesinden**
    ///   geliyor; koordinat gözlem değil, tuş merkezi (§8.9).
    private func perform(touch: CanonicalSession.Touch? = nil,
                         command: ReplayCommand,
                         touchID: Int? = nil,
                         at time: TimeInterval? = nil,
                         synthetic: Bool = false) {
        // **Güvenli alan kontrolü burada.** `textDidChange` üzerinden düşürmeye
        // güvenmek yetmiyordu: o çağrı proxy'nin henüz güncel olmadığı anda
        // koşuyor ve ertelenmiş `readSelection` güvenliği tekrar sormuyordu.
        // Kontrolü mutasyonun kendisine koymak, tamponun parola karakteri
        // görmesini yapısal olarak imkânsız kılıyor.
        if fieldIsSecure { dropBufferIfSecure() }
        // Türetilmiş harf **kaydedilemez** ve bu bir şema eksiği değil bir olgu:
        // kayıt her harfe bir dokunma olgusu bağlamayı şart koşuyor (`touchID`
        // harf komutlarında zorunlu) ve elimizde bir dokunma yok. Tuş merkezini
        // "ham koordinat" diye yazmak, §12'nin toplamak için var olduğu veri
        // kümesinin içine uydurulmuş bir gözlem koymak olurdu.
        //
        // Kaydedici normalde VoiceOver açıkken hiç kurulmuyor; buraya ancak
        // kullanıcı kayıt sürerken VoiceOver'ı açarsa gelinir. Tepki yazma
        // hatasınınkiyle aynı: kaydedici bırakılır, klavye yazmaya devam eder.
        if synthetic, recorder != nil {
            releaseRecorder(reason: "VoiceOver açıldı")
        }
        guard let recorder, let engine = input else {
            // Kayıt yok ama klavye çalışmak zorunda.
            withOwnEdit { applyToFallback(command, at: time, synthetic: synthetic) }
            return
        }
        let t = time ?? ProductionRecorder.now
        withOwnEdit {
            do {
                if let touch { try engine.record(touch) }
                try engine.perform(.init(command: command, touchID: touchID,
                                         timestamp: t), into: self)
                // **Devretmeden önce.** Kişisel sözlüğe kabul edilen kelime
                // devretmeyi tetikliyor (leksikon kayıt dışı değişti) ve
                // devretme yeni koordinatörün sözlüğünü **diskten** okuyor.
                // Diske yazmayı token sınırına bırakmak, tam da kabul edilen
                // kelimeyi bir sonraki denemede kaybettirirdi.
                if engine.wantsPersonalSave {
                    savePersonal()
                    engine.personalSaved()
                }
                // Rezervuarın **canlı** kopyası: devretme koordinatörü sıfırdan
                // kuruyor ve `configure` çağrıldığında `input` çoktan YENİ
                // motoru gösteriyor. Eskisinin öğrendiğini oradan okumak
                // imkânsız; o yüzden her eylemden sonra burada tutuluyor.
                liveCalibration = engine.calibration
                // Sınıra **eylemden sonra** bakılıyor: ortasında devretmek yarım
                // bir mutasyonu iki denemeye bölerdi.
                try recorder.rollOverIfNeeded()
            } catch {
                // Kayıt bozulursa klavye çalışmaya devam etmeli: kullanıcının
                // günlük aracı bu. Kaydedici bırakılıyor, tampon atılıyor.
                self.releaseRecorder(reason: "\(error)")
            }
        }
    }

    /// Kaydediciyi bırakır ve **sebebini** saklar.
    ///
    /// Sessizce bırakmak, kullanıcının kayıt düğmesine bastığını sanıp hiçbir
    /// şey kaydedilmediğini ancak dosyaları açtığında görmesi demekti.
    ///
    /// Yarım kalan token yedek koordinatöre **devrediliyor**. Ölen
    /// koordinatörün yazmakta olduğu yüzey belgede duruyor ve yedek yol boş
    /// başlarsa yüzeyin yalnız yeni kısmını kendi token'ı sanıyor: `kal`
    /// yazılmışken gelen `em` tek başına düzeltilebiliyor ve `kalem` önerisi
    /// belgeyi `kalkalem` yapıyordu. Yüzey **ölen oturumdan** okunuyor,
    /// belgeden ayrıştırılarak değil — biri olgu, diğeri tahmin.
    private func releaseRecorder(reason: String) {
        let carried = input?.composingSurface ?? ""
        recorder = nil
        recorderFailure = reason
        fallback.adoptDetachedSurface(carried)
    }

    /// VoiceOver açıldı ya da kapandı.
    ///
    /// Açılışta kaydedici bırakılıyor; kapanışta geri geliyor. Geri getirme
    /// `startRecorder`'a bırakılıyor, koşulları burada tekrarlanmıyor —
    /// güvenli alan ve token sınırı kontrolleri orada zaten var ve ikinci bir
    /// kopya ayrışırdı.
    @objc private func voiceOverStatusChanged() {
        if UIAccessibility.isVoiceOverRunning {
            if recorder != nil { releaseRecorder(reason: "VoiceOver açık") }
        } else if recorder == nil, !suspendedForSecureField,
                  let loaded = loadedPacks {
            recorderFailure = nil
            startRecorder(with: loaded)
        }
        refreshUI()
    }

    /// Örtü panel açıldı ya da kapandı — erişilebilirlik tarafı.
    ///
    /// ## Panel klavyeyi görsel olarak kapatıyor, ekran okuyucu için kapatmıyordu
    ///
    /// `cancelInteraction()` **parmakları** kesiyor: panel açılırken basılı
    /// duran bir tuş arkada silmeye devam ediyordu ve o düzeltilmişti. Ama
    /// erişilebilirlik etkinleştirmesi parmak değil — panelin arkasındaki tuşlar
    /// erişilebilirlik ağacında duruyor ve VoiceOver kullanıcısı sağa kaydırarak
    /// **görünmeyen** bir klavyeye ulaşabiliyor.
    ///
    /// Bu kusur §8.9'dan önce zararsızdı: tuşlar okunabiliyor ama
    /// etkinleştirilemiyordu, yani en kötü ihtimalle gürültüydü. Etkinleştirme
    /// bağlanınca **gerçek** oldu — panel açıkken görünmeyen bir tuşa basıp
    /// belgeye harf yazmak. Yeni bir özellik eski bir kusuru işler hâle
    /// getirdi; ikisini birlikte kapatmak zorunluydu.
    ///
    /// İki savunma, ayrı gerekçelerle:
    ///
    /// 1. `accessibilityViewIsModal` — panelin kardeşlerini ağaçtan düşürüyor.
    ///    Doğru ve genel çözüm bu; gezinme de panelin içinde kalıyor.
    /// 2. `allowsAccessibilityActivation` — tuş yüzeyinin kendi kapısı.
    ///    Modalliğin doğru uygulanmasına bel bağlamamak için: `cancelInteraction`
    ///    da aynı sebeple var, ve o hatanın bedeli zaten bir kez ödendi.
    ///
    /// Ayrıca `.screenChanged` gönderiliyor: bildirimsiz açılan panelde odak
    /// ⚙︎ düğmesinde kalıyor ve kullanıcı bir panelin açıldığını hiç duymuyor.
    private func overlayPanelDidChange(_ panel: UIView?) {
        panel?.accessibilityViewIsModal = true
        keyboardView.allowsAccessibilityActivation = (panel == nil)
        suggestionBar.accessibilityElementsHidden = panel != nil
        guard UIAccessibility.isVoiceOverRunning else { return }
        // Argüman odağın **nereye** gideceğini söylüyor: panel açılırken panele,
        // kapanırken tuş yüzeyine. `nil` göndermek odağı ekranın başına atardı.
        UIAccessibility.post(notification: .screenChanged,
                             argument: panel ?? keyboardView)
    }

    // MARK: - Boşlukta imleç sürükleme

    /// Jestin durumu. `nil` = kip kapalı.
    ///
    /// Eksen kilidi ve adım aritmetiği çekirdekte (`CursorDragGesture`);
    /// burada kalan tek iş host'a bağlam sormak ve ofseti uygulamak.
    /// Jestin belgeye bağlanmış hâli. Bağlam okuması, eksen kilidi ve ofset
    /// aritmetiği **çekirdekte** (`CursorDragSession`); burada kalan tek iş
    /// ofseti proxy'ye vermek.
    private var cursorDrag: CursorDragSession?

    private func beginCursorDrag() {
        cursorDrag = CursorDragSession(
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            after: textDocumentProxy.documentContextAfterInput ?? "")
    }

    /// - Returns: jest sıfır olmayan bir hareket istediyse `true` — görünüm
    ///   boşluk yazımını buna bakarak bastırıyor.
    private func updateCursorDrag(dx: Double, dy: Double) -> Bool {
        guard var s = cursorDrag else { return false }
        let wasMoving = s.didRequestMove
        let delta = s.update(dx: dx, dy: dy)
        cursorDrag = s
        guard delta != 0 else { return s.didRequestMove }

        // İmleç oynamadan **önce** composing kapatılıyor, senkron.
        //
        // Ertelenmiş `readSelection`'a güvenmek yetmiyordu: jest sürerken
        // ikinci bir parmak harf commit edebiliyor ve o harf, seçim geri
        // çağrısı gelmeden hâlâ açık olan eski token'a yazılıyordu.
        // `handleSelection` ayrıca composing'i yalnız `agreesWithHost`
        // başarısızsa kapatıyor — aynı yüzey belgede başka bir yerde de
        // duruyorsa taşınmış imleci ayırt edemez. Koşulsuz kapatmak iki boşluğu
        // birden kapıyor.
        if !wasMoving { invalidateComposingForCursorMove() }

        // **`withOwnEdit` yok, bilerek.** Kendi düzenlemelerimizi saklamak
        // `textDidChange`'i bastırıyor; burada bastırılmamalı çünkü bağlam,
        // otomatik büyük harf ve adaylar imlecin yeni yerine göre yeniden
        // okunmalı (§8.4).
        textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        return true
    }

    /// İmleç oynadı: yazılmakta olan token'ın belgedeki yeriyle ilgisi kalmadı.
    ///
    /// Kayıt da bu hareketi **anlatamıyor** (`ReplayCommand` karşılığı yok;
    /// uydurulmuş bir ofset başka bir belgede başka bir yeri gösterirdi), o
    /// yüzden deneme **hemen** kapatılıyor. Ertelemek, aradaki pencerede ikinci
    /// bir parmağın commit'ini bilerek bozuk bir denemeye yazmak olurdu.
    private func invalidateComposingForCursorMove() {
        // `withOwnEdit` **yok**: burada belge değiştirilmiyor, yalnız oturum
        // durumu düşürülüyor. Sarmalamak "bu bir düzenleme" demek olurdu.
        if let input {
            input.noteStateChangedOutsideTheLog()
            try? input.invalidateComposing()
        } else {
            fallback.invalidateComposing()
        }
        try? recorder?.rollOverIfNeeded()
    }

    /// Tek kelimelik adım — erişilebilirlik eyleminin yolu.
    ///
    /// Sürükleme durumundan **bağımsız**: jest yok, dolayısıyla eksen kilidi de
    /// yok. Ofset hesabı ve kayıt işaretlemesi yine aynı yerden geçiyor.
    @discardableResult
    private func stepCursorByWord(_ direction: Int) -> Bool {
        let offset = direction < 0
            ? WordBoundaries.toPreviousWordStart(
                before: textDocumentProxy.documentContextBeforeInput ?? "", count: 1)
            : WordBoundaries.toNextWordStart(
                after: textDocumentProxy.documentContextAfterInput ?? "", count: 1)
        guard offset != 0 else { return false }
        // Sürükleme yolundaki koşulsuz kapatmanın aynısı — tek adımlık olması
        // token'ın hâlâ yerinde durduğu anlamına gelmiyor.
        invalidateComposingForCursorMove()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        return true
    }

    private func endCursorDrag() {
        cursorDrag = nil
        // Jest bitti: bağlam, otomatik büyük harf ve adaylar imlecin **yeni**
        // yerine göre okunmalı.
        //
        // Okuma bir run loop turu **erteleniyor**: proxy son
        // `adjustTextPosition`'ı henüz yansıtmamış olabilir ve senkron okumak
        // tam da kaçınmaya çalıştığımız bayat bağlamı okumak olurdu.
        // `textDidChange` da aynı gerekçeyle erteliyor.
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    /// VoiceOver'a tek seferlik bir bildirim.
    ///
    /// Durum satırı bir `CATextLayer` ve çubuğun `accessibilityElements`
    /// listesinde **yok** — yani ekran okuyucu onu hiç görmüyor. Geçici geri
    /// bildirimin (kaydedildi, kaydedilemedi) VoiceOver karşılığı bu; satırı
    /// öğe yapmak onu kalıcı bir gezinme durağına çevirirdi.
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Token sınırında bekleyen kaydedici kurulumunu karşılar.
    ///
    /// Sınırda kurmak bir gecikme değil doğruluk şartı: token ortasında
    /// kurulan kaydedici, yazılmakta olan kelimenin dokunma kanıtını
    /// göremiyor ve ilk commit'te sayım tutmuyordu.
    private func startPendingRecorderIfAtBoundary() {
        guard pendingRecorderStart, recorder == nil, !fieldIsSecure,
              !fallback.session.isComposing, let loaded = loadedPacks
        else { return }
        startRecorder(with: loaded)
    }

    private var recorderFailure: String?
    /// Yüklenen paketler — kaydediciyi yeniden başlatmak için saklanıyor.
    private var loadedPacks: PackLoader.Loaded?
    /// Kaydedici token sınırı bekliyor.
    private var pendingRecorderStart = false
    /// Motor kurulmadan seçilen profilin öğrenicisi.
    private var pendingLearner: CalibrationLearner?

    /// Canlı motorun rezervuarının **son bilinen kopyası**.
    ///
    /// Devretme (`rollOver`) koordinatörü sıfırdan kuruyor ve `configure`
    /// çağrıldığında `input` çoktan yeni motoru gösteriyor: eskisinin
    /// öğrendiğini o an okumak imkânsız. Bu kopya her eylemden sonra
    /// tazeleniyor, dolayısıyla en fazla bir eylem bayat.
    private var liveCalibration: CalibrationLearner?

    /// Yedek yolun komut uygulaması.
    ///
    /// Motorun `apply`'ıyla **aynı kümeyi** karşılıyor; ayrışırsa bozulmuş
    /// durumda klavye başka bir klavye olurdu.
    private func applyToFallback(_ command: ReplayCommand, at time: TimeInterval?,
                                 synthetic: Bool = false) {
        switch command {
        case let .letter(baseKey, display, shifted):
            guard let ch = baseKey.first else { return }
            let sample = TouchSample(down: lastFallbackPoint,
                                     timestamp: time ?? ProductionRecorder.now)
            if shifted {
                fallback.insertUppercaseLetter(ch, uppercase: display,
                                               touch: sample, synthetic: synthetic,
                                               into: self)
            } else {
                fallback.insertLetter(ch, touch: sample, synthetic: synthetic,
                                      into: self)
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

    /// Klavyenin ürettiği **her** dokunma kayda giriyor.
    ///
    /// Güvenli alanda hiçbir şey tamponlanmıyor: kontrol burada da var, çünkü
    /// dokunma kaydı komuttan bağımsız geliyor.
    private func record(_ r: KeyboardView.TouchRecord) {
        if fieldIsSecure { dropBufferIfSecure() }
        guard let engine = input else { return }
        let s = shift.isUppercase
            ? (shift.mode == .locked ? "locked" : "shifted") : "off"
        do { try engine.record(r.canonical(layout: layout, shift: s)) }
        catch {
            recorder = nil
            recorderFailure = "\(error)"
        }
        if r.phase == .ended || r.phase == .cancelled {
            lastTouchID = r.touchID
        }
    }

    /// Son biten dokunmanın kimliği — harf zarfı ona atıf yapıyor.
    private var lastTouchID: Int?

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
        guard fieldIsSecure else { return }
        guard recorder != nil else { return }
        recorder = nil
        // Sebep **kaydediliyor**: yoksa güvenli alandan çıkınca kaydın neden
        // kapalı olduğu bilinmez ve "kayıt hazır değil" kalıcı görünürdü.
        recorderFailure = "parola alanı"
        suspendedForSecureField = true
    }

    /// Güvenli alan yüzünden kapatıldı mı.
    ///
    /// Ayrı bir bayrak: gerçek bir hata (paket yüklenemedi) ile geçici bir
    /// askıya alma aynı şey değil ve ikisini karıştırmak, alandan çıkınca
    /// kaydın hiç dönmemesine yol açıyordu.
    private var suspendedForSecureField = false

    /// Güvenli alandan **çıkıldıysa** kaydı yeniden başlatır.
    private func resumeAfterSecureFieldIfNeeded() {
        guard suspendedForSecureField, !fieldIsSecure, recorder == nil,
              let loaded = loadedPacks else { return }
        suspendedForSecureField = false
        recorderFailure = nil
        startRecorder(with: loaded)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        dropBufferIfSecure()
        resumeAfterSecureFieldIfNeeded()
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
        // **Hangi koordinatör yazıyorsa o haberdar ediliyor.**
        //
        // Burası uzun süre yalnız `input`'u uyarıyordu ve kaydedici çoğu
        // oturumda **yok**: o hâlde imleç oynadığında yedek koordinatörün
        // composing token'ı yerinde kalıyor, belgede başka bir yeri anlattığı
        // hâlde. Sonucu bilinen sınıftan — öneri seçimi `display.count` kadar
        // silip metni bozuyor (§8.9'daki yarım token devrinin aynısı).
        //
        // Kusur yeni değil (host'a dokunup imleci taşımak da aynı yoldan
        // geçiyordu) ama boşluk sürüklemesi onu **sık** hâle getirdi; §8.9'daki
        // örtü panel dersinin aynısı: yeni özellik eski bir kusuru işler yaptı.
        //
        // İkisi birden uyarılmıyor: `handleSelection` seçim varken belgeyi
        // **değiştiriyor** (`beginEditingSelection`) ve iki koordinatör aynı
        // düzenlemeyi iki kez uygulardı.
        selectionNote = withOwnEditResult {
            if let input {
                return try? input.selectionChanged(textDocumentProxy.selectedText, into: self)
            }
            return fallback.handleSelection(textDocumentProxy.selectedText, into: self)
        } ?? nil
        try? recorder?.rollOverIfNeeded()
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

        guard let input else {
            // Kaydedici yokken durum satırı eskiden **hiç** güncellenmiyordu:
            // ekranda son yazılan cümle kalıyor ve kullanıcı kaydın neden
            // durduğunu görmüyordu. Sebep zaten tutuluyordu, yalnız okunmuyordu.
            if let why = recorderFailure {
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
    private func afterTokenBoundary() {
        if input?.wantsCalibrationSave == true {
            saveCalibration()
            input?.calibrationSaved()
        }
        // Kişisel sözlük burada **değil**: yazma devretmeden önce olmak zorunda
        // ve o an `perform`'un içinde (bkz. oradaki not). Sayaç da yok — kabul
        // ender bir olay ve kaybedilirse kullanıcı kelimeyi baştan öğretir.
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
        // Paket gelmeden profil seçilirse `input` nil ve yüklenen öğrenici
        // tamamen kayboluyordu; paket gelince boş öğrenici uygulanıyordu.
        // Yüklenen profil saklanıyor ve motor kurulunca uygulanıyor.
        if let dir = Self.calibrationDirectory {
            let learner = CalibrationStore.loadOrEmpty(from: dir, profile: key)
            // Canlı kopya da **yeni profile** geçiyor. Geçmeseydi bir sonraki
            // devretme, eski geometride öğrenilmiş sapmayı yeni profile
            // taşırdı — profil ayrımının varlık sebebi tam olarak bunu
            // engellemek.
            liveCalibration = learner
            if let engine = input {
                engine.replaceCalibration(learner)
                engine.applyCalibration()
                try? recorder?.rollOverIfNeeded()
            } else {
                // Motor henüz kurulmadı: öğrenici **saklanıyor**. Eskiden
                // düşüyordu ve paket gelince boş öğrenici uygulanıyor, yani
                // kaydedilmiş kalibrasyon profili sessizce kayboluyordu.
                pendingLearner = learner
            }
        }
        refreshUI()
    }

    /// Aktif profilin diskteki rezervuarı; profil henüz kurulmadıysa boş.
    private func loadedCalibration() -> CalibrationLearner? {
        guard let dir = Self.calibrationDirectory,
              let p = calibrationProfile else { return pendingLearner }
        return CalibrationStore.loadOrEmpty(from: dir, profile: p)
    }

    private func saveCalibration() {
        guard let dir = Self.calibrationDirectory, let p = calibrationProfile,
              let input, input.calibration.sampleCount > 0 else { return }
        try? CalibrationStore.save(input.calibration, to: dir, profile: p)
    }

    // MARK: - Kişisel sözlük kalıcılığı (§8.7)

    /// Diskteki sözlüğü **her iki** yola da uygular.
    ///
    /// Yedek yol da kullanıcının kelimelerini bilmeli: kaydedici bozulduğunda
    /// klavye başka bir klavye olmamalı (aynı gerekçe motorun kendisinde de
    /// uygulanıyor). Öğrenilen tarafın **kalıcılığı** yalnız `input`'ta —
    /// kalibrasyonla aynı bölüşüm; iki yazar split-brain üretirdi.
    private static func loadPersonalLexicon() -> PersonalLexicon {
        personalDirectory.map { PersonalLexiconStore.loadOrEmpty(from: $0) }
            ?? PersonalLexicon()
    }

    /// Yedek yola sözlüğü uygular.
    ///
    /// Kaydedici yolunda gerek yok — orada sözlük `configure`'ın parçası ve
    /// her devretmede yeniden veriliyor. Yedek yol `setEngine` ile paketlerden
    /// kurulduğu için onun üstüne **burada** biniyor; bozulmuş durumda klavye
    /// başka bir klavye olmamalı.
    private func applyPersonalLexicon() {
        fallback.replacePersonalLexicon(Self.loadPersonalLexicon())
    }

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
    private func importPersonalFromField()
        -> (added: [String], all: [String], note: String) {
        guard !fieldIsSecure else {
            return ([], (input?.personal ?? fallback.personal).admitted,
                    "parola alanında öğrenme yok")
        }
        let text = (textDocumentProxy.documentContextBeforeInput ?? "")
                 + (textDocumentProxy.documentContextAfterInput ?? "")
        let tokens = PromptTokenizer(layout: layout).tokens(of: text)
        guard !tokens.isEmpty else {
            return ([], (input?.personal ?? fallback.personal).admitted,
                    "bu alanda okunacak metin yok")
        }

        // **Her iki yol da** öğreniyor; kalıcılık yalnız `input`'ta, kişisel
        // sözlüğün geri kalanıyla aynı bölüşüm.
        let report = input?.ingestPersonal(tokens: tokens)
        let fallbackReport = fallback.ingestPersonal(tokens: tokens)
        let effective = report ?? fallbackReport
        savePersonal()
        input?.personalSaved()
        try? recorder?.rollOverIfNeeded()

        let all = (input?.personal ?? fallback.personal).admitted
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

    /// Kullanıcı bir yüzeyi siliyor: **her iki** yoldan da düşüyor ve disk
    /// hemen güncelleniyor.
    ///
    /// Diske yazmak burada `input.personal.isEmpty` kapısına takılabilir —
    /// son kelime silindiğinde dosyanın kalması, klavyeyi bir sonraki açışta
    /// silinen kelimeyi geri getirirdi. O yüzden boş sözlükte dosya siliniyor.
    private func forgetPersonal(_ word: String) {
        input?.forgetPersonal(word)
        fallback.forgetPersonal(word)
        savePersonal()
        input?.personalSaved()
        try? recorder?.rollOverIfNeeded()
    }

    private func savePersonal() {
        guard let dir = Self.personalDirectory, let input else { return }
        if input.personal.isEmpty {
            try? PersonalLexiconStore.delete(from: dir)
        } else {
            try? PersonalLexiconStore.save(input.personal, to: dir)
        }
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
    /// Emoji yüzeyi.
    ///
    /// Giriş **çubukta**, tuş ızgarasında değil: ızgaraya bir yuva eklemek
    /// bütün harf merkezlerini kaydırır, `layoutID` değişir ve öğrenilmiş
    /// kalibrasyon başka bir kovaya düşerdi (⚙︎ ve kayıt düğmesiyle aynı
    /// gerekçe).
    var onEmoji: (() -> Void)?
    /// Klavyeyi kapat.
    ///
    /// Uzantının kendi kapatma yolu yok: sistem klavyesinde bu iş `⌄` tuşunun
    /// ya da alanın dışına dokunmanın; bazı host'larda ikisi de yok ve klavye
    /// ekranın yarısını kaplayıp duruyor.
    ///
    /// Yeri **çubuk**, ızgara değil — emoji, ⚙︎ ve kayıt düğmesiyle aynı
    /// gerekçe: ızgaraya yuva eklemek bütün harf merkezlerini kaydırırdı.
    /// Nokta tuşunda bu bedel bilerek ödendi (kullanıcı yazarken sürekli
    /// lazım); kapatma tuşu o eşiği geçmiyor.
    var onDismiss: (() -> Void)?

    private static let slotCount = 3
    private static let rowHeight: CGFloat = 32
    private static let gearWidth: CGFloat = 34
    /// Kayıt düğmesi de aynı genişlikte.
    ///
    /// **Harf geometrisine dokunmuyor**: tuş satırlarına bir düğme eklemek
    /// bütün merkezleri kaydırır, `layoutID` değişir ve öğrenilmiş kalibrasyon
    /// başka bir kovaya düşerdi.
    private static let captureWidth: CGFloat = 34
    /// Emoji düğmesi — aynı gerekçe, aynı genişlik.
    private static let emojiWidth: CGFloat = 34
    /// Kapatma düğmesi — aynı gerekçe, aynı genişlik.
    private static let dismissWidth: CGFloat = 34

    private var slots: [CATextLayer] = []
    private var slotWords: [String] = Array(repeating: "", count: slotCount)
    private var slotFrames: [CGRect] = []
    private let status = CATextLayer()
    private let settingsButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
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

        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.accessibilityIdentifier = "key.emoji"
        emojiButton.accessibilityLabel = "Emoji"
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        emojiButton.addAction(UIAction { [weak self] _ in self?.onEmoji?() },
                              for: .touchUpInside)
        addSubview(emojiButton)

        // `chevron.down` sistem klavyesinin kapatma simgesiyle aynı: kullanıcı
        // bu şekli zaten "klavyeyi indir" diye biliyor ve öğrenilecek yeni bir
        // şey yok.
        dismissButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        dismissButton.accessibilityIdentifier = "key.dismiss"
        dismissButton.accessibilityLabel = "Klavyeyi kapat"
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() },
                                for: .touchUpInside)
        addSubview(dismissButton)

        // Tek Auto Layout kullanıcısı ayar düğmesi; yazarken hiç dokunulmuyor.
        NSLayoutConstraint.activate([
            dismissButton.topAnchor.constraint(equalTo: topAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor),
            dismissButton.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            dismissButton.widthAnchor.constraint(equalToConstant: Self.dismissWidth),

            emojiButton.topAnchor.constraint(equalTo: topAnchor),
            emojiButton.trailingAnchor.constraint(equalTo: captureButton.leadingAnchor),
            emojiButton.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            emojiButton.widthAnchor.constraint(equalToConstant: Self.emojiWidth),

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

        // Dördüncü düğme de payını alıyor: unutulsaydı öneri yuvaları düğmelerin
        // altına uzanır ve en sağdaki aday `⌄`'nin arkasında kalırdı.
        let usable = max(0, W - Self.gearWidth - Self.captureWidth
                            - Self.emojiWidth - Self.dismissWidth - 6)
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
        invalidateAccessibilityElements()
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
        emojiButton.tintColor = theme.barSecondaryText
        dismissButton.tintColor = theme.barSecondaryText
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
        if changed { invalidateAccessibilityElements() }
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
    // tuş yüzeyiyle aynı yaklaşım, **tembel kurulum dahil**.
    //
    // Liste eskiden `setCandidates`'ta istekli kuruluyordu, yani aday her
    // değiştiğinde — pratikte her tuş vuruşunda. Tuş yüzeyindeki ~45 nesneye
    // göre buradaki 3 nesne küçük, ama iki kardeş uygulamanın farklı davranması
    // kendi başına bir kusur: biri düzeltilirken diğeri unutulur.

    private var cachedAccessibilityElements: [Any]?

    override var accessibilityElements: [Any]? {
        get {
            if cachedAccessibilityElements == nil {
                cachedAccessibilityElements = buildAccessibilityElements()
            }
            return cachedAccessibilityElements
        }
        set { cachedAccessibilityElements = newValue }
    }

    /// Liste bayatladı — bir sonraki soruda yeniden kurulacak. O(1).
    private func invalidateAccessibilityElements() {
        cachedAccessibilityElements = nil
    }

    private func buildAccessibilityElements() -> [Any] {
        var elements: [Any] = []
        for (i, w) in slotWords.enumerated() where !w.isEmpty && i < slotFrames.count {
            let e = ActivatableAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "suggestion.\(i)"
            e.accessibilityLabel = w
            e.accessibilityTraits = .button
            e.accessibilityFrameInContainerSpace = slotFrames[i]
            e.onActivate = { [weak self] in self?.onPick?(w); return true }
            elements.append(e)
        }
        // Düğmeler de listede: özel `accessibilityElements` dizisi yalnız
        // sayılanları görünür kılıyor ve eklenmeyen düğmeye VoiceOver'la
        // ulaşılamıyor. Emoji düğmesi eklendiğinde bu satır güncellenmemişti;
        // düğme ekranda duruyor ama ekran okuyucu için **yoktu**. Hatanın
        // sessiz olmasının sebebi bu: eksiklik yalnız VoiceOver açıkken
        // görünüyor ve hiçbir test o kipte koşmuyor.
        elements.append(dismissButton)
        elements.append(emojiButton)
        elements.append(captureButton)
        elements.append(settingsButton)
        return elements
    }
}

