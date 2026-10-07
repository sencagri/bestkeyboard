import UIKit

/// Klavyenin üstünde "havada" duran yapay zeka kartı — tasarım tuvali 22.
///
/// Klavye kendi alanının dışına çizemiyor; kart açılınca klavye yukarı
/// uzuyor ve kart o alana gölgeli, yuvarlak köşeli oturuyor. Durumlar:
/// seç → hazırlanıyor → metin ya da resim sonucu (ya da hata).
final class AIPanel: UIView {
    struct EventRow {
        var title: String
        /// "Cmt 10 Eki · 19:00" ya da tüm gün için yalnız gün.
        var when: String
        /// "2 saat", "45 dk"; tüm gün etkinliğinde `nil`.
        var duration: String?
        var location: String?

        init(title: String, when: String, duration: String?, location: String?) {
            self.title = title; self.when = when; self.duration = duration; self.location = location
        }

        /// Etkinlikten (biçim tek yerde: `EventDraft.trWhen` / `trDuration`).
        init(_ d: AIService.EventDraft) {
            self.init(title: d.title, when: d.trWhen, duration: d.trDuration, location: d.location)
        }
    }

    enum State {
        /// `label`: "Panodan", "Seçili metin", "Yazdığın". `canSwitch`: başka
        /// kaynak da var — kutuya dokununca değişiyor.
        case pick(source: String, label: String, canSwitch: Bool)
        case loading(String)
        case text(String)
        case image(UIImage)
        case error(String)
        /// Mesajdan çıkan yapılacaklar (tasarım 26): liste + her madde ayrı satır,
        /// `when` "Yarın 19:00" gibi.
        case reminders(list: String?, rows: [(title: String, when: String?)])
        /// Mesajdan çıkan Takvim etkinlikleri (tasarım 28).
        case events(calendar: String?, rows: [EventRow])
        /// Mesajdan çıkan kişi kartı (tasarım 29).
        case contact(name: String, organization: String?, phones: [String], emails: [String])
        /// Kısa bilgi: başlık + açıklama (hatırlatıcı gönderildi gibi).
        case info(title: String, message: String)

        /// Başlıktaki simge.
        var symbol: String {
            switch self {
            case .reminders: "checklist"
            case .events: "calendar"
            case .contact: "person.crop.circle"
            default: "sparkles"
            }
        }
    }

    var onRun: ((AIAction) -> Void)?
    var onSourceTap: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onAppend: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSticker: (() -> Void)?
    var onAgain: (() -> Void)?
    /// Hatırlatıcı / etkinlik / kişi kartındaki "ekle" ve "Düzenle".
    var onAdd: (() -> Void)?
    var onEdit: (() -> Void)?
    /// Kartın istediği yükseklik değişti (içerik büyüdü / küçüldü).
    var onHeightChange: (() -> Void)?

    let actions: [AIAction]
    var theme: KeyboardTheme
    let card = UIView()
    private let titleIcon = UIImageView(image: UIImage(systemName: "sparkles"))
    let titleLabel = UILabel()
    let closeButton = UIButton(type: .system)
    let body = UIStackView()
    var copyButton: UIButton?
    var stickerButton: UIButton?
    // Renkler **seçili temadan**: kart harf tuşu, çipler işlev tuşu, ana
    // düğme ⏎ renginde — her temada klavyenin parçası gibi duruyor.
    // (Önce sabit mordu; karanlıkta okunmuyor, fotoğraflı temada sırıtıyordu.)
    var accent: UIColor { theme.returnFace }
    var accentText: UIColor { theme.returnText }
    var chipFace: UIColor { theme.functionFace }
    var ink: UIColor { theme.keyText }
    private(set) var lastState: State?

    init(actions: [AIAction], theme: KeyboardTheme) {
        self.actions = actions
        self.theme = theme
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func build() {
        backgroundColor = .clear
        card.backgroundColor = theme.keyFace
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor(rgb: BKPalette.shadow).cgColor
        card.layer.shadowOpacity = 0.2
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        overrideUserInterfaceStyle = theme.userInterfaceStyle

        titleIcon.preferredSymbolConfiguration = .init(pointSize: 13, weight: .bold)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        paintChrome()
        closeButton.accessibilityLabel = "Kartı kapat"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titleIcon, titleLabel, UIView(), closeButton])
        header.spacing = 6
        header.alignment = .center
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        body.axis = .vertical
        body.spacing = 10
        let stack = UIStackView(arrangedSubviews: [header, body])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    private func paintChrome() {
        card.backgroundColor = theme.keyFace
        card.layer.borderColor = theme.keyBorder?.cgColor
        card.layer.borderWidth = theme.keyBorder == nil ? 0 : 1
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        titleIcon.tintColor = accent
        titleLabel.textColor = ink
        var cfg = UIButton.Configuration.filled()
        cfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        cfg.baseBackgroundColor = chipFace
        cfg.baseForegroundColor = theme.functionText
        cfg.cornerStyle = .capsule
        closeButton.configuration = cfg
    }

    /// Tema kart açıkken değişti.
    func apply(theme: KeyboardTheme) {
        self.theme = theme
        paintChrome()
        if let s = lastState { show(s) }
    }

    /// Kartın genişliğe göre istediği yükseklik.
    func fittingHeight(width: CGFloat) -> CGFloat {
        systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                withHorizontalFittingPriority: .required,
                                verticalFittingPriority: .fittingSizeLevel).height
    }

    func show(_ state: State) {
        lastState = state
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        copyButton = nil; stickerButton = nil
        titleIcon.image = UIImage(systemName: state.symbol)
        switch state {
        case let .pick(source, label, canSwitch): showPick(source: source, label: label, canSwitch: canSwitch)
        case let .loading(text): showLoading(text)
        case let .text(result): showText(result)
        case let .image(img): showImage(img)
        case let .reminders(list, rows): showReminders(list: list, rows: rows)
        case let .events(calendar, rows): showEvents(calendar: calendar, rows: rows)
        case let .contact(name, organization, phones, emails):
            showContact(name: name, organization: organization, phones: phones, emails: emails)
        case let .info(title, message): showInfo(title: title, message: message)
        case let .error(msg): showError(msg)
        }
        setNeedsLayout()
        onHeightChange?()
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    /// Düğme etiketini kısa süreliğine değiştirir ("Kopyalandı").
    func flashCopied() { flash(copyButton, "Kopyalandı") }
    func flashSticker() { flash(stickerButton, "Stüdyoya eklendi") }

    /// Düğmenin asıl başlığı, geçici yazı sürerken — art arda basışta
    /// geçici yazı "asıl" sanılıp düğme onda takılı kalıyordu.
    private var flashOriginals: [ObjectIdentifier: String] = [:]
    private(set) var flashGeneration = 0

    func flash(_ b: UIButton?, _ text: String) {
        guard let b, var cfg = b.configuration else { return }
        let key = ObjectIdentifier(b)
        if flashOriginals[key] == nil { flashOriginals[key] = cfg.title ?? "" }
        cfg.title = text
        b.configuration = cfg
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelUI.messageDuration) { [weak self, weak b] in
            guard let self, let b, generation == self.flashGeneration,
                  let original = self.flashOriginals.removeValue(forKey: key), var c = b.configuration else { return }
            c.title = original
            b.configuration = c
        }
    }

}

