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
        LocalStore.url(LocalStore.Name.clipboard, isDirectory: true)
    }

    private static var index: URL? { directory?.appendingPathComponent("index.json") }

    static func load() -> ClipboardStore {
        var s = ClipboardStore()
        s.items = JSONFile.read([Item].self, at: index) ?? []
        return s
    }

    func save() {
        JSONFile.write(items, to: Self.index, protected: true)
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

/// Pano geçmişi paneli — emoji paneliyle aynı yerde, klavyenin üstünde.
final class ClipboardPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPickText: ((String) -> Void)?
    var onPickImage: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onClose: (() -> Void)?
    var onEmoji: (() -> Void)?
    private lazy var emojiButton = PanelUI.emojiButton { [weak self] in self?.onEmoji?() }

    private var items: [ClipboardStore.Item]
    private var theme: KeyboardTheme
    private var collection: UICollectionView!
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private lazy var closeButton = PanelUI.lettersButton { [weak self] in self?.onClose?() }
    private lazy var clearButton = PanelUI.button(title: "Temizle", weight: .regular) { [weak self] in self?.onClear?() }
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
        titleLabel.text = PanelUI.Label.clipboard
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.numberOfLines = 2
        hintLabel.text = "Metne dokun: yazılır. Resme dokun: panoya konur, kutuya basılı tutup Yapıştır de."
        hintLabel.alpha = 0.75

        collection = PanelUI.grid(spacing: 8, inset: UIEdgeInsets(top: 4, left: 12, bottom: 8, right: 12),
                                  cell: ClipCell.self, id: ClipCell.id, owner: self)

        emptyLabel.text = "Kopyaladığın metin ve resimler burada görünür"
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = !items.isEmpty

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), clearButton])
        header.alignment = .center
        let footer = PanelUI.footer([closeButton, emojiButton])
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
        ] + pinFooter(footer))
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        applyPanelChrome(theme, buttons: [closeButton, clearButton, emojiButton])
        titleLabel.textColor = theme.barText
        for l in [hintLabel, emptyLabel] { l.textColor = theme.barSecondaryText }
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

private final class ClipCell: PanelCell {
    static let id = "clip"
    private let label = UILabel()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
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
}
