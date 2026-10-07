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
    /// Klavyenin üstünü kaplayan paneller — aynı anda bir tane.
    private lazy var panels = PanelSlot(host: view)
    /// Son kullanılan emoji — açılışta diskten okunuyor.
    private lazy var emojiRecents = EmojiRecentsStore.load()
    private var keyboardHeight: NSLayoutConstraint!
    private var suggestionBarTop: NSLayoutConstraint!

    /// Bir **harf satırının** yüksekliği: 4 satırlık klavyenin 216 pt'si.
    /// Sayı sırası açılınca ya da boşluk satırı uzayınca klavye **büyür**;
    /// satırları sıkıştırmak tuş merkezlerini birbirine yaklaştırıp uzamsal
    /// ayrımı zayıflatırdı (`KeyboardMetrics.heightUnits`).

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
    /// `init`'te layout ile **aynı** ölçüden kuruluyor (önce varsayılan ölçüyle
    /// kuruluyor ve ilk yeniden kuruluma kadar layout'tan ayrışabiliyordu).
    private var fallback: InputCoordinator
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
        self.fallback = InputCoordinator(layout: l)
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
    private static let configurationTag = RecordingSnapshot.buildConfiguration == "Debug" ? "⚠︎DEBUG · " : ""
    /// Seçili kelime düzenleniyorsa yüzeyi — durum satırı için.
    private var selectionNote: String?

    /// Kalibrasyon profili ve diskteki rezervuar.
    private let calibration = CalibrationPersistence()

    /// Kişisel sözlük (§8.7) — kalibrasyonla **aynı sandbox**, ayrı dizin.
    ///
    /// Profil yok: öğrenilen şey bir yüzey, tuş merkezlerine bağlı değil.
    private static var personalDirectory: URL? { LocalStore.url(LocalStore.Name.personal, isDirectory: true) }

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

    private var resolvedTheme: KeyboardTheme {
        settings.theme.resolved(for: traitCollection)
    }

    private let backdrop = ThemeBackdropView()

    private func applyTheme() {
        let t = resolvedTheme
        backdrop.apply(t)
        keyboardView.theme = t
        suggestionBar.apply(theme: t)
        panels.apply(theme: t)
    }

    // MARK: - Paneller
    //
    // Açma/kapama burada **tek** yoldan: önce her panelin kendi kopyası vardı
    // ve hangisinin hangisini kapattığı, hangisinin token'ı kapattığı panelden
    // panele değişiyordu.

    private func togglePanel(_ kind: PanelSlot.Kind) {
        let wasOpen = panels.kind == kind
        closePanel()
        if !wasOpen { openPanel(kind) }
    }

    private func openPanel(_ kind: PanelSlot.Kind) {
        // Panel klavyenin üstünü kaplıyor ama **zaten basılı** parmaklar
        // olaylarını almaya devam ediyor: ⌫'yi basılı tutarken ikinci parmakla
        // ⚙︎'ye basmak panelin arkasında silmeyi sürdürüyordu.
        keyboardView.cancelInteraction()
        // Yazılmakta olan token burada kapanıyor. Ayar geometriyi
        // değiştirebilir ve tampondaki dokunmalar eski normalize uzayda
        // kaydedilmiş olur; emoji ve pano girişi de token sınırı.
        closeComposition()
        selectionNote = nil
        // Token kapandı: bekleyen profil geçişi ve kalibrasyon kaydı burada
        // karşılanmalı. Yoksa composition sırasında cihaz döndürülüp panel
        // açıldığında `pendingProfile` asılı kalıyor ve panelden sonraki ilk
        // kelime **eski** yönelimin kalibrasyonuyla işleniyordu.
        afterTokenBoundary()

        let panel: OverlayPanel
        var bottom = view.bottomAnchor
        switch kind {
        case .settings: panel = makeSettingsPanel()
        case .emoji: panel = makeEmojiPanel()
        case .clipboard:
            checkPasteboard()
            panel = makeClipboardPanel()
        case .media: panel = makeMediaPanel()
        case .ai:
            panel = aiCard.makePanel(theme: resolvedTheme)
            // Kart klavyenin **üstünde**; klavye yukarı uzuyor (`aiCardHeightChanged`).
            bottom = suggestionBar.topAnchor
        }
        panels.show(kind, panel, bottom: bottom)
        if kind == .ai {
            suggestionBar.aiActive = true
            aiCard.didOpen()
        }
        overlayPanelDidChange(panel)
        refreshUI()
    }

    private func closePanel() {
        guard let kind = panels.close() else { return }
        switch kind {
        case .settings:
            // Bekleyen ağır kurulum burada kesinleşiyor: panel kapanır kapanmaz
            // yazılabiliyor ve o an decoder yeni geometriyle kurulmuş olmalı.
            rebuildModel()
        case .ai:
            aiCard.didClose()
            suggestionBar.aiActive = false
            suggestionBarTop.constant = 0
        case .emoji, .clipboard, .media: break
        }
        overlayPanelDidChange(nil)
        refreshUI()
    }

    private func makeSettingsPanel() -> KeyboardSettingsPanel {
        let p = KeyboardSettingsPanel(
            settings: settings,
            theme: resolvedTheme,
            showsGlobe: needsInputModeSwitchKey,
            // Liste **motordan** okunuyor, diskten değil: kullanıcı o an
            // klavyenin bildiği kelimeleri görmeli. Kaydedici bozuksa yedek
            // yolun sözlüğü de aynı dosyadan yüklendi.
            personalWords: personalWords)
        p.onChange = { [weak self] s in self?.apply(settings: s) }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onCapture = { [weak self] in
            self?.closePanel()
            self?.captureSlice()
        }
        p.onDismissKeyboard = { [weak self] in self?.dismissWithPanels() }
        p.onOpenApp = { [weak self] in
            guard let self, !self.openHome() else { return }
            self.showToast(CommonText.fullAccess(open: CommonText.app))
        }
        p.onForgetPersonal = { [weak self] word in self?.forgetPersonal(word) }
        p.onImportPersonal = { [weak self] in
            self?.importPersonalFromField() ?? ([], [], "klavye hazır değil")
        }
        return p
    }

    private func makeEmojiPanel() -> EmojiPanel {
        let p = EmojiPanel(theme: resolvedTheme, recents: emojiRecents)
        p.onPick = { [weak self] emoji in self?.insertEmoji(emoji) }
        p.onBackspace = { [weak self] in self?.emojiBackspace() }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onClipboard = { [weak self] in self?.togglePanel(.clipboard) }
        p.onMedia = { [weak self] in self?.togglePanel(.media) }
        return p
    }

    private func makeClipboardPanel() -> ClipboardPanel {
        let p = ClipboardPanel(items: clipboard.store.items, theme: resolvedTheme)
        p.onPickText = { [weak self] t in
            self?.closePanel()
            self?.insertAtBoundary(t)
        }
        p.onPickImage = { [weak self] name in
            guard let self, let image = ClipboardStore.image(named: name) else { return }
            self.clipboard.put(image: image)
            self.panels.current(ClipboardPanel.self)?.flash(PasteHint.image())
        }
        p.onClear = { [weak self] in self?.clipboard.clear() }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onEmoji = { [weak self] in self?.togglePanel(.emoji) }
        return p
    }

    private func makeMediaPanel() -> MediaPanel {
        let p = MediaPanel(theme: resolvedTheme)
        p.onCopied = { [weak self] in
            // Kendi koyduğumuz panoyu geçmişe almayalım.
            self?.clipboard.noteOwnWrite()
            self?.showToast(PasteHint.copied)
        }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onEmoji = { [weak self] in self?.togglePanel(.emoji) }
        return p
    }

    /// `dismissKeyboard()` uzantının kendi kapanma yolu; host'a "işim bitti"
    /// demenin desteklenen tek biçimi. Açık panel önce kapanıyor: panel
    /// `view`'ın alt görünümü ve klavye kapanınca ekranda kalmıyor ama bir
    /// sonraki açılışta **açık** geliyordu.
    private func dismissWithPanels() {
        closePanel()
        dismissKeyboard()
    }

    /// Uygulamanın ana ekranı (Tam Erişim gerekli).
    private func openHome() -> Bool {
        DeepLink.url(.home).map { openURL($0) } ?? false
    }

    // MARK: - Ortak adımlar

    /// Yazılmakta olan token kapanıyor; kayda girmeyen durum değişikliği
    /// denemeyi kapatıyor. Klavye belgeye kendi yolundan başka bir şey
    /// yazmadan (panel, kısayol, kart, dikte) önce **hep** bu.
    func closeComposition() {
        withOwnEdit { try? input?.invalidateComposing() }
        try? recorder?.rollOverIfNeeded()
    }

    /// Token sınırında bir ekleme oldu (emoji, pano, kısayol, tahmin):
    /// çift dokunuş zinciri kesiliyor, sınır işleri ve otomatik büyük harf
    /// yeniden, çubuk tazeleniyor.
    private func didInsertAtBoundary() {
        shift.didInterruptChain()
        afterTokenBoundary()
        startPendingRecorderIfAtBoundary()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Metin kayda geçen yoldan (sembol: token sınırı, düzeltme yok) giriyor —
    /// emoji, pano, dikte ve kart sonucu aynı yol.
    func insertAtBoundary(_ text: String) {
        perform(command: .symbol(text))
        didInsertAtBoundary()
    }

    /// İmleçten hemen önce `suffix` duruyorsa onu siler (kayda geçen ⌫'lerle).
    /// Belgede gerçekten o metin duruyor mu yeniden bakılıyor — bayat bir
    /// öneriyle başka bir şeyi silmemek için.
    @discardableResult
    private func deleteTrailing(_ suffix: String) -> Bool {
        guard textDocumentProxy.documentContextBeforeInput?.hasSuffix(suffix) == true else { return false }
        for _ in 0..<suffix.count { perform(command: .backspaceTap) }
        return true
    }

    private var isComposing: Bool { input?.isComposing ?? fallback.session.isComposing }
    /// Klavyenin o an bildiği kişisel kelimeler (kaydedici bozuksa yedek yolunki).
    private var personalWords: [String] { (input?.personal ?? fallback.personal).admitted }

    // MARK: - Kısayollar

    /// Çubukta gösterilen kısayol ve onu tetikleyen metin.
    private var activeShortcut: (trigger: String, item: TextShortcut)?
    /// `/` ile başlayan son kelimeye uyan yapay zeka tuşları.
    private var activeCommands: [AIAction] = []
    private var commandToken = ""
    private static let commandMark = "✦ "

    /// Son kelime `/` ile başlıyorsa adı o önekle başlayan tuşlar.
    static func slashCommand(before: String, actions: [AIAction]) -> (String, [AIAction])? {
        guard let token = before.split(separator: " ", omittingEmptySubsequences: false).last,
              token.hasPrefix("/"), !token.dropFirst().contains("/") else { return nil }
        // Aksansız da eşleşsin: "/cevir" → "Çevir".
        let fold = { (s: String) in s.trFolded.replacingOccurrences(of: " ", with: "") }
        let q = fold(String(token.dropFirst()))
        let hits = actions.filter { fold($0.name).hasPrefix(q) }
        return hits.isEmpty ? nil : (String(token), hits)
    }

    private func refreshShortcut() {
        activeShortcut = nil
        activeCommands = []
        defer {
            if let s = activeShortcut, s.item.isMedia {
                suggestionBar.setShortcut(s.item.kind == .gif ? "GIF, panoya kopyala" : "Çıkartma, panoya kopyala",
                                          image: shortcutThumb(s.item.output))
            } else {
                suggestionBar.setShortcut(activeShortcut?.item.output)
            }
        }
        guard !fieldIsSecure,
              let before = textDocumentProxy.documentContextBeforeInput else { return }
        // `/çe` → yapay zeka tuşları (tasarım 23). Öneri satırının tamamını
        // alıyor; `refreshUI` adayların yerine bunları koyuyor.
        if let (token, hits) = Self.slashCommand(before: before, actions: settings.aiActions) {
            commandToken = token
            activeCommands = hits
            return
        }
        // Az önce emoji yazıldıysa aynısı ilk yuvada: arka arkaya basıp
        // çoğaltılabilsin (😂😂😂). Tetikleyici boş — hiçbir şey silinmiyor.
        if let last = before.last, Self.isEmoji(last) {
            activeShortcut = ("", TextShortcut(trigger: "", output: String(last)))
            return
        }
        for token in ShortcutLibrary.candidates(before: before) {
            // Öğesi Stüdyo'dan silinmiş çıkartma/GIF kısayolu eşleşmiyor.
            if let hit = ShortcutLibrary.matches(token: token, list: settings.shortcuts)
                .first(where: { !$0.isMedia || shortcutThumb($0.output) != nil }) {
                activeShortcut = (token, hit)
                return
            }
        }
        // Hatırlama aynı yuvayı kullanıyor: yazılan önek → daha önce yazılan
        // tam token (IP, e-posta…). Uygulama yolu da aynı.
        if settings.recallTokens, let raw = ShortcutLibrary.candidates(before: before).first,
           let hit = history.recall(lastToken: raw) {
            activeShortcut = (hit.prefix, TextShortcut(trigger: hit.prefix, output: hit.full, kind: .text))
        }
    }

    /// Emoji olarak **görünen** karakter mi. `isEmoji` rakamlar ve `#` için
    /// de doğru; sunum ya da VS16 şartı onları eliyor.
    static func isEmoji(_ c: Character) -> Bool {
        let sc = c.unicodeScalars
        return sc.contains { $0.properties.isEmojiPresentation }
            || sc.contains { $0.value == 0xFE0F }
            || (sc.count > 1 && sc.first?.properties.isEmoji == true && !(sc.first?.properties.numericType != nil))
    }

    /// Küçük resimler önbellekte: kısayol her tuşta yeniden aranıyor ve
    /// diskten okumak her basışa bir dosya okuması eklerdi.
    private var thumbCache: [String: UIImage] = [:]
    private func shortcutThumb(_ id: String) -> UIImage? {
        if let t = thumbCache[id] { return t }
        guard let item = MediaStore.item(id: id), let t = MediaStore.thumbnail(item) else { return nil }
        thumbCache[id] = t
        return t
    }

    /// Tetikleyiciyi silip çıktıyı yazar — kayda geçen yoldan: önce token
    /// kapanıyor, sonra her karakter bir `⌫`, sonra çıktı sembol olarak.
    private func applyShortcut() {
        guard let s = activeShortcut else { return }
        if s.item.isMedia { applyMediaShortcut(s.trigger, id: s.item.output); return }
        closeComposition()
        activeShortcut = nil
        guard deleteTrailing(s.trigger) else { refreshUI(); return }
        insertAtBoundary(s.item.output)
    }

    /// Çıkartma/GIF kısayolu: tetikleyici silinip öğe panoya konuyor —
    /// iOS klavyenin belgeye resim koymasına izin vermiyor.
    private func applyMediaShortcut(_ trigger: String, id: String) {
        closeComposition()
        activeShortcut = nil
        guard let item = MediaStore.item(id: id), hasFullAccess, MediaStore.copyToPasteboard(item) else {
            refreshUI()
            showToast(CommonText.fullAccess(failed: "Panoya konamadı"))
            return
        }
        clipboard.noteOwnWrite()
        deleteTrailing(trigger)
        afterTokenBoundary()
        updateAutoCapitalization()
        refreshUI()
        showToast(PasteHint.placed)
    }

    /// `/çe` yazılıp öneriden seçildi: kelime (ve önündeki boşluk) siliniyor,
    /// tuş kartta ya da uygulamada çalışıyor.
    private func runCommand(_ a: AIAction) {
        closeComposition()
        if deleteTrailing(commandToken) {
            // "metin /çe" → "metin".
            if textDocumentProxy.documentContextBeforeInput?.last == " " { perform(command: .backspaceTap) }
        }
        activeCommands = []
        aiCard.run(command: a)
        refreshUI()
    }

    // MARK: - Yazma geçmişi (sonraki kelime, hatırlama)

    private let history = TypingHistory()
    private var predictedNext: [String] = []

    private func observeHistory() {
        guard settings.predictNext || settings.recallTokens, !fieldIsSecure,
              let before = textDocumentProxy.documentContextBeforeInput else { return }
        history.observe(before: before)
    }

    private func nextWordPredictions() -> [String] {
        guard settings.predictNext, !fieldIsSecure, !isComposing,
              let before = textDocumentProxy.documentContextBeforeInput else { return [] }
        return history.nextWords(before: before)
    }

    /// Tahmin edilen kelime + boşluk — sembol yolundan (kayda geçen bir
    /// token sınırı), sonra boşluk.
    private func insertPredicted(_ word: String) {
        perform(command: .symbol(word))
        perform(command: .space)
        predictedNext = []
        didInsertAtBoundary()
    }

    // MARK: - Sesle yazma

    private lazy var dictation = DictationReceiver { [weak self] in self?.consumeDictation() }

    /// Uygulamanın dikte ekranından gelen metni yazar (`AppGroup.handoffTTL` içinde).
    private func consumeDictation() {
        guard let pending = DictationHandoff.pending() else { return }
        // Yazılamayacak durumlarda metin **duruyor**: kullanıcı başka bir alana
        // geçince (süre içinde) yine gelsin. Neden yazılmadığı günlükte.
        if let why = DictationReceiver.blocker(fullAccess: hasFullAccess, secureField: fieldIsSecure,
                                               onScreen: isOnScreen) {
            DictationReceiver.log(pending.text, status: .error, detail: why)
            return
        }
        // Yazılabilir: şimdi atomik sahiplen (okuduğumuzdan sonra gelen yeni metin korunur).
        guard let claimed = DictationHandoff.claim(), !claimed.text.isEmpty else { return }
        guard claimed.isFresh else {
            DictationReceiver.log(claimed.text, status: .error, detail: "\(AppGroup.handoffTTLText)dan eski; yazılmadı.")
            return
        }
        closeComposition()
        let text = claimed.text.spaced(after: textDocumentProxy.documentContextBeforeInput)
        insertAtBoundary(text)
        DictationReceiver.log(claimed.text, status: .ok, detail: "\(text.count) harf yazıldı.")
        showToast("Sesle yazılan eklendi")
    }

    // MARK: - Uygulama kısayolları

    /// Seçili metin, yoksa panodaki metinle uygulamayı açar.
    ///
    /// Resim adresle taşınamıyor: panodaysa orada kalıyor ve kullanıcıya
    /// "yapıştır" deniyor. Metni `q` almayan uygulamalarda metin de panoya
    /// konuyor.
    private func openApp(_ id: String) {
        guard let app = AIApp.byID[id] else { return }
        let imageOnBoard = clipboard.hasImage(allowed: hasFullAccess)
        var text = textDocumentProxy.selectedText
        if (text ?? "").isEmpty, !imageOnBoard { text = clipboard.string(allowed: hasFullAccess) }
        let carried = text.flatMap(\.nilIfEmpty)
        if let t = carried, !app.takesText, hasFullAccess { clipboard.put(string: t) }
        guard let url = app.url(text: app.takesText ? carried : nil) else { return }
        guard openURL(url) else {
            showToast(CommonText.fullAccess(open: app.name))
            return
        }
        if imageOnBoard {
            showToast(PasteHint.image(in: app.name))
        } else if carried != nil, !app.takesText {
            showToast(PasteHint.text(in: app.name))
        }
    }

    // MARK: - Fontlu yazı (tasarım 24)

    private var fancy = FancyTextMode()

    private func toggleFancy() {
        fancy.toggle()
        applyFancy()
    }

    private func pickFancyStyle(_ i: Int) {
        fancy.pick(i)
        applyFancy()
    }

    private func applyFancy() {
        suggestionBar.fontsActive = fancy.isOpen
        suggestionBar.showStyles(fancy.samples, selected: fancy.selectedIndex)
        if let s = fancy.style {
            keyboardView.letterTransform = { FancyText.apply(s, to: $0) }
            keyboardView.spaceTitle = FancyTextMode.name(s)
        } else {
            keyboardView.letterTransform = nil
            keyboardView.spaceTitle = nil
        }
        refreshUI()
    }

    // MARK: - Yapay zeka kartı (`AICardController`)

    private lazy var aiCard = AICardController(host: self)

    /// Uzantıdan adres açmak. iOS klavyeye `extensionContext.open` vermiyor;
    /// yanıtlayıcı zincirinde `UIApplication`'a ulaşıp onun `open`'ı
    /// çağrılıyor. Yalnız Tam Erişimle çalışıyor.
    @discardableResult
    func openURL(_ url: URL) -> Bool { bkOpenURL(url) }

    // MARK: - Pano (`ClipboardWatcher`)

    private(set) lazy var clipboard: ClipboardWatcher = {
        let c = ClipboardWatcher()
        c.onChange = { [weak self] in
            guard let self else { return }
            self.panels.current(ClipboardPanel.self)?.update(items: self.clipboard.store.items)
            self.refreshClipChip()
        }
        return c
    }()

    private func checkPasteboard() {
        clipboard.check(allowed: hasFullAccess && !fieldIsSecure)
    }

    private func refreshClipChip() {
        let chip = isComposing ? nil : clipboard.chip
        suggestionBar.showClip(image: chip?.image, text: chip?.text)
    }

    private func useRecentClip() {
        guard let c = clipboard.chip else { return }
        if c.image != nil {
            showToast(PasteHint.image())
        } else if case let .text(t)? = clipboard.store.items.first {
            insertAtBoundary(t)
        }
        clipboard.consumeRecent()
        refreshClipChip()
    }

    // MARK: - Bilgi balonu

    private lazy var toast = Toast(in: view)

    /// Kısa bilgi balonu — klavyenin üstünde.
    func showToast(_ text: String) { toast.show(text, theme: resolvedTheme) }

    // MARK: - Emoji

    /// Emoji **sembol yolundan** giriyor.
    ///
    /// Doğrudan `textDocumentProxy.insertText` çağırmak kaydın görmediği bir
    /// mutasyon üretirdi (§12.6) ve defter belgeyle ayrışırdı. Sembolle aynı
    /// yol olması ayrıca doğru semantiği veriyor: emoji bir **token sınırı**,
    /// kod çözmeye girmiyor ve düzeltme denenmiyor. Güvenli alanda da
    /// yazılabilmeli; `perform` tamponu zaten düşürüyor.
    private func insertEmoji(_ emoji: String) {
        insertAtBoundary(emoji)
        if emojiRecents.use(emoji) {
            EmojiRecentsStore.save(emojiRecents)
            panels.current(EmojiPanel.self)?.update(recents: emojiRecents)
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
    /// `persist: false` — depodan yeni okunan değer geri yazılmıyor: okuma ile
    /// yazma arasında uygulama kaydederse onun değişikliği ezilirdi.
    private func apply(settings new: KeyboardSettings, persist: Bool = true) {
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
        keyboardView.apply(layout: layout, metrics: settings.metrics)
        // Profil anahtarı `layout.id`'yi taşıyor; geometri değişince
        // `refreshCalibrationProfile` yeni kovaya geçiyor. Yeni profil
        // `viewDidLayoutSubviews`'te kuruluyor: burada klavyenin yeni boyutu
        // henüz ölçülmedi ve profil anahtarı ölçüyü de taşıyor.
        calibration.reset()
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
        dropBufferIfSecure()
        checkPasteboard()
        resumeAfterSecureFieldIfNeeded()
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
        recorder = nil
        suspendedForSecureField = false
        // Yalnız zamanlayıcı iptal ediliyor; "kirli" bilgisi `layout.id`
        // farkında duruyor ve `viewWillAppear` onu topluyor.
        modelRebuild?.invalidate()
        modelRebuild = nil
        saveCalibration()          // biriken örnekler kaybolmasın
        history.flush()
        // Panel açık kalırsa bir sonraki açılışta açık gelirdi (kartla klavye de uzun).
        closePanel()
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
        startRecorder(with: loaded)
        loadReport = loaded.report
        // Profil layout sırasında, motordan ÖNCE kurulmuştu;
        // kaydedilmiş kalibrasyon ancak burada uygulanabilir.
        if let input { calibration.engineDidLoad(input) }
        // Kalibrasyon motoru değiştirdi: mevcut denemenin snapshot'ı
        // artık onu anlatmıyor, yenisine geçiliyor.
        try? recorder?.rollOverIfNeeded()
        refreshUI()
    }

    // MARK: - Girdi

    private func handle(_ hit: KeyboardView.KeyHit,
                        _ how: KeyboardView.KeyActivation = .touch) {
        // Türetilmiş kanıt yalnız **harf** yolunda anlam taşıyor: rakam, sembol
        // ve işlev tuşları zaten kod çözmeye girmiyor ve hiçbir uzamsal iddiada
        // bulunmuyorlar.
        let synthetic = how == .accessibility
        switch hit {
        case let .letter(index, _) where fancy.style != nil:
            // Fontlu yazı: harf kod çözmeye girmiyor, stilli karakter olarak
            // doğrudan yazılıyor (sembol yolu — token kapanıyor, düzeltme yok).
            let ch = layout.keys[index].char
            let plain = shift.isUppercase ? TurkishText.uppercased(ch) : String(ch)
            selectionNote = nil
            perform(command: .symbol(fancy.styled(plain) ?? plain))
            shift.didEmitLetter()
            syncKeyboardState()
            afterTokenBoundary()
            refreshUI()

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
                                        ? TurkishText.uppercased(ch)
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
            perform(command: .symbol(fancy.styled(String(ch)) ?? String(ch)))
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
        if word.hasPrefix(Self.commandMark),
           let a = activeCommands.first(where: { Self.commandMark + $0.name == word }) {
            runCommand(a)
            return
        }
        if predictedNext.contains(word) { insertPredicted(word); return }
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
        RecordingLibrary.directory
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
                        learner: self?.calibration.learnerForNewEngine())
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
                buildConfiguration: RecordingSnapshot.buildConfiguration,
                appVersion: RecordingSnapshot.appVersion(Bundle(for: KeyboardViewController.self)),
                build: RecordingSnapshot.buildManifest(Bundle(for: KeyboardViewController.self)),
                policy: .init(RecordingPolicy.behavior)),
            geometry: geometry)
    }

    /// Klavyenin **gerçek** geometrisi.
    ///
    /// Önce sıfır bounds ve daima `portrait` yazılıyordu: landscape'te
    /// `rawX = 700` olan bir dokunma `boundsWidth = 0, portrait` diyen bir
    /// kayda giriyor ve normalize uzay yeniden kurulamıyordu.
    private func geometrySnapshot() -> CanonicalSession.Geometry {
        RecordingSnapshot.geometry(layout: layout, keyboard: keyboardView, host: view)
    }

    /// VC yokken kullanılan yer tutucu — pratikte erişilmiyor.
    private static func emptyGeometry(layout: KeyLayout) -> CanonicalSession.Geometry {
        RecordingSnapshot.geometry(layout: layout, keyboard: nil, host: UIView())
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
                calibration.live = engine.calibration
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
        } else if !suspendedForSecureField {
            restartRecorder()
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

    /// Jestin belgeye bağlanmış hâli. Bağlam okuması, ivme ve satır
    /// aritmetiği **çekirdekte** (`CursorTrackpad`); burada kalan tek iş
    /// ofseti proxy'ye vermek.
    private var cursorDrag: CursorTrackpad?
    private var cursorDragMoved = false

    private func beginCursorDrag() {
        cursorDragMoved = false
        cursorDrag = CursorTrackpad(
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            after: textDocumentProxy.documentContextAfterInput ?? "")
    }

    /// - Returns: jest sıfır olmayan bir hareket istediyse `true` — görünüm
    ///   boşluk yazımını buna bakarak bastırıyor.
    private func updateCursorDrag(dx: Double, dy: Double, time: TimeInterval) -> Int {
        guard var s = cursorDrag else { return 0 }
        let wasMoving = cursorDragMoved
        let delta = s.update(dx: dx, dy: dy, time: time)
        cursorDrag = s
        guard delta != 0 else { return 0 }
        cursorDragMoved = true

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
        return delta
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
        guard pendingRecorderStart, !fieldIsSecure, !fallback.session.isComposing else { return }
        restartRecorder()
    }

    /// Bırakılmış kaydediciyi yeniden kurmayı dener. Kurulum koşulları (güvenli
    /// alan, VoiceOver, token sınırı) `startRecorder`'da — burada tekrarlanmıyor.
    private func restartRecorder() {
        guard recorder == nil, let loaded = loadedPacks else { return }
        recorderFailure = nil
        startRecorder(with: loaded)
    }

    private var recorderFailure: String?
    /// Yüklenen paketler — kaydediciyi yeniden başlatmak için saklanıyor.
    private var loadedPacks: PackLoader.Loaded?
    /// Kaydedici token sınırı bekliyor.
    private var pendingRecorderStart = false
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

    /// Belgeye **kendi** düzenlememiz: o sırada gelen `textDidChange` host
    /// uzlaştırmasını çalıştırmıyor (kendi ara hâllerimize bakmak olurdu).
    @discardableResult
    func withOwnEdit<T>(_ body: () -> T) -> T {
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
        // Hata `releaseRecorder`'dan geçiyor: yarım token yedek yola devredilmeli
        // ("kalkalem" — bkz. orası). Önce burada elle bırakılıyordu.
        do { try engine.record(r.canonical(layout: layout, shift: s)) }
        catch { releaseRecorder(reason: "\(error)") }
        if r.phase == .ended || r.phase == .cancelled {
            lastTouchID = r.touchID
        }
    }

    /// Son biten dokunmanın kimliği — harf zarfı ona atıf yapıyor.
    private var lastTouchID: Int?


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
        guard suspendedForSecureField, !fieldIsSecure, recorder == nil else { return }
        suspendedForSecureField = false
        restartRecorder()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        checkPasteboard()
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
        selectionNote = withOwnEdit {
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
        refreshClipChip()
        refreshShortcut()
        // Bozulmuş durumda da öneri gösteriliyor: boş çubuk "aday yok" demek
        // olurdu, oysa yalnız kayıt yok.
        let engineWords = input?.suggestionSurfaces() ?? fallback.suggestionSurfaces()
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
        observeHistory()
        if input?.wantsCalibrationSave == true {
            saveCalibration()
            input?.calibrationSaved()
        }
        // Kişisel sözlük burada **değil**: yazma devretmeden önce olmak zorunda
        // ve o an `perform`'un içinde (bkz. oradaki not). Sayaç da yok — kabul
        // ender bir olay ve kaybedilirse kullanıcı kelimeyi baştan öğretir.
        if !isComposing, calibration.applyPending(engine: input) { calibrationDidSwitch() }
    }

    private func refreshCalibrationProfile() {
        guard let key = CalibrationPersistence.profileKey(
            layoutID: layout.id, size: keyboardView.bounds.size,
            isPad: traitCollection.userInterfaceIdiom == .pad,
            screenWidth: view.window?.screen.bounds.width, scale: traitCollection.displayScale)
        else { return }
        if calibration.request(key, composing: isComposing, engine: input) { calibrationDidSwitch() }
    }

    /// Profil değişti: motor yeni kalibrasyonla çalışıyor, deneme devrediliyor.
    private func calibrationDidSwitch() {
        try? recorder?.rollOverIfNeeded()
        refreshUI()
    }

    private func saveCalibration() { calibration.save(input) }

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
        guard !fieldIsSecure else { return ([], personalWords, "parola alanında öğrenme yok") }
        let text = (textDocumentProxy.documentContextBeforeInput ?? "")
                 + (textDocumentProxy.documentContextAfterInput ?? "")
        // Yazma geçmişi de bu metinden öğreniyor (sonraki kelime, hatırlama).
        history.ingest(text: text)
        let tokens = PromptTokenizer(layout: layout).tokens(of: text)
        guard !tokens.isEmpty else { return ([], personalWords, "bu alanda okunacak metin yok") }

        // **Her iki yol da** öğreniyor; kalıcılık yalnız `input`'ta, kişisel
        // sözlüğün geri kalanıyla aynı bölüşüm.
        let report = input?.ingestPersonal(tokens: tokens)
        let fallbackReport = fallback.ingestPersonal(tokens: tokens)
        let effective = report ?? fallbackReport
        personalLexiconChanged()

        let all = personalWords
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
        personalLexiconChanged()
    }

    /// Sözlük kayıt dışı değişti: diske yazılıyor, motora bildiriliyor ve
    /// deneme devrediliyor (yeni koordinatör sözlüğü diskten okuyor).
    private func personalLexiconChanged() {
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

/// Yapay zeka kartının klavyeye açılan penceresi.
extension KeyboardViewController: AICardHost {
    var isOnScreen: Bool { view.window != nil }
    var aiActions: [AIAction] { settings.aiActions }

    func openAICard() {
        guard panels.kind != .ai else { return }
        closePanel()
        openPanel(.ai)
    }

    func closeAICard() {
        guard panels.kind == .ai else { return }
        closePanel()
    }

    /// Kart açılınca klavye **yukarı** uzuyor: çubuğun üstü aşağı itiliyor,
    /// giriş görünümü kartın boyu kadar büyüyor.
    func aiCardHeightChanged() {
        guard let p = panels.current(AIPanel.self) else { return }
        let h = ceil(p.fittingHeight(width: view.bounds.width))
        guard abs(suggestionBarTop.constant - h) > 0.5 else { return }
        suggestionBarTop.constant = h
        view.setNeedsLayout()
    }

    func didEditFromCard() {
        afterTokenBoundary()
        updateAutoCapitalization()
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
