import UIKit

/// Kartın durumları — her biri kendi çizimiyle (`show(_:)` yalnız dağıtıyor).
extension AIPanel {
    /// Seç: kaynak kutusu ve tuş ızgarası.
    func showPick(source: String, label: String, canSwitch: Bool) {
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
    }

    /// Hazırlanıyor.
    func showLoading(_ text: String) {
        titleLabel.text = "Hazırlanıyor"
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = accent
        spinner.startAnimating()
        let v = UIStackView(arrangedSubviews: [spinner, label(text, size: 14, color: ink.withAlphaComponent(0.7))])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 10
        v.heightAnchor.constraint(equalToConstant: 92).isActive = true
        v.distribution = .equalCentering
        body.addArrangedSubview(v)
    }

    /// Metin sonucu: değiştir / ekle / kopyala.
    func showText(_ result: String) {
        titleLabel.text = "Sonuç"
        body.addArrangedSubview(label(result, size: 17, lines: 6))
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
    }

    /// Resim sonucu: çıkartma / kopyala / yeniden.
    func showImage(_ img: UIImage) {
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
    }

    /// Yapılacaklar (tasarım 26, hedef çipleri tasarım 30).
    func showReminders(list: String?, rows: [(title: String, when: String?)]) {
        titleLabel.text = rows.count > 1 ? "\(rows.count) yapılacak" : "Hatırlatıcı"
        // Hedef çipleri (tasarım 30): yüklü olmayan soluk; seçim hatırlanıyor.
        let dest = TodoDestination.current
        let chips = UIStackView()
        chips.spacing = 6
        for d in TodoDestination.allCases {
            let b = PanelUI.chip(d.title) { [weak self] in
                TodoDestination.current = d
                if let s = self?.lastState { self?.show(s) }
            }
            PanelUI.styleChip(b, selected: d == dest, theme: theme)
            b.alpha = d.isAvailable ? 1 : 0.45
            chips.addArrangedSubview(b)
        }
        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        NSLayoutConstraint.activate(chipScroll.contentConstraints(chips, fillHeight: true)
            + [chipScroll.heightAnchor.constraint(equalToConstant: 32)])
        body.addArrangedSubview(chipScroll)
        if let note = dest.unavailableNote {
            body.addArrangedSubview(label(note, size: 12, color: ink.withAlphaComponent(0.75), lines: 2))
        }
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 8
        if let list {
            box.addArrangedSubview(smallLabel(dest != .apple ? dest.place(list)
                : AIService.reminderLists.contains(list) ? "Liste: \(list)" : "Yeni liste: \(list)"))
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
            let t = label(r.title, size: 16, weight: .semibold)
            let line = UIStackView(arrangedSubviews: [ring, t])
            line.spacing = 10
            line.alignment = .center
            if let when = r.when { line.addArrangedSubview(chip(when, symbol: "clock")) }
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            box.addArrangedSubview(line)
        }
        if rows.count > shown.count {
            box.addArrangedSubview(label(SettingsFormat.more(rows.count - shown.count, "madde"),
                                         size: 13, color: ink.withAlphaComponent(0.7)))
        }
        body.addArrangedSubview(framed(box))
        body.addArrangedSubview(addEditRow(dest.addTitle(count: rows.count)))
    }

    /// Takvim etkinlikleri (tasarım 28).
    func showEvents(calendar: String?, rows: [EventRow]) {
        titleLabel.text = rows.count > 1 ? "\(rows.count) etkinlik" : "Takvim"
        for (i, r) in rows.prefix(3).enumerated() {
            let v = UIStackView()
            v.axis = .vertical
            v.spacing = 7
            v.alignment = .leading
            if i == 0, let calendar {
                v.addArrangedSubview(smallLabel("Takvim: \(calendar)"))
            }
            v.addArrangedSubview(label(r.title, size: 17, weight: .semibold, lines: 2))
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
        if rows.count > 3 { body.addArrangedSubview(smallLabel(SettingsFormat.more(rows.count - 3, "etkinlik"))) }
        body.addArrangedSubview(addEditRow(AddText.events(rows.count)))
    }

    /// Kişi kartı (tasarım 29).
    func showContact(name: String, organization: String?, phones: [String], emails: [String]) {
        titleLabel.text = "Kişi"
        let avatar = label(AIService.ContactDraft.initials(of: name), size: 16, weight: .bold, color: .white)
        avatar.textAlignment = .center
        avatar.backgroundColor = BKPalette.avatar.ui
        avatar.layer.cornerRadius = 20
        avatar.clipsToBounds = true
        avatar.widthAnchor.constraint(equalToConstant: 40).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let names = UIStackView(arrangedSubviews: [
            label(name.nilIfEmpty ?? AIService.ContactDraft.unnamed, size: 17, weight: .semibold)])
        names.axis = .vertical
        names.spacing = 1
        if let organization {
            names.addArrangedSubview(label(organization, size: 13, color: ink.withAlphaComponent(0.7)))
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
        body.addArrangedSubview(addEditRow(AddText.contacts))
    }

    /// Kısa bilgi.
    func showInfo(title: String, message: String) {
        titleLabel.text = title
        body.addArrangedSubview(label(message, size: 15, lines: 4))
    }

    /// Hata.
    func showError(_ msg: String) {
        titleLabel.text = "Olmadı"
        body.addArrangedSubview(label(msg, size: 15, lines: 4))
        body.addArrangedSubview(button("Geri", fill: chipFace, ink: theme.functionText) { [weak self] in self?.onAgain?() })
    }
}
