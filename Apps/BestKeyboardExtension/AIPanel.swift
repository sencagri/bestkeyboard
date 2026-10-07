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

    private let actions: [AIAction]
    private var theme: KeyboardTheme
    private let card = UIView()
    private let titleIcon = UIImageView(image: UIImage(systemName: "sparkles"))
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let body = UIStackView()
    private var copyButton: UIButton?
    private var stickerButton: UIButton?
    // Renkler **seçili temadan**: kart harf tuşu, çipler işlev tuşu, ana
    // düğme ⏎ renginde — her temada klavyenin parçası gibi duruyor.
    // (Önce sabit mordu; karanlıkta okunmuyor, fotoğraflı temada sırıtıyordu.)
    private var accent: UIColor { theme.returnFace }
    private var accentText: UIColor { theme.returnText }
    private var chipFace: UIColor { theme.functionFace }
    private var ink: UIColor { theme.keyText }
    private var lastState: State?

    init(actions: [AIAction], theme: KeyboardTheme) {
        self.actions = actions
        self.theme = theme
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear
        card.backgroundColor = theme.keyFace
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor(red: 20 / 255, green: 18 / 255, blue: 40 / 255, alpha: 1).cgColor
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
        let symbol: String
        switch state {
        case .reminders: symbol = "checklist"
        case .events: symbol = "calendar"
        case .contact: symbol = "person.crop.circle"
        default: symbol = "sparkles"
        }
        titleIcon.image = UIImage(systemName: symbol)
        switch state {
        case let .pick(source, label, canSwitch):
            titleLabel.text = "Ne yapayım?"
            body.addArrangedSubview(sourceBox(source, label: label, canSwitch: canSwitch))
            let grid = UIStackView()
            grid.axis = .vertical
            grid.spacing = 8
            for row in stride(from: 0, to: actions.count, by: 3) {
                let h = UIStackView()
                h.spacing = 8
                h.distribution = .fillEqually
                for a in actions[row..<min(row + 3, actions.count)] { h.addArrangedSubview(actionButton(a)) }
                for _ in 0..<(3 - h.arrangedSubviews.count) { h.addArrangedSubview(UIView()) }
                grid.addArrangedSubview(h)
            }
            body.addArrangedSubview(grid)

        case let .loading(text):
            titleLabel.text = "Hazırlanıyor"
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = accent
            spinner.startAnimating()
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 14)
            l.textColor = ink.withAlphaComponent(0.7)
            let v = UIStackView(arrangedSubviews: [spinner, l])
            v.axis = .vertical
            v.alignment = .center
            v.spacing = 10
            v.heightAnchor.constraint(equalToConstant: 92).isActive = true
            v.distribution = .equalCentering
            body.addArrangedSubview(v)

        case let .text(result):
            titleLabel.text = "Sonuç"
            let l = UILabel()
            l.text = result
            l.font = .systemFont(ofSize: 17)
            l.textColor = ink
            l.numberOfLines = 6
            body.addArrangedSubview(l)
            let replace = button("Değiştir", fill: accent, ink: accentText) { [weak self] in self?.onReplace?() }
            let append = button("Ekle", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onAppend?() }
            let copy = button("Kopyala", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onCopy?() }
            copyButton = copy
            let row = UIStackView(arrangedSubviews: [replace, append, copy])
            row.spacing = 8
            row.distribution = .fillProportionally
            replace.widthAnchor.constraint(equalTo: append.widthAnchor, multiplier: 1.3).isActive = true
            append.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
            body.addArrangedSubview(row)

        case let .image(img):
            titleLabel.text = "Resim hazır"
            let iv = UIImageView(image: img)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 14
            iv.widthAnchor.constraint(equalToConstant: 132).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 132).isActive = true
            iv.isAccessibilityElement = true
            iv.accessibilityLabel = "Üretilen resim"
            let sticker = button("Çıkartma yap", fill: accent, ink: accentText) { [weak self] in self?.onSticker?() }
            stickerButton = sticker
            let copy = button("Kopyala", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onCopy?() }
            copyButton = copy
            let again = button("Yeniden", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onAgain?() }
            let col = UIStackView(arrangedSubviews: [sticker, copy, again])
            col.axis = .vertical
            col.spacing = 8
            col.distribution = .fillEqually
            let row = UIStackView(arrangedSubviews: [iv, col])
            row.spacing = 12
            body.addArrangedSubview(row)

        case let .reminders(list, rows):
            titleLabel.text = rows.count > 1 ? "\(rows.count) yapılacak" : "Hatırlatıcı"
            // Hedef çipleri (tasarım 30): yüklü olmayan soluk; seçim hatırlanıyor.
            let dest = TodoDestination.current
            let chips = UIStackView()
            chips.spacing = 6
            for d in TodoDestination.allCases {
                let on = d == dest
                var cfg = UIButton.Configuration.filled()
                cfg.title = d.title
                cfg.baseBackgroundColor = on ? accent : chipFace
                cfg.baseForegroundColor = on ? accentText : theme.functionText
                cfg.cornerStyle = .capsule
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
                cfg.titleTextAttributesTransformer = .init { a in var a = a; a.font = .systemFont(ofSize: 13, weight: .bold); return a }
                cfg.titleLineBreakMode = .byClipping
                let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in
                    TodoDestination.current = d
                    if let s = self?.lastState { self?.show(s) }
                })
                b.alpha = d.isAvailable ? 1 : 0.45
                b.accessibilityTraits.insert(on ? .selected : [])
                b.setContentCompressionResistancePriority(.required, for: .horizontal)
                chips.addArrangedSubview(b)
            }
            let chipScroll = UIScrollView()
            chipScroll.showsHorizontalScrollIndicator = false
            chips.translatesAutoresizingMaskIntoConstraints = false
            chipScroll.addSubview(chips)
            NSLayoutConstraint.activate([
                chips.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
                chips.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
                chips.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
                chips.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
                chips.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
                chipScroll.heightAnchor.constraint(equalToConstant: 32),
            ])
            body.addArrangedSubview(chipScroll)
            if let note = dest.unavailableNote {
                let l = UILabel()
                l.text = note
                l.font = .systemFont(ofSize: 12)
                l.textColor = ink.withAlphaComponent(0.75)
                l.numberOfLines = 2
                body.addArrangedSubview(l)
            }
            let box = UIStackView()
            box.axis = .vertical
            box.spacing = 8
            if let list {
                let l = UILabel()
                l.text = dest != .apple ? "\(dest.title) · \(list)"
                    : AIService.reminderLists.contains(list) ? "Liste: \(list)" : "Yeni liste: \(list)"
                l.font = .systemFont(ofSize: 12, weight: .bold)
                l.textColor = accent
                box.addArrangedSubview(l)
            }
            // Her madde ayrı satır — Hatırlatıcılar'da da ayrı işaretlenecek.
            let shown = rows.prefix(6)
            for r in shown {
                let ring = UIView()
                ring.layer.borderColor = accent.cgColor
                ring.layer.borderWidth = 2
                ring.layer.cornerRadius = 9
                ring.widthAnchor.constraint(equalToConstant: 18).isActive = true
                ring.heightAnchor.constraint(equalToConstant: 18).isActive = true
                let t = UILabel()
                t.text = r.title
                t.font = .systemFont(ofSize: 16, weight: .semibold)
                t.textColor = ink
                t.numberOfLines = 1
                let line = UIStackView(arrangedSubviews: [ring, t])
                line.spacing = 10
                line.alignment = .center
                if let when = r.when { line.addArrangedSubview(chip(when, symbol: "clock")) }
                t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                box.addArrangedSubview(line)
            }
            if rows.count > shown.count {
                let more = UILabel()
                more.text = "+\(rows.count - shown.count) madde daha"
                more.font = .systemFont(ofSize: 13)
                more.textColor = ink.withAlphaComponent(0.7)
                box.addArrangedSubview(more)
            }
            let framed = padded(box, background: .clear)
            framed.layer.borderColor = chipFace.cgColor
            framed.layer.borderWidth = 1
            framed.layer.cornerRadius = 14
            body.addArrangedSubview(framed)
            body.addArrangedSubview(addEditRow(dest == .apple && rows.count > 1 ? "Hepsini ekle" : dest.addTitle))

        case let .events(calendar, rows):
            titleLabel.text = rows.count > 1 ? "\(rows.count) etkinlik" : "Takvim"
            for (i, r) in rows.prefix(3).enumerated() {
                let v = UIStackView()
                v.axis = .vertical
                v.spacing = 7
                v.alignment = .leading
                if i == 0, let calendar {
                    v.addArrangedSubview(smallLabel("Takvim: \(calendar)"))
                }
                let t = UILabel()
                t.text = r.title
                t.font = .systemFont(ofSize: 17, weight: .semibold)
                t.textColor = ink
                t.numberOfLines = 2
                v.addArrangedSubview(t)
                let chips = UIStackView(arrangedSubviews: [chip(r.when, symbol: "calendar")])
                chips.spacing = 6
                if let d = r.duration { chips.addArrangedSubview(chip(d, symbol: "clock")) }
                v.addArrangedSubview(chips)
                if let loc = r.location { v.addArrangedSubview(iconLine("mappin.and.ellipse", loc)) }
                // Soldaki renkli şerit: Takvim'deki etkinlik görünümü.
                let stripe = UIView()
                stripe.backgroundColor = accent
                stripe.layer.cornerRadius = 2
                stripe.widthAnchor.constraint(equalToConstant: 4).isActive = true
                let row = UIStackView(arrangedSubviews: [stripe, v])
                row.spacing = 10
                body.addArrangedSubview(framed(row))
            }
            if rows.count > 3 { body.addArrangedSubview(smallLabel("+\(rows.count - 3) etkinlik daha")) }
            body.addArrangedSubview(addEditRow(rows.count > 1 ? "Hepsini ekle" : "Takvime ekle"))

        case let .contact(name, organization, phones, emails):
            titleLabel.text = "Kişi"
            let initials = AIService.ContactDraft.initials(of: name)
            let avatar = UILabel()
            avatar.text = initials.isEmpty ? "?" : initials
            avatar.font = .systemFont(ofSize: 16, weight: .bold)
            avatar.textColor = .white
            avatar.textAlignment = .center
            avatar.backgroundColor = UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
            avatar.layer.cornerRadius = 20
            avatar.clipsToBounds = true
            avatar.widthAnchor.constraint(equalToConstant: 40).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let n = UILabel()
            n.text = name.isEmpty ? "Adsız kişi" : name
            n.font = .systemFont(ofSize: 17, weight: .semibold)
            n.textColor = ink
            let names = UIStackView(arrangedSubviews: [n])
            names.axis = .vertical
            names.spacing = 1
            if let organization {
                let o = UILabel()
                o.text = organization
                o.font = .systemFont(ofSize: 13)
                o.textColor = ink.withAlphaComponent(0.7)
                names.addArrangedSubview(o)
            }
            let head = UIStackView(arrangedSubviews: [avatar, names])
            head.spacing = 10
            head.alignment = .center
            let v = UIStackView(arrangedSubviews: [head])
            v.axis = .vertical
            v.spacing = 8
            for p in phones.prefix(3) { v.addArrangedSubview(iconLine("phone", p, tag: "cep")) }
            for e in emails.prefix(2) { v.addArrangedSubview(iconLine("envelope", e, tag: "e-posta")) }
            body.addArrangedSubview(framed(v))
            body.addArrangedSubview(addEditRow("Kişilere ekle"))

        case let .info(title, message):
            titleLabel.text = title
            let l = UILabel()
            l.text = message
            l.font = .systemFont(ofSize: 15)
            l.textColor = ink
            l.numberOfLines = 4
            body.addArrangedSubview(l)

        case let .error(msg):
            titleLabel.text = "Olmadı"
            let l = UILabel()
            l.text = msg
            l.font = .systemFont(ofSize: 15)
            l.textColor = ink
            l.numberOfLines = 4
            body.addArrangedSubview(l)
            body.addArrangedSubview(button("Geri", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onAgain?() })
        }
        setNeedsLayout()
        onHeightChange?()
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    /// Düğme etiketini kısa süreliğine değiştirir ("Kopyalandı").
    func flashCopied() { flash(copyButton, "Kopyalandı") }
    func flashSticker() { flash(stickerButton, "Stüdyoya eklendi") }

    private func flash(_ b: UIButton?, _ text: String) {
        guard let b, var cfg = b.configuration else { return }
        let old = cfg.title
        cfg.title = text
        b.configuration = cfg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak b] in
            guard let b, var c = b.configuration else { return }
            c.title = old
            b.configuration = c
        }
    }

    private func actionButton(_ a: AIAction) -> UIButton {
        let image = a.kind == .image
        var cfg = UIButton.Configuration.filled()
        cfg.title = a.name
        cfg.image = UIImage(systemName: a.icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        cfg.imagePlacement = .top
        cfg.imagePadding = 4
        // Resim tuşu ⏎ renginde: tek "farklı" tuş, tasarımdaki turuncunun yerine.
        cfg.baseBackgroundColor = image ? accent : chipFace
        cfg.baseForegroundColor = image ? accentText : theme.functionText
        cfg.background.cornerRadius = 14
        cfg.titleTextAttributesTransformer = .init { a in var a = a; a.font = .systemFont(ofSize: 13, weight: .bold); return a }
        cfg.titleLineBreakMode = .byTruncatingTail
        let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.onRun?(a) })
        b.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return b
    }

    private func button(_ title: String, fill: UIColor, ink: UIColor, _ action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = fill
        cfg.baseForegroundColor = ink
        cfg.background.cornerRadius = 12
        cfg.titleTextAttributesTransformer = .init { a in var a = a; a.font = .systemFont(ofSize: 15, weight: .bold); return a }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    /// Kaynak kutusu: üstte nereden geldiği, altta metin. Başka kaynak varsa
    /// dokununca sıradakine geçiyor (⇄).
    private func sourceBox(_ source: String, label: String, canSwitch: Bool) -> UIView {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = chipFace.withAlphaComponent(0.6)
        cfg.baseForegroundColor = ink
        cfg.background.cornerRadius = 10
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        cfg.titleAlignment = .leading
        let head = canSwitch ? label + "  ⇄" : label
        cfg.attributedTitle = AttributedString(head, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: accent]))
        cfg.attributedSubtitle = AttributedString(source.isEmpty ? "Metin yok — bir şey seç ya da kopyala" : "“\(source)”",
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13),
                                            .foregroundColor: ink.withAlphaComponent(0.75)]))
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.subtitleLineBreakMode = .byTruncatingTail
        let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.onSourceTap?() })
        b.contentHorizontalAlignment = .leading
        b.isUserInteractionEnabled = canSwitch
        b.accessibilityLabel = "\(label): \(source)"
        b.accessibilityHint = canSwitch ? "Kaynağı değiştirmek için dokun" : nil
        return b
    }

    private func chip(_ text: String, symbol: String) -> UIView {
        var cfg = UIButton.Configuration.filled()
        cfg.title = text
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        cfg.imagePadding = 5
        cfg.baseBackgroundColor = accent.withAlphaComponent(0.15)
        cfg.baseForegroundColor = ink
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        cfg.titleTextAttributesTransformer = .init { a in var a = a; a.font = .systemFont(ofSize: 13, weight: .bold); return a }
        let b = UIButton(configuration: cfg)
        b.isUserInteractionEnabled = false
        // Satır daralınca başlık kısalsın; saat çipi tam kalmalı ("Yarın 09:0" oluyordu).
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Ana düğme (⏎ rengi) + "Düzenle".
    private func addEditRow(_ title: String) -> UIView {
        let add = button(title, fill: accent, ink: accentText) { [weak self] in self?.onAdd?() }
        let edit = button("Düzenle", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onEdit?() }
        let buttons = UIStackView(arrangedSubviews: [add, edit])
        buttons.spacing = 8
        add.widthAnchor.constraint(equalTo: edit.widthAnchor, multiplier: 1.4).isActive = true
        return buttons
    }

    private func smallLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .bold)
        l.textColor = accent
        return l
    }

    /// Simge + (etiket) + metin satırı: konum, telefon, e-posta.
    private func iconLine(_ symbol: String, _ text: String, tag: String? = nil) -> UIView {
        let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        iv.tintColor = accent
        iv.contentMode = .center
        iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let row = UIStackView(arrangedSubviews: [iv])
        row.spacing = 8
        row.alignment = .center
        if let tag {
            let t = UILabel()
            t.text = tag
            t.font = .systemFont(ofSize: 12)
            t.textColor = ink.withAlphaComponent(0.65)
            t.widthAnchor.constraint(equalToConstant: 54).isActive = true
            row.addArrangedSubview(t)
        }
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 15)
        l.textColor = ink
        l.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(l)
        return row
    }

    /// İnce çerçeveli kutu (hatırlatıcı listesi, etkinlik, kişi).
    private func framed(_ v: UIView) -> UIView {
        let f = padded(v, background: .clear)
        f.layer.borderColor = chipFace.cgColor
        f.layer.borderWidth = 1
        f.layer.cornerRadius = 14
        return f
    }

    private func padded(_ v: UIView, background: UIColor) -> UIView {
        let box = UIView()
        box.backgroundColor = background
        box.layer.cornerRadius = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        return box
    }
}

