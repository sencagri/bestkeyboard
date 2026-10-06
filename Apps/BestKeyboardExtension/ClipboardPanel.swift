import UIKit

/// Pano geçmişi — yalnız klavyenin kendi sandbox'ında.
///
/// ## Ne saklanıyor, ne saklanmıyor
///
/// Klavye panoyu yalnız **açıldığında ve pano değişmişse** okuyor
/// (`changeCount`). iOS her okumada "BestKeyboard … yapıştırdı" bildirimi
/// gösteriyor; değişmemiş panoyu tekrar okumak bu bildirimi boşuna
/// tekrarlardı. Parola yöneticilerinin "gizli" işaretlediği içerik
/// (`org.nspasteboard.ConcealedType`) hiç okunmuyor, parola alanında da
/// okuma yapılmıyor.
///
/// ## Resim neden doğrudan yapıştırılamıyor
///
/// iOS klavyeye belgeye yalnız **metin** yazma yetkisi veriyor
/// (`UITextDocumentProxy`). Resim panoda kalıyor; kullanıcı kutuya basılı
/// tutup Yapıştır diyor. Geçmişteki bir resme dokunmak onu panoya geri
/// koyuyor.
struct ClipboardStore {
    enum Item: Codable, Equatable {
        case text(String)
        /// Dosya adı, `directory` altında.
        case image(String)
    }

    private(set) var items: [Item] = []
    static let capacity = 20
    static let imageCapacity = 6
    /// Çok uzun metin geçmişi şişiriyor ve önizlemede okunmuyor.
    static let maxTextLength = 2000

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("clipboard", isDirectory: true)
    }

    static func load() -> ClipboardStore {
        var s = ClipboardStore()
        if let dir = directory,
           let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let items = try? JSONDecoder().decode([Item].self, from: data) {
            s.items = items
        }
        return s
    }

    func save() {
        guard let dir = Self.directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        }
    }

    mutating func add(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= Self.maxTextLength else { return }
        items.removeAll { $0 == .text(t) }
        items.insert(.text(t), at: 0)
        trim()
    }

    /// Resim klavye boyutunda saklanıyor (en uzun kenar 1024 px): panoya geri
    /// koymaya yetiyor, uzantının bellek ve disk bütçesini zorlamıyor.
    mutating func add(image: UIImage) -> UIImage? {
        guard let dir = Self.directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scaled = image.scaled(maxSide: 1024)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
        items.insert(.image(name), at: 0)
        trim()
        return scaled
    }

    mutating func remove(_ item: Item) {
        items.removeAll { $0 == item }
        if case let .image(name) = item { Self.deleteFile(name) }
    }

    mutating func clear() {
        for i in items { if case let .image(n) = i { Self.deleteFile(n) } }
        items.removeAll()
    }

    static func image(named name: String) -> UIImage? {
        directory.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent(name).path) }
    }

    private mutating func trim() {
        var images = 0
        items = items.filter { item in
            guard case let .image(n) = item else { return true }
            images += 1
            if images > Self.imageCapacity { Self.deleteFile(n); return false }
            return true
        }
        while items.count > Self.capacity {
            let last = items.removeLast()
            if case let .image(n) = last { Self.deleteFile(n) }
        }
    }

    private static func deleteFile(_ name: String) {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let k = maxSide / longest
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Pano geçmişi paneli — emoji paneliyle aynı yerde, klavyenin üstünde.
final class ClipboardPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPickText: ((String) -> Void)?
    var onPickImage: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onClose: (() -> Void)?
    var onEmoji: (() -> Void)?
    private let emojiButton = UIButton(type: .system)

    private var items: [ClipboardStore.Item]
    private var theme: KeyboardTheme
    private var collection: UICollectionView!
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    init(items: [ClipboardStore.Item], theme: KeyboardTheme) {
        self.items = items
        self.theme = theme
        super.init(frame: .zero)
        build()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(items new: [ClipboardStore.Item]) {
        items = new
        collection.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }

    /// Kısa bilgi — resim panoya kondu gibi.
    func flash(_ text: String) {
        hintLabel.text = text
        hintLabel.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 2.6, options: []) { self.hintLabel.alpha = 0.75 }
    }

    private func build() {
        titleLabel.text = "Pano geçmişi"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.numberOfLines = 2
        hintLabel.text = "Metne dokun: yazılır. Resme dokun: panoya konur, kutuya basılı tutup Yapıştır de."
        hintLabel.alpha = 0.75

        closeButton.setTitle("ABC", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.accessibilityLabel = "harflere dön"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        clearButton.setTitle("Temizle", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15)
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(ClipCell.self, forCellWithReuseIdentifier: ClipCell.id)
        collection.disableEdgeEffects()

        emptyLabel.text = "Kopyaladığın metin ve resimler burada görünür"
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = !items.isEmpty

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), clearButton])
        header.alignment = .center
        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.setTitle(" Emoji", for: .normal)
        emojiButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        emojiButton.addAction(UIAction { [weak self] _ in self?.onEmoji?() }, for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [closeButton, emojiButton, UIView()])
        footer.spacing = 20
        for v in [header, hintLabel, collection!, emptyLabel, footer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 36),
            hintLabel.topAnchor.constraint(equalTo: header.bottomAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            collection.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 6),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: footer.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: collection.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -48),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.panelFace
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        for l in [titleLabel, hintLabel, emptyLabel] { l.textColor = theme.panelText }
        closeButton.tintColor = theme.accent
        clearButton.tintColor = theme.accent
        emojiButton.tintColor = theme.accent
        collection.reloadData()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: ClipCell.id, for: ip) as! ClipCell
        c.show(items[ip.item], theme: theme)
        return c
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        let w = (cv.bounds.width - 24 - 16) / 3
        return CGSize(width: max(60, floor(w)), height: 72)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        switch items[ip.item] {
        case let .text(t): onPickText?(t)
        case let .image(n): onPickImage?(n)
        }
    }
}

private final class ClipCell: UICollectionViewCell {
    static let id = "clip"
    private let label = UILabel()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 13)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        for v in [label, imageView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: ClipboardStore.Item, theme: KeyboardTheme) {
        contentView.backgroundColor = theme.keyFace
        label.textColor = theme.keyText
        switch item {
        case let .text(t):
            label.isHidden = false; imageView.isHidden = true
            label.text = t
            accessibilityLabel = "Metin: \(t)"
        case let .image(n):
            label.isHidden = true; imageView.isHidden = false
            imageView.image = ClipboardStore.image(named: n)
            accessibilityLabel = "Resim"
        }
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.5 : 1 }
    }
}
