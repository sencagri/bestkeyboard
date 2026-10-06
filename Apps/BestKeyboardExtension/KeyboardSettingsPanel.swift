import UIKit
import KBGeometry
import KBRuntime

/// Klavyenin üstünü kaplayan ayar paneli.
///
/// ## Neden klavyenin içinde
///
/// Ayarlar uzantının kendi sandbox'ında duruyor (`KeyboardSettingsStore`);
/// ana uygulamadan yazılan bir ayar App Group olmadan uzantıya ulaşmıyor. Bu
/// yüzden panel klavyenin **kendi** yüzeyi: gördüğün klavyeyi gördüğün yerden
/// ayarlıyorsun.
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
    private let dismissButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    /// Uygulamayı aç.
    var onOpenApp: (() -> Void)?
    private let quickLearn = UIButton(type: .system)
    private let quickNote = UILabel()
    private let openApp = UIButton(type: .system)
    private let advancedToggle = UIButton(type: .system)
    private let advanced = UIStackView()
    private var chipButtons: [(UISwitch, UIButton, UIColor)] = []

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

    private func refreshChips() {
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

    private(set) var settings: KeyboardSettings
    private let showsGlobe: Bool
    private var theme: KeyboardTheme

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
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

    private var rows: [SliderRow] = []
    private var labels: [UILabel] = []

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
    private var personalWords: [String]

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Kurulum

    private func build() {
        titleLabel.text = "Ayarlar"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        labels.append(titleLabel)

        wordStageLabel.font = .systemFont(ofSize: 12)
        labels.append(wordStageLabel)

        closeButton.setTitle("Bitti", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.accessibilityLabel = "Klavyeyi kapat"
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismissKeyboard?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), dismissButton, closeButton])
        header.spacing = 16
        header.axis = .horizontal
        header.alignment = .center

        themeStrip.onPick = { [weak self] choice in
            guard let self else { return }
            self.settings.theme = choice
            self.commit(self.settings.metrics)
        }
        themeTitle.text = "Tema"
        themeTitle.font = .systemFont(ofSize: 14)
        labels.append(themeTitle)

        numberRowSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.commit(self.settings.metrics.with(showsNumberRow: self.numberRowSwitch.isOn))
        }, for: .valueChanged)
        clickSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.settings.soundEnabled = self.clickSwitch.isOn
            self.commit(self.settings.metrics)
        }, for: .valueChanged)
        hapticsSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.settings.haptics = self.hapticsSwitch.isOn
            self.commit(self.settings.metrics)
        }, for: .valueChanged)
        diagnosticsSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.settings.showsDiagnostics = self.diagnosticsSwitch.isOn
            self.commit(self.settings.metrics)
        }, for: .valueChanged)

        // Genişlik sürgüleri. Kademe `KeyboardMetrics.step`: daha ince bir adım
        // hissedilmeyen bir fark için kalibrasyon profilini değiştirirdi.
        let shiftRow = SliderRow(title: "⇧ genişlik",
                                 range: KeyboardMetrics.shiftRange,
                                 step: KeyboardMetrics.step) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(shiftWidth: v))
        }
        let backspaceRow = SliderRow(title: "⌫ genişlik",
                                     range: KeyboardMetrics.backspaceRange,
                                     step: KeyboardMetrics.step) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(backspaceWidth: v))
        }
        let spaceRow = SliderRow(title: "boşluk genişlik",
                                 range: KeyboardMetrics.spaceBounds(showsGlobe: showsGlobe),
                                 step: KeyboardMetrics.step) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(spaceWidth: v))
        }
        // Yükseklik **satırın**: yalnız boşluk tuşunu uzatmak onu üstteki harf
        // satırının üstüne bindirirdi — düzelttiğimiz hatanın aynısı.
        let bottomRow = SliderRow(title: "boşluk satırı yükseklik",
                                  range: KeyboardMetrics.bottomRowRange,
                                  step: KeyboardMetrics.bottomRowStep) { [weak self] v in
            guard let self else { return }
            self.commit(self.settings.metrics.with(bottomRowScale: v))
        }

        // `⌫` basılı tutma kademeleri. Zamanlama geometri değil: kalibrasyon
        // profiline ve decoder'a dokunmuyor, o yüzden `commitCadence` ayrı.
        func secs(_ v: Double) -> String { String(format: "%.0f ms", v * 1000) }
        let c = KeyRepeatCadence.self
        let delayRow = SliderRow(title: "⌫ tekrar gecikmesi",
                                 range: c.initialDelayRange,
                                 step: c.initialDelayStep,
                                 format: secs) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(initialDelay: v))
        }
        let charRow = SliderRow(title: "⌫ karakter aralığı",
                                range: c.characterIntervalRange,
                                step: c.characterIntervalStep,
                                format: secs) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(characterInterval: v))
        }
        let wordRow = SliderRow(title: "⌫ kelime aralığı",
                                range: c.wordIntervalRange,
                                step: c.wordIntervalStep,
                                format: secs) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence.with(wordInterval: v))
        }
        let stageRange = Double(c.charactersBeforeWordStageRange.lowerBound)
                       ... Double(c.charactersBeforeWordStageRange.upperBound)
        let stageRow = SliderRow(title: "⌫ kelimeye geçiş",
                                 range: stageRange,
                                 step: Double(c.charactersBeforeWordStageStep),
                                 format: { String(format: "%.0f karakter", $0) }) { [weak self] v in
            guard let self else { return }
            self.commitCadence(self.settings.cadence
                .with(charactersBeforeWordStage: Int(v.rounded())))
        }
        rows = [shiftRow, backspaceRow, spaceRow, bottomRow,
                delayRow, charRow, wordRow, stageRow]

        // Ses kanalları: seçince ve şiddet değişince örnek çalınıyor —
        // sesi adından seçmek, duymadan renk seçmek gibi.
        let pct: (Double) -> String = { String(format: "%%%.0f", $0 * 100) }
        for (control, isWord) in [(letterSoundControl, false), (wordSoundControl, true)] {
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                let kind = KeySoundKind.allCases[control.selectedSegmentIndex]
                if isWord { self.settings.wordSound.kind = kind }
                else { self.settings.letterSound.kind = kind }
                KeySoundPlayer.shared.play(isWord ? self.settings.wordSound : self.settings.letterSound)
                self.commit(self.settings.metrics)
            }, for: .valueChanged)
            control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 11)], for: .normal)
        }
        soundRows = [
            SliderRow(title: "harf sesi şiddeti", range: 0...1, step: 0.05, format: pct) { [weak self] v in
                guard let self else { return }
                self.settings.letterSound.volume = v
                KeySoundPlayer.shared.play(self.settings.letterSound)
                self.commit(self.settings.metrics)
            },
            SliderRow(title: "kelime sonu sesi şiddeti", range: 0...1, step: 0.05, format: pct) { [weak self] v in
                guard let self else { return }
                self.settings.wordSound.volume = v
                KeySoundPlayer.shared.play(self.settings.wordSound)
                self.commit(self.settings.metrics)
            },
        ]

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

        stack.axis = .vertical
        stack.spacing = 10
        // Tasarım tuvali "8 · Klavyedeki ⚙︎ paneli": üstte temalar, üç büyük
        // düğme, öğren / uygulamayı aç; uzun kaydırıcılar "Gelişmiş" altında
        // kapalı (uygulamadaki ekranlar onları animasyonlu anlatıyor).
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(themeStrip)
        let chips = UIStackView(arrangedSubviews: [
            quickChip(numberRowSwitch, "Sayı satırı", UIColor(hex: "#0E7A68")),
            quickChip(hapticsSwitch, "Titreşim", UIColor(hex: "#5B3FD0")),
            quickChip(clickSwitch, "Ses", UIColor(hex: "#1F5FBF")),
        ])
        chips.distribution = .fillEqually
        chips.spacing = 8
        stack.addArrangedSubview(chips)
        quickLearn.setTitle("Bu alandaki metinden öğren", for: .normal)
        quickLearn.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        quickLearn.contentHorizontalAlignment = .leading
        quickLearn.addAction(UIAction { [weak self] _ in
            guard let self, let result = self.onImportPersonal?() else { return }
            self.personalWords = result.all
            self.personalImportNote = result.note
            self.quickNote.text = result.note
            self.quickNote.isHidden = false
            self.buildPersonalSection()
        }, for: .touchUpInside)
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

        advancedToggle.setTitle("Gelişmiş ayarlar  ▾", for: .normal)
        advancedToggle.titleLabel?.font = .systemFont(ofSize: 15)
        advancedToggle.contentHorizontalAlignment = .leading
        advancedToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.advanced.isHidden.toggle()
            self.advancedToggle.setTitle(self.advanced.isHidden ? "Gelişmiş ayarlar  ▾" : "Gelişmiş ayarlar  ▴",
                                         for: .normal)
        }, for: .touchUpInside)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(advancedToggle)
        advanced.axis = .vertical
        advanced.spacing = 10
        advanced.isHidden = true
        stack.addArrangedSubview(advanced)
        let stack = advanced   // aşağıdakiler gelişmiş bölüme
        stack.addArrangedSubview(caption("Harf yazarken"))
        stack.addArrangedSubview(letterSoundControl)
        stack.addArrangedSubview(soundRows[0])
        stack.addArrangedSubview(caption("Kelime bitirirken (boşluk, nokta, ⏎)"))
        stack.addArrangedSubview(wordSoundControl)
        stack.addArrangedSubview(soundRows[1])
        for r in rows { stack.addArrangedSubview(r) }
        stack.addArrangedSubview(wordStageLabel)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(personalStack)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(labelledRow("Tanı satırı", diagnosticsSwitch))
        captureButton.setTitle("Son yazılanı kaydet (geliştirici)", for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 14)
        captureButton.contentHorizontalAlignment = .leading
        captureButton.addAction(UIAction { [weak self] _ in self?.onCapture?() }, for: .touchUpInside)
        stack.addArrangedSubview(captureButton)
        stack.addArrangedSubview(resetButton)
        buildPersonalSection()
        layoutScroll()
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

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    // MARK: - Kişisel sözlük (§8.7)

    private let personalStack = UIStackView()

    /// Kabul edilmiş yüzeyler ve her birinin yanında **sil**.
    ///
    /// Liste kapasitenin tamamını (512) çizmiyor: panel bir ayar yüzeyi, sözlük
    /// tarayıcısı değil. Gösterilenden fazlası varsa sayı yazılıyor — sessizce
    /// kesmek, kullanıcıya sözlüğünde olmayan bir boyut gösterirdi.
    private static let shownPersonalWords = 30

    /// Son içe aktarımın sonucu — varsa açıklama yerine o yazılıyor.
    private var personalImportNote: String?

    private func buildPersonalSection() {
        personalStack.axis = .vertical
        personalStack.spacing = 8
        for v in personalStack.arrangedSubviews {
            personalStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        personalDeleteButtons.removeAll()

        let title = UILabel()
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.text = personalWords.isEmpty
            ? "Kişisel sözlük — boş"
            : "Kişisel sözlük (\(personalWords.count))"
        labels.append(title)
        personalStack.addArrangedSubview(title)

        let hint = UILabel()
        hint.font = .systemFont(ofSize: 12)
        hint.numberOfLines = 0
        hint.text = personalImportNote
            ?? "Sözlükte olmayan bir kelimeyi üç kez yazınca klavye onu öğrenir "
             + "ve bir daha düzeltmez."
        labels.append(hint)
        personalStack.addArrangedSubview(hint)

        // Korpus içe aktarımı: **bu alandaki** metinden öğren.
        //
        // Pano değil: panoyu okumak Tam Erişim istiyor ve iOS her okumada
        // sistem onayı gösteriyor. Alandaki metin zaten kullanıcının önünde ve
        // klavye onu izin almadan görüyor.
        if onImportPersonal != nil {
            let importButton = UIButton(type: .system)
            importButton.setTitle("Bu alandaki metinden öğren", for: .normal)
            importButton.titleLabel?.font = .systemFont(ofSize: 14)
            importButton.contentHorizontalAlignment = .leading
            importButton.tintColor = theme.accent
            importButton.addAction(UIAction { [weak self] _ in
                guard let self, let result = self.onImportPersonal?() else { return }
                self.personalWords = result.all
                self.personalImportNote = result.note
                self.buildPersonalSection()
            }, for: .touchUpInside)
            personalDeleteButtons.append(importButton)   // tema aynı yoldan
            personalStack.addArrangedSubview(importButton)
        }

        if personalWords.isEmpty { return }

        for word in personalWords.prefix(Self.shownPersonalWords) {
            let l = UILabel()
            l.text = word
            l.font = .systemFont(ofSize: 14)
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labels.append(l)

            let del = UIButton(type: .system)
            del.setTitle("sil", for: .normal)
            // Etiket **kelimeyi taşıyor**. Görülen "sil" yazısı yeterli değil:
            // kelime ayrı bir öğede duruyor ve VoiceOver kullanıcısı listede
            // arka arkaya beş tane "sil, düğme" duyuyordu. Hangisinin hangi
            // kelimeye ait olduğu yalnız ekrana bakınca belliydi — ve bu
            // **yıkıcı** bir eylem, yanlış olanı seçmek kelimeyi siliyor.
            del.accessibilityLabel = "\(word) sözcüğünü sil"
            del.titleLabel?.font = .systemFont(ofSize: 14)
            del.tintColor = theme.accent
            del.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            del.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onForgetPersonal?(word)
                self.personalWords.removeAll { $0 == word }
                self.buildPersonalSection()
            }, for: .touchUpInside)
            personalDeleteButtons.append(del)

            let row = UIStackView(arrangedSubviews: [l, del])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            personalStack.addArrangedSubview(row)
        }

        if personalWords.count > Self.shownPersonalWords {
            let more = UILabel()
            more.font = .systemFont(ofSize: 12)
            more.text = "+\(personalWords.count - Self.shownPersonalWords) kelime daha"
            labels.append(more)
            personalStack.addArrangedSubview(more)
        }
    }

    private var personalDeleteButtons: [UIButton] = []

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

    private func separator() -> UIView {
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
        wordStageLabel.text = String(format: "kelime kademesi ~%.1f sn sonra",
                                     settings.cadence.timeToWordStage)
    }

    /// Kırpma tek yerde: `KeyboardMetrics.init` (`with(...)` oradan geçiyor).
    /// Böylece panelin gösterdiği ile klavyenin çizdiği hep aynı.
    private func commit(_ metrics: KeyboardMetrics) {
        settings.metrics = metrics
        syncControls()
        onChange?(settings)
    }

    /// Kırpma `KeyRepeatCadence.init`'te; `wordInterval` orada karakter
    /// aralığının altına inemiyor, o yüzden sürgüler geri okunuyor.
    private func commitCadence(_ cadence: KeyRepeatCadence) {
        settings.cadence = cadence
        syncControls()
        onChange?(settings)
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.panelFace
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        for l in labels { l.textColor = theme.panelText }
        for s in separators { s.backgroundColor = theme.separator }
        closeButton.tintColor = theme.accent
        dismissButton.tintColor = theme.accent
        resetButton.tintColor = theme.accent
        captureButton.tintColor = theme.accent
        for b in [quickLearn, openApp, advancedToggle] { b.tintColor = theme.accent }
        refreshChips()
        for b in personalDeleteButtons { b.tintColor = theme.accent }
        numberRowSwitch.onTintColor = theme.accent
        themeStrip.ringColor = theme.accent
        themeStrip.nameColor = theme.panelText
        diagnosticsSwitch.onTintColor = theme.accent
        hapticsSwitch.onTintColor = theme.accent
        clickSwitch.onTintColor = theme.accent
        for r in rows + soundRows { r.apply(theme: theme) }
    }
}

/// Etiket + değer + sürgü. Değer her zaman yazılı: "geniş/dar" gibi göreli bir
/// ifade, kullanıcının aynı ayarı ikinci cihazda tekrarlamasını imkânsız kılar.
private final class SliderRow: UIStackView {
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let step: Double
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    var value: Double {
        get { Double(slider.value) }
        set {
            slider.value = Float(newValue)
            valueLabel.text = format(newValue)
            // Değer sürgünün **kendi** erişilebilirlik değeri oluyor.
            //
            // `UISlider` varsayılan olarak yüzde okuyor ("%40") — oysa burada
            // anlamlı olan biçimlendirilmiş değer ("1.25 birim"). Yüzde,
            // kullanıcının aynı ayarı ikinci bir cihazda tekrarlamasını
            // imkânsız kılıyor; `valueLabel`'ın var olma sebebiyle aynı gerekçe.
            slider.accessibilityValue = format(newValue)
        }
    }

    /// - Parameter step: kademe **parametre başına**. Genişlik ile yükseklik
    ///   aynı ızgarada olamaz: 1 birim genişlik ≈ 36 pt, 1 birim yükseklik
    ///   ≈ 54 pt, aynı adım birinde ince diğerinde kaba kalıyor.
    init(title text: String, range: ClosedRange<Double>, step: Double,
         format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
         onChange: @escaping (Double) -> Void) {
        self.step = step
        self.format = format
        self.onChange = onChange
        super.init(frame: .zero)

        title.text = text
        title.font = .systemFont(ofSize: 14)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        // Sürgünün adı başlıktan geliyor. Başlık ayrı bir `UILabel` ve VoiceOver
        // onu ayrı bir durak olarak okuyor; sürgüye gelindiğinde elde yalnız
        // isimsiz bir değer kalıyordu ("%40, ayarlanabilir") — hangi ayar
        // olduğu ancak bir önceki durağı hatırlayarak anlaşılıyordu.
        slider.accessibilityLabel = text
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Sürekli değeri kademeye oturt: sürgü serbest bıraksa 1.3271 gibi
            // değerler üretir ve her biri ayrı bir kalibrasyon profili olurdu.
            let snapped = (Double(self.slider.value) / self.step).rounded() * self.step
            self.value = snapped
            self.onChange(snapped)
        }, for: .valueChanged)

        let head = UIStackView(arrangedSubviews: [title, valueLabel])
        head.axis = .horizontal
        axis = .vertical
        spacing = 2
        addArrangedSubview(head)
        addArrangedSubview(slider)
    }

    required init(coder: NSCoder) { fatalError() }

    func apply(theme: KeyboardTheme) {
        title.textColor = theme.panelText
        valueLabel.textColor = theme.barSecondaryText
        slider.tintColor = theme.accent
        slider.minimumTrackTintColor = theme.accent
    }
}

/// Tema seçici: her tema kendi zemini ve tuş renkleriyle küçük bir kare.
///
/// Bölümlü denetim (`Sistem/Açık/Koyu`) üç seçenekte işe yarıyordu; on iki
/// seçenekte adlar okunmaz hâle geliyor ve "Okyanus" yazısı temanın neye
/// benzediğini söylemiyor. Kare temanın **kendisini** gösteriyor.
final class ThemeStrip: UIScrollView {
    var onPick: ((ThemeChoice) -> Void)?
    var selected: ThemeChoice = .system { didSet { refreshRings() } }
    var ringColor: UIColor = .systemBlue { didSet { refreshRings() } }

    private let row = UIStackView()
    private var tiles: [(ThemeChoice, UIButton)] = []
    private var nameLabels: [UILabel] = []
    var nameColor: UIColor = .label { didSet { for l in nameLabels { l.textColor = nameColor } } }
    private static let side: CGFloat = 48

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        disableEdgeEffects()
        clipsToBounds = false
        row.axis = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: Self.side + 26),
        ])
        for choice in ThemeChoice.allCases {
            let name = UILabel()
            name.text = choice.title
            name.font = .systemFont(ofSize: 11)
            name.textAlignment = .center
            name.isAccessibilityElement = false
            nameLabels.append(name)
            let col = UIStackView(arrangedSubviews: [tile(for: choice), name])
            col.axis = .vertical
            col.alignment = .center
            col.spacing = 4
            col.widthAnchor.constraint(equalToConstant: 64).isActive = true
            row.addArrangedSubview(col)
        }
        refreshRings()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tile(for choice: ThemeChoice) -> UIButton {
        let b = UIButton(type: .custom)
        b.accessibilityLabel = "Tema: \(choice.title)"
        b.layer.cornerRadius = 12
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: Self.side),
            b.heightAnchor.constraint(equalToConstant: Self.side),
        ])
        func preview(_ t: KeyboardTheme, in frame: CGRect) {
            let back = ThemeBackdropView(frame: frame)
            back.apply(t)
            b.addSubview(back)
            for (i, face) in [t.keyFace, t.keyFace, t.returnFace].enumerated() {
                let k = UIView(frame: CGRect(x: 7 + CGFloat(i) * 12, y: Self.side - 24,
                                             width: 10, height: 16))
                k.backgroundColor = face
                k.layer.cornerRadius = 3
                k.isUserInteractionEnabled = false
                b.addSubview(k)
            }
        }
        let full = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        if choice == .system {
            // Sistem: yarısı açık, yarısı koyu — "kipi izler" demenin kısa yolu.
            preview(.dark, in: full)
            let half = UIView(frame: CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side))
            half.clipsToBounds = true
            half.isUserInteractionEnabled = false
            let light = ThemeBackdropView(frame: full)
            light.apply(.light)
            half.addSubview(light)
            b.insertSubview(half, at: 1)
        } else {
            preview(choice.resolved(for: traitCollection), in: full)
        }
        for v in b.subviews { v.isUserInteractionEnabled = false }
        b.addAction(UIAction { [weak self] _ in
            self?.selected = choice
            self?.onPick?(choice)
        }, for: .touchUpInside)
        tiles.append((choice, b))
        return b
    }

    private func refreshRings() {
        for (choice, b) in tiles {
            let on = choice == selected
            b.layer.borderWidth = on ? 3 : 1
            b.layer.borderColor = (on ? ringColor : UIColor(white: 0.5, alpha: 0.35)).cgColor
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}
