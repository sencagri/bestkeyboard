import UIKit

/// Kartın küçük parçaları: düğmeler, çipler, etiketler, çerçeveler.
extension AIPanel {
    func actionButton(_ a: AIAction) -> UIButton {
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
        cfg.setTitleFont(.systemFont(ofSize: 13, weight: .bold))
        cfg.titleLineBreakMode = .byTruncatingTail
        let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.onRun?(a) })
        b.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return b
    }

    func button(_ title: String, fill: UIColor, ink: UIColor, _ action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = fill
        cfg.baseForegroundColor = ink
        cfg.background.cornerRadius = 12
        cfg.setTitleFont(.systemFont(ofSize: 15, weight: .bold))
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    /// Kaynak kutusu: üstte nereden geldiği, altta metin. Başka kaynak varsa
    /// dokununca sıradakine geçiyor (⇄).
    func sourceBox(_ source: String, label: String, canSwitch: Bool) -> UIView {
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

    func chip(_ text: String, symbol: String) -> UIView {
        var cfg = UIButton.Configuration.filled()
        cfg.title = text
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        cfg.imagePadding = 5
        cfg.baseBackgroundColor = accent.withAlphaComponent(0.15)
        cfg.baseForegroundColor = ink
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        cfg.setTitleFont(.systemFont(ofSize: 13, weight: .bold))
        let b = UIButton(configuration: cfg)
        b.isUserInteractionEnabled = false
        // Satır daralınca başlık kısalsın; saat çipi tam kalmalı ("Yarın 09:0" oluyordu).
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Ana düğme (⏎ rengi) + "Düzenle".
    func addEditRow(_ title: String) -> UIView {
        let add = button(title, fill: accent, ink: accentText) { [weak self] in self?.onAdd?() }
        let edit = button(AddText.edit, fill: chipFace, ink: theme.functionText) { [weak self] in self?.onEdit?() }
        let buttons = UIStackView(arrangedSubviews: [add, edit])
        buttons.spacing = 8
        add.widthAnchor.constraint(equalTo: edit.widthAnchor, multiplier: 1.4).isActive = true
        return buttons
    }

    func smallLabel(_ text: String) -> UILabel { label(text, size: 12, weight: .bold, color: accent) }

    /// Kartın bütün yazıları bu yoldan; renk verilmezse kartın yazı rengi.
    func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                       color: UIColor? = nil, lines: Int = 1) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color ?? ink
        l.numberOfLines = lines
        return l
    }

    /// Simge + (etiket) + metin satırı: konum, telefon, e-posta.
    func iconLine(_ symbol: String, _ text: String, tag: String? = nil) -> UIView {
        let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        iv.tintColor = accent
        iv.contentMode = .center
        iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let row = UIStackView(arrangedSubviews: [iv])
        row.spacing = 8
        row.alignment = .center
        if let tag {
            let t = label(tag, size: 12, color: ink.withAlphaComponent(0.65))
            t.widthAnchor.constraint(equalToConstant: 54).isActive = true
            row.addArrangedSubview(t)
        }
        let l = label(text, size: 15)
        l.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(l)
        return row
    }

    /// İnce çerçeveli kutu (hatırlatıcı listesi, etkinlik, kişi).
    func framed(_ v: UIView) -> UIView {
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
