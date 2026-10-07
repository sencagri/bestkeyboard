import UIKit

/// Klavyede stüdyo GIF'leri ve çıkartmaları — tasarım tuvali "16 · Klavyede
/// GIF ve çıkartma". Dokunulan öğe panoya kopyalanıyor (klavye belgeye resim
/// yazamıyor); kullanıcı mesaj kutusuna basılı tutup Yapıştır diyor.
final class MediaPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onCopied: (() -> Void)?
    var onClose: (() -> Void)?
    var onEmoji: (() -> Void)?

    private var theme: KeyboardTheme
    private var all: [MediaStore.Item]
    private var kind: MediaStore.Item.Kind = .gif
    /// `nil` = Tümü.
    private var category: String?
    private var items: [MediaStore.Item] {
        MediaStore.filter(all, kind: kind, category: category)
    }
    private let chipBar = UIScrollView()
    private let chipRow = UIStackView()
    private var chipButtons: [(String?, UIButton)] = []

    private let tabs = UISegmentedControl(items: ["GIF", "Çıkartma"])
    private var collection: UICollectionView!
    private let hint = UILabel()
    private lazy var closeButton = PanelUI.lettersButton { [weak self] in self?.onClose?() }
    private lazy var emojiButton = PanelUI.emojiButton { [weak self] in self?.onEmoji?() }

    init(theme: KeyboardTheme) {
        self.theme = theme
        self.all = MediaStore.load()
        super.init(frame: .zero)
        build()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        tabs.selectedSegmentIndex = 0
        tabs.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.kind = self.tabs.selectedSegmentIndex == 0 ? .gif : .sticker
            self.collection.reloadData()
            self.updateHint()
        }, for: .valueChanged)

        collection = PanelUI.grid(spacing: 8, inset: UIEdgeInsets(top: 4, left: 10, bottom: 8, right: 10),
                                  cell: MediaCell.self, id: MediaCell.id, owner: self)

        hint.font = .systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.numberOfLines = 2

        let footer = PanelUI.footer([closeButton, emojiButton])

        // Kategori çipleri — yalnız kategori varsa.
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.disableEdgeEffects()
        chipRow.axis = .horizontal
        chipRow.spacing = 6
        let cats = MediaStore.categories()
        for c in ([nil] as [String?]) + cats.map(Optional.some) {
            let b = PanelUI.chip(c ?? "Tümü") { [weak self] in
                self?.category = c
                self?.collection.reloadData()
                self?.updateHint()
                self?.refreshChips()
            }
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            chipButtons.append((c, b))
            chipRow.addArrangedSubview(b)
        }
        chipBar.isHidden = cats.isEmpty

        for v in [tabs, chipBar, collection!, hint, footer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chipBar.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            chipBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chipBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chipBar.heightAnchor.constraint(equalToConstant: cats.isEmpty ? 0 : 32),

            collection.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: 6),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: footer.topAnchor),
            hint.centerXAnchor.constraint(equalTo: collection.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
            hint.widthAnchor.constraint(equalTo: widthAnchor, constant: -40),
        ] + chipBar.contentConstraints(chipRow, insets: UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0))
          + pinFooter(footer))
        updateHint()
    }

    private func refreshChips() {
        for (c, b) in chipButtons {
            PanelUI.styleChip(b, selected: c == category, theme: theme)
        }
    }

    private func updateHint() {
        hint.isHidden = !items.isEmpty
        hint.text = category != nil ? "Bu kategoride henüz yok"
            : kind == .gif ? "Henüz GIF yok — uygulamada Stüdyo › Videodan GIF"
                           : "Henüz çıkartma yok — uygulamada Stüdyo › Fotoğraftan çıkartma"
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        applyPanelChrome(theme, buttons: [closeButton, emojiButton])
        hint.textColor = theme.barSecondaryText
        // Seçili sekme ⏎ renginde, zemin işlev tuşu — kartla aynı dil.
        tabs.backgroundColor = theme.functionFace
        tabs.selectedSegmentTintColor = theme.returnFace
        tabs.setTitleTextAttributes([.foregroundColor: theme.returnText], for: .selected)
        tabs.setTitleTextAttributes([.foregroundColor: theme.functionText], for: .normal)
        refreshChips()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: MediaCell.id, for: ip) as! MediaCell
        c.show(items[ip.item])
        return c
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        let cols: CGFloat = kind == .gif ? 3 : 4
        let w = (cv.bounds.width - 20 - 8 * (cols - 1)) / cols
        return CGSize(width: floor(w), height: kind == .gif ? 92 : floor(w))
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        if MediaStore.copyToPasteboard(items[ip.item]) { onCopied?() }
    }
}

private final class MediaCell: PanelCell {
    static let id = "media"
    private let imageView = UIImageView()
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        badge.text = " GIF "
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: MediaStore.Item) {
        imageView.image = MediaStore.thumbnail(item)
        let gif = item.kind == .gif
        imageView.contentMode = gif ? .scaleAspectFill : .scaleAspectFit
        badge.isHidden = !gif
        accessibilityLabel = gif ? "GIF, kopyala" : "Çıkartma, kopyala"
    }
}
