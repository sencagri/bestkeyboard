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
    private var items: [MediaStore.Item] { all.filter { $0.kind == kind } }

    private let tabs = UISegmentedControl(items: ["GIF", "Çıkartma"])
    private var collection: UICollectionView!
    private let hint = UILabel()
    private let closeButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)

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

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(MediaCell.self, forCellWithReuseIdentifier: MediaCell.id)
        collection.disableEdgeEffects()

        hint.font = .systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.numberOfLines = 2

        closeButton.setTitle("ABC", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.setTitle(" Emoji", for: .normal)
        emojiButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        emojiButton.addAction(UIAction { [weak self] _ in self?.onEmoji?() }, for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [closeButton, emojiButton, UIView()])
        footer.spacing = 20

        for v in [tabs, collection!, hint, footer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            collection.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: footer.topAnchor),
            hint.centerXAnchor.constraint(equalTo: collection.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
            hint.widthAnchor.constraint(equalTo: widthAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
        ])
        updateHint()
    }

    private func updateHint() {
        hint.isHidden = !items.isEmpty
        hint.text = kind == .gif ? "Henüz GIF yok — uygulamada Stüdyo › Videodan GIF"
                                 : "Henüz çıkartma yok — uygulamada Stüdyo › Fotoğraftan çıkartma"
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.panelFace
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        hint.textColor = theme.panelText.withAlphaComponent(0.7)
        closeButton.tintColor = theme.accent
        emojiButton.tintColor = theme.accent
        tabs.selectedSegmentTintColor = theme.accent
        tabs.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
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

private final class MediaCell: UICollectionViewCell {
    static let id = "media"
    private let imageView = UIImageView()
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
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
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: MediaStore.Item) {
        imageView.image = MediaStore.thumbnail(item)
        let gif = item.kind == .gif
        imageView.contentMode = gif ? .scaleAspectFill : .scaleAspectFit
        badge.isHidden = !gif
        accessibilityLabel = gif ? "GIF, kopyala" : "Çıkartma, kopyala"
    }

    override var isHighlighted: Bool { didSet { contentView.alpha = isHighlighted ? 0.5 : 1 } }
}
