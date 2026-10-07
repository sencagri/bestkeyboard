import UIKit
import KBGeometry
import KBRuntime

/// Klavyenin üstünü kaplayan ayar paneli.
///
/// ## Neden klavyenin içinde
///
/// ⚙︎ normalde uygulamayı açıyor (ayarların tek yeri orası). Tam Erişim
/// kapalıyken klavye uygulamayı açamıyor ve ortak depoyu göremiyor; o zaman
/// bu panel açılıyor ve ayarlar klavyenin kendi deposuna yazılıyor
/// (`KeyboardSettingsStore`).
///
/// ## Neden Auto Layout
///
/// §11.B Auto Layout'u **yazma yolunda** yasaklıyor. Panel açıkken yazılmıyor;
/// buradaki maliyet ölçülebilir bir yere düşmüyor.
final class KeyboardSettingsPanel: UIView {

    /// Her değişimde çağrılır — klavye anında güncellenir, "uygula" yok.
    /// Ölçüyü seçerken sonucu görmemek, kapatıp açmayı gerektirirdi.
    var onChange: ((KeyboardSettings) -> Void)?
    var onClose: (() -> Void)?
    /// Geliştirici: son yazılan dilimi kayda al (öneri çubuğundaki ⏺ buraya taşındı).
    var onCapture: (() -> Void)?
    /// Klavyeyi indir — öneri çubuğundaki ⌄ buraya taşındı.
    var onDismissKeyboard: (() -> Void)?
    let dismissButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    /// Uygulamayı aç.
    var onOpenApp: (() -> Void)?
    private let quickLearn = UIButton(type: .system)
    let quickNote = UILabel()
    let openApp = UIButton(type: .system)
    private let advancedToggle = UIButton(type: .system)
    private let advanced = UIStackView()
    private(set) var chipButtons: [(UISwitch, UIButton, UIColor)] = []

    /// Anahtarı büyük renkli bir düğmeyle sürüyor — gizli `UISwitch` tek
    /// doğruluk kaynağı, mevcut eylemleri değişmeden çalışıyor.
    private func quickChip(_ sw: UISwitch, _ title: String, _ color: UIColor) -> UIButton {
        let b = UIButton(type: .system)
        b.layer.cornerRadius = 14
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.heightAnchor.constraint(equalToConstant: 60).isActive = true
        b.accessibilityLabel = title
        b.addAction(UIAction { [weak self, weak sw] _ in
            guard let sw else { return }
            sw.setOn(!sw.isOn, animated: false)
            sw.sendActions(for: .valueChanged)
            self?.refreshChips()
        }, for: .touchUpInside)
        b.setTitle(title, for: .normal)
        chipButtons.append((sw, b, color))
        return b
    }

    func refreshChips() {
        for (sw, b, color) in chipButtons {
            let on = sw.isOn
            let title = (b.accessibilityLabel ?? "") + "\n" + (on ? "Açık" : "Kapalı")
            b.setAttributedTitle(NSAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: on ? color : theme.panelText.withAlphaComponent(0.7),
            ]), for: .normal)
            b.backgroundColor = on ? color.withAlphaComponent(0.16) : theme.panelText.withAlphaComponent(0.06)
            b.accessibilityValue = on ? "açık" : "kapalı"
        }
    }
    /// Kullanıcı kişisel sözlükten bir yüzeyi siliyor (§8.7).
    ///
    /// **Gerekli**, süs değil: kabul edilen yüzey `θ = ∞` alıyor ve yanlışlıkla
    /// öğretilmiş bir typo silinemezse kalıcı olurdu.
    var onForgetPersonal: ((String) -> Void)?

    /// Kullanıcı bu alandaki metinden öğrenmeyi istiyor (§8.7 korpus içe
    /// aktarımı). Sonuç: eklenen yüzeyler ve güncel liste.
    var onImportPersonal: (() -> (added: [String], all: [String], note: String))?

    var settings: KeyboardSettings
    let showsGlobe: Bool
    var theme: KeyboardTheme

    private let scroll = UIScrollView()
    let stack = UIStackView()
    let titleLabel = UILabel()
    let closeButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let themeStrip = ThemeStrip()
    private let themeTitle = UILabel()
    private let numberRowSwitch = UISwitch()
    private let diagnosticsSwitch = UISwitch()
    private let hapticsSwitch = UISwitch()
    private let clickSwitch = UISwitch()
    private let letterSoundControl = UISegmentedControl(items: KeySoundKind.allCases.map(\.title))
    private let wordSoundControl = UISegmentedControl(items: KeySoundKind.allCases.map(\.title))
    private var soundRows: [SliderRow] = []
    /// Ayarların tek başına anlamı yok; kullanıcının hissettiği şey toplam süre.
    private let wordStageLabel = UILabel()

    private(set) var rows: [SliderRow] = []
    var labels: [UILabel] = []

    init(settings: KeyboardSettings, theme: KeyboardTheme, showsGlobe: Bool,
         personalWords: [String] = []) {
        self.settings = settings
        self.theme = theme
        self.showsGlobe = showsGlobe
        self.personalWords = personalWords
        super.init(frame: .zero)
        build()
        apply(theme: theme)
        syncControls()
    }

    /// Kabul edilmiş kişisel yüzeyler — panel açılırken veriliyor.
    var personalWords: [String]

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Kurulum

    func build() {
        configureTheme()
        configureSwitches()
        makeSliderRows()
        makeSoundControls()
        configureReset()
        buildQuickSection()
        buildAdvancedSection()
        buildPersonalSection()
        layoutScroll()
    }

    /// Başlık: "Ayarlar", klavyeyi kapat, Bitti.
    private func makeHeader() -> UIView {
        titleLabel.text = "Ayarlar"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        labels.append(titleLabel)

        wordStageLabel.font = .systemFont(ofSize: 12)
        labels.append(wordStageLabel)

        closeButton.setTitle("Bitti", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.accessibilityLabel = PanelUI.Label.dismissKeyboard
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismissKeyboard?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), dismissButton, closeButton])
        header.spacing = 16
        header.axis = .horizontal
        header.alignment = .center
        return header

    }

    private func configureTheme() {
        themeStrip.onPick = { [weak self] choice in
            guard let self else { return }
            self.update { $0.theme = choice }
        }
        themeTitle.text = "Tema"
        themeTitle.font = .systemFont(ofSize: 14)
        labels.append(themeTitle)
    }

    /// Hızlı çiplerin ve gelişmiş bölümün anahtarları.
    private func configureSwitches() {
        numberRowSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.commit(self.settings.metrics.with(showsNumberRow: self.numberRowSwitch.isOn))
        }, for: .valueChanged)
        clickSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.update { $0.soundEnabled = self.clickSwitch.isOn }
        }, for: .valueChanged)
        hapticsSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.update { $0.haptics = self.hapticsSwitch.isOn }
        }, for: .valueChanged)
        diagnosticsSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.update { $0.showsDiagnostics = self.diagnosticsSwitch.isOn }
        }, for: .valueChanged)
    }

    private func makeSliderRows() {
        // Genişlik sürgüleri. Kademe `KeyboardMetrics.step`: daha ince bir adım
        // hissedilmeyen bir fark için kalibrasyon profilini değiştirirdi.
        let shiftRow = SliderRow(SettingsSliders.shift) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(shiftWidth: v))
        }
        let backspaceRow = SliderRow(SettingsSliders.backspace) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(backspaceWidth: v))
        }
        let spaceRow = SliderRow(SettingsSliders.space(showsGlobe: showsGlobe)) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(spaceWidth: v))
        }
        // Yükseklik **satırın**: yalnız boşluk tuşunu uzatmak onu üstteki harf
        // satırının üstüne bindirirdi — düzelttiğimiz hatanın aynısı.
        let bottomRow = SliderRow(SettingsSliders.bottomRow(rowHeight: KeyboardView.rowHeightPoints)) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(bottomRowScale: v))
        }

        // `⌫` basılı tutma kademeleri. Zamanlama geometri değil: kalibrasyon
        // profiline ve decoder'a dokunmuyor, o yüzden `commitCadence` ayrı.
        let delayRow = SliderRow(SettingsSliders.repeatDelay) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(initialDelay: v))
        }
        let charRow = SliderRow(SettingsSliders.characterInterval) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(characterInterval: v))
        }
        let wordRow = SliderRow(SettingsSliders.wordInterval) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(wordInterval: v))
        }
        let stageRow = SliderRow(SettingsSliders.wordStage) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence
                .with(charactersBeforeWordStage: Int(v.rounded())))
        }
        rows = [shiftRow, backspaceRow, spaceRow, bottomRow,
                delayRow, charRow, wordRow, stageRow]
    }

    private func makeSoundControls() {
        // Ses kanalları: seçince ve şiddet değişince örnek çalınıyor —
        // sesi adından seçmek, duymadan renk seçmek gibi.
        let channels: [(UISegmentedControl, WritableKeyPath<KeyboardSettings, KeySoundChannel>, String)] = [
            (letterSoundControl, \.letterSound, "harf sesi şiddeti"),
            (wordSoundControl, \.wordSound, "kelime sonu sesi şiddeti"),
        ]
        for (control, channel, _) in channels {
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let control else { return }
                self?.changeSound(channel) { $0.kind = KeySoundKind.allCases[control.selectedSegmentIndex] }
            }, for: .valueChanged)
            control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 11)], for: .normal)
        }
        soundRows = channels.map { _, channel, title in
            SliderRow(SettingsSliders.volume(title)) { [weak self] v in self?.changeSound(channel) { $0.volume = v } }
        }
    }

    private func configureReset() {
        resetButton.setTitle("Varsayılana dön", for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 14)
        resetButton.contentHorizontalAlignment = .leading
        resetButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Depoyu **temizleyip** kanonik varsayılanı geri okuyoruz; mevcut
            // varsayılanları yazmak, varsayılan ileride değişirse kullanıcıyı
            // eski değerlerde bırakırdı.
            self.settings = KeyboardSettingsStore.reset()
            self.syncControls()
            self.onChange?(self.settings)
        }, for: .touchUpInside)
    }

    /// Üst bölüm (tasarım tuvali "8 · Klavyedeki ⚙︎ paneli"): temalar, üç
    /// büyük düğme, öğren / uygulamayı aç.
    private func buildQuickSection() {
        stack.axis = .vertical
        stack.spacing = 10
        // Tasarım tuvali "8 · Klavyedeki ⚙︎ paneli": üstte temalar, üç büyük
        // düğme, öğren / uygulamayı aç; uzun kaydırıcılar "Gelişmiş" altında
        // kapalı (uygulamadaki ekranlar onları animasyonlu anlatıyor).
        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(themeStrip)
        let chips = UIStackView(arrangedSubviews: [
            quickChip(numberRowSwitch, "Sayı satırı", BKPalette.teal.ink.ui),
            quickChip(hapticsSwitch, "Titreşim", BKPalette.purple.ink.ui),
            quickChip(clickSwitch, "Ses", BKPalette.blue.ink.ui),
        ])
        chips.distribution = .fillEqually
        chips.spacing = 8
        stack.addArrangedSubview(chips)
        quickLearn.setTitle(Self.learnTitle, for: .normal)
        quickLearn.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        quickLearn.contentHorizontalAlignment = .leading
        quickLearn.addAction(UIAction { [weak self] _ in self?.learnFromField() }, for: .touchUpInside)
        quickNote.font = .systemFont(ofSize: 12)
        quickNote.numberOfLines = 0
        quickNote.isHidden = true
        labels.append(quickNote)
        openApp.setTitle("Tüm ayarlar uygulamada  ›", for: .normal)
        openApp.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        openApp.contentHorizontalAlignment = .leading
        openApp.addAction(UIAction { [weak self] _ in self?.onOpenApp?() }, for: .touchUpInside)
        stack.addArrangedSubview(quickLearn)
        stack.addArrangedSubview(quickNote)
        stack.addArrangedSubview(openApp)
    }

    /// "Gelişmiş" altında kapalı duran uzun kaydırıcılar, ses, sözlük, tanı.
    private func buildAdvancedSection() {
        advancedToggle.setTitle(Self.advancedTitle(open: false), for: .normal)
        advancedToggle.titleLabel?.font = .systemFont(ofSize: 15)
        advancedToggle.contentHorizontalAlignment = .leading
        advancedToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.advanced.isHidden.toggle()
            self.advancedToggle.setTitle(Self.advancedTitle(open: !self.advanced.isHidden), for: .normal)
        }, for: .touchUpInside)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(advancedToggle)
        advanced.axis = .vertical
        advanced.spacing = 10
        advanced.isHidden = true
        stack.addArrangedSubview(advanced)
        advanced.addArrangedSubview(caption("Harf yazarken"))
        advanced.addArrangedSubview(letterSoundControl)
        advanced.addArrangedSubview(soundRows[0])
        advanced.addArrangedSubview(caption("Kelime bitirirken (boşluk, nokta, ⏎)"))
        advanced.addArrangedSubview(wordSoundControl)
        advanced.addArrangedSubview(soundRows[1])
        for r in rows { advanced.addArrangedSubview(r) }
        advanced.addArrangedSubview(wordStageLabel)
        advanced.addArrangedSubview(separator())
        advanced.addArrangedSubview(personalStack)
        advanced.addArrangedSubview(separator())
        advanced.addArrangedSubview(labelledRow("Tanı satırı", diagnosticsSwitch))
        captureButton.setTitle("Son yazılanı kaydet (geliştirici)", for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 14)
        captureButton.contentHorizontalAlignment = .leading
        captureButton.addAction(UIAction { [weak self] _ in self?.onCapture?() }, for: .touchUpInside)
        advanced.addArrangedSubview(captureButton)
        advanced.addArrangedSubview(resetButton)
    }

    private func layoutScroll() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.disableEdgeEffects()
        scroll.addSubview(stack)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + scroll.contentConstraints(stack, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16),
                                      fillWidth: true))
    }

    // MARK: - Kişisel sözlük durumu (çizimi `+Personal`)

    let personalStack = UIStackView()
    /// Kabul edilmiş yüzeyler ve her birinin yanında **sil**.
    ///
    /// Liste kapasitenin tamamını (512) çizmiyor: panel bir ayar yüzeyi, sözlük
    /// tarayıcısı değil. Gösterilenden fazlası varsa sayı yazılıyor — sessizce
    /// kesmek, kullanıcıya sözlüğünde olmayan bir boyut gösterirdi.
    static let shownPersonalWords = 30
    /// Son içe aktarımın sonucu — varsa açıklama yerine o yazılıyor.
    var personalImportNote: String?
    var personalDeleteButtons: [UIButton] = []

    // MARK: - Ortak parçalar

    private func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        labels.append(l)
        return l
    }

    private func labelledRow(_ title: String, _ control: UIView) -> UIStackView {
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14)
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.append(l)
        // Denetim **adını buradan** alıyor. Etiket ayrı bir öğe olduğu için
        // VoiceOver ikisini ayrı duraklar olarak okuyor ve denetime
        // gelindiğinde elde isimsiz bir değer kalıyordu: "açık, anahtar".
        // Hangi ayarın açık olduğu ancak bir önceki durak hatırlanarak
        // anlaşılıyordu. `SliderRow`'daki sorunun aynısı, aynı çözüm.
        control.accessibilityLabel = title
        let row = UIStackView(arrangedSubviews: [l, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    func separator() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.backgroundColor = theme.separator
        separators.append(v)
        return v
    }

    private var separators: [UIView] = []

    // MARK: - Durum

    private func syncControls() {
        themeStrip.selected = settings.theme
        numberRowSwitch.isOn = settings.metrics.showsNumberRow
        diagnosticsSwitch.isOn = settings.showsDiagnostics
        hapticsSwitch.isOn = settings.haptics
        defer { refreshChips() }
        clickSwitch.isOn = settings.soundEnabled
        letterSoundControl.selectedSegmentIndex =
            KeySoundKind.allCases.firstIndex(of: settings.letterSound.kind) ?? 0
        wordSoundControl.selectedSegmentIndex =
            KeySoundKind.allCases.firstIndex(of: settings.wordSound.kind) ?? 0
        soundRows[0].value = settings.letterSound.volume
        soundRows[1].value = settings.wordSound.volume
        rows[0].value = settings.metrics.shiftWidth
        rows[1].value = settings.metrics.backspaceWidth
        rows[2].value = settings.metrics.effectiveSpaceWidth(showsGlobe: showsGlobe)
        rows[3].value = settings.metrics.bottomRowScale
        rows[4].value = settings.cadence.initialDelay
        rows[5].value = settings.cadence.characterInterval
        rows[6].value = settings.cadence.wordInterval
        rows[7].value = Double(settings.cadence.charactersBeforeWordStage)
        wordStageLabel.text = "kelime kademesi " + SettingsFormat.wordStageAfter(settings.cadence.timeToWordStage)
    }

    /// Kırpma tek yerde: `KeyboardMetrics.init` (`with(...)` oradan geçiyor).
    /// Böylece panelin gösterdiği ile klavyenin çizdiği hep aynı.
    func commit(_ metrics: KeyboardMetrics) { update { $0.metrics = metrics } }

    /// Kırpma `KeyRepeatCadence.init`'te; `wordInterval` orada karakter
    /// aralığının altına inemiyor, o yüzden sürgüler geri okunuyor.
    private func commitCadence(_ cadence: KeyRepeatCadence) { update { $0.cadence = cadence } }

    /// Ses kanalı değişti: kaydedilip örnek çalınıyor.
    private func changeSound(_ channel: WritableKeyPath<KeyboardSettings, KeySoundChannel>,
                             _ change: (inout KeySoundChannel) -> Void) {
        update { change(&$0[keyPath: channel]) }
        KeySoundPlayer.shared.play(settings[keyPath: channel])
    }

    /// Her değişikliğin tek yolu: ayar değişir, denetimler geri okunur, klavyeye bildirilir.
    func update(_ change: (inout KeyboardSettings) -> Void) {
        change(&settings)
        syncControls()
        onChange?(settings)
    }

    static let learnTitle = "Bu alandaki metinden öğren"
    private static func advancedTitle(open: Bool) -> String { "Gelişmiş ayarlar  " + (open ? "▴" : "▾") }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.panelFace
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        for l in labels { l.textColor = theme.panelText }
        for s in separators { s.backgroundColor = theme.separator }
        closeButton.tintColor = theme.controlTint
        dismissButton.tintColor = theme.controlTint
        resetButton.tintColor = theme.controlTint
        captureButton.tintColor = theme.controlTint
        for b in [quickLearn, openApp, advancedToggle] { b.tintColor = theme.controlTint }
        refreshChips()
        for b in personalDeleteButtons { b.tintColor = theme.controlTint }
        numberRowSwitch.onTintColor = theme.controlTint
        themeStrip.ringColor = theme.controlTint
        themeStrip.nameColor = theme.panelText
        diagnosticsSwitch.onTintColor = theme.controlTint
        hapticsSwitch.onTintColor = theme.controlTint
        clickSwitch.onTintColor = theme.controlTint
        for r in rows + soundRows { r.apply(theme: theme) }
    }
}
