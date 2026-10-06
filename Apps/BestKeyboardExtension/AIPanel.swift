import UIKit

/// Klavyenin üstünde "havada" duran yapay zeka kartı — tasarım tuvali 22.
///
/// Klavye kendi alanının dışına çizemiyor; kart açılınca klavye yukarı
/// uzuyor ve kart o alana gölgeli, yuvarlak köşeli oturuyor. Durumlar:
/// seç → hazırlanıyor → metin ya da resim sonucu (ya da hata).
final class AIPanel: UIView {
    enum State {
        /// `label`: "Panodan", "Seçili metin", "Yazdığın". `canSwitch`: başka
        /// kaynak da var — kutuya dokununca değişiyor.
        case pick(source: String, label: String, canSwitch: Bool)
        case loading(String)
        case text(String)
        case image(UIImage)
        case error(String)
    }

    var onRun: ((AIAction) -> Void)?
    var onSourceTap: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onAppend: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSticker: (() -> Void)?
    var onAgain: (() -> Void)?
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

