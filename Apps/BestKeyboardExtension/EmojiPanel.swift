import UIKit
import KBRuntime

/// Emoji yüzeyi — klavyenin üstünü kaplayan örtü katman.
///
/// ## Neden tuş ızgarası değil
///
/// `KeyboardView` sabit bir ızgara çiziyor ve her tuşu `KeyLayout`'tan alıyor.
/// Emoji'yi oraya koymak iki şeyi birden bozardı: ızgara kaydırılamıyor (yüzlerce
/// emoji sığmaz), ve daha kötüsü **`layoutID` değişirdi** — tuş yuvası eklemek
/// harf merkezlerini kaydırır, kalibrasyon profili başka bir kovaya düşer ve
/// kullanıcı öğrettiği parmak sapmasını kaybederdi (§8.6).
///
/// Ayar paneliyle aynı çözüm: ayrı bir görünüm, klavyenin üstünde.
///
/// ## Neden `UICollectionView`
///
/// §11.B Auto Layout'u **yazma yolunda** yasaklıyor. Emoji yüzeyi açıkken
/// yazılmıyor, dolayısıyla buradaki maliyet ölçülebilir bir yere düşmüyor.
/// Hücre yeniden kullanımı ise uzantının dar bellek bütçesinde asıl kazanç:
/// altı yüz emoji için altı yüz `UIButton` tutmak gerekmiyor.
final class EmojiPanel: UIView {

    /// Kullanıcı bir emoji seçti — **belgeye yazmak çağıranın işi**.
    ///
    /// Panel doğrudan `textDocumentProxy`'ye yazmıyor: giriş kaydediciden
    /// geçmek zorunda, yoksa kaydın görmediği bir mutasyon olurdu (§12.6).
    var onPick: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onClose: (() -> Void)?

    private enum Section: Hashable { case grid }

    private let categoryBar = UIScrollView()
    private let categoryStack = UIStackView()
    private var collection: UICollectionView!
    private let closeButton = UIButton(type: .system)
    private let backspaceButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    private var theme: KeyboardTheme
    private var recents: EmojiRecents
    private var categoryButtons: [(id: String, button: UIButton)] = []

    /// Son kullanılanlar sekmesinin kimliği — katalogla çakışmaması için
    /// katalogda bulunmayan bir değer.
    private static let recentsID = "__recents"

    private var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            syncCategorySelection()
            collection.reloadData()
            collection.setContentOffset(.zero, animated: false)
            updateEmptyState()
        }
    }

    private var items: [String] {
        selectedID == Self.recentsID
            ? recents.items
            : (EmojiCatalog.category(id: selectedID)?.emoji ?? [])
    }

    init(theme: KeyboardTheme, recents: EmojiRecents) {
        self.theme = theme
        self.recents = recents
        // Son kullanılanlar boşsa oradan başlamak boş bir ekran gösterirdi.
        self.selectedID = recents.isEmpty
            ? (EmojiCatalog.categories.first?.id ?? Self.recentsID)
            : Self.recentsID
        super.init(frame: .zero)
        build()
        apply(theme: theme)
        syncCategorySelection()
        updateEmptyState()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Kurulum

    private func build() {
        // --- Izgara ---
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.dataSource = self
        collection.delegate = self
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.id)
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)

        emptyLabel.text = "Henüz emoji kullanmadın"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        // --- Kategori çubuğu ---
        categoryStack.axis = .horizontal
        categoryStack.distribution = .fillEqually
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.addSubview(categoryStack)
        categoryBar.showsHorizontalScrollIndicator = false
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryBar)

        func tab(id: String, symbol: String, title: String) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(symbol, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 20)
            b.accessibilityLabel = title
            b.addAction(UIAction { [weak self] _ in self?.selectedID = id },
                        for: .touchUpInside)
            categoryButtons.append((id, b))
            return b
        }

        categoryStack.addArrangedSubview(
            tab(id: Self.recentsID, symbol: "🕘", title: "Son kullanılanlar"))
        for c in EmojiCatalog.categories {
            categoryStack.addArrangedSubview(tab(id: c.id, symbol: c.symbol, title: c.title))
        }

        // --- Alt sıra ---
        closeButton.setTitle("ABC", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        closeButton.accessibilityIdentifier = "key.emoji.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() },
                              for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        backspaceButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        backspaceButton.accessibilityIdentifier = "key.emoji.backspace"
        backspaceButton.accessibilityLabel = "Sil"
        backspaceButton.addAction(UIAction { [weak self] _ in self?.onBackspace?() },
                                  for: .touchUpInside)
        backspaceButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backspaceButton)

        NSLayoutConstraint.activate([
            categoryBar.topAnchor.constraint(equalTo: topAnchor),
            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            categoryStack.topAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.topAnchor),
            categoryStack.bottomAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.bottomAnchor),
            categoryStack.leadingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.leadingAnchor),
            categoryStack.trailingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.trailingAnchor),
            categoryStack.heightAnchor.constraint(equalTo: categoryBar.frameLayoutGuide.heightAnchor),
            categoryStack.widthAnchor.constraint(equalTo: categoryBar.frameLayoutGuide.widthAnchor),

            collection.topAnchor.constraint(equalTo: categoryBar.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor,
                                               constant: -Self.barHeight),

            emptyLabel.centerXAnchor.constraint(equalTo: collection.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collection.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            closeButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: Self.barHeight),

            backspaceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            backspaceButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            backspaceButton.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
    }

    private static let barHeight: CGFloat = 40
    /// Hücre kenarı — parmak hedefi için alt sınır 40 pt.
    private static let cellSide: CGFloat = 42

    // MARK: - Durum

    /// Son kullanılanlar dışarıda değişti (yeni emoji seçildi).
    func update(recents new: EmojiRecents) {
        recents = new
        if selectedID == Self.recentsID {
            collection.reloadData()
            updateEmptyState()
        }
    }

    private func syncCategorySelection() {
        for (id, b) in categoryButtons {
            let on = id == selectedID
            b.backgroundColor = on ? theme.pressedFace : .clear
            b.accessibilityTraits = on ? [.button, .selected] : [.button]
        }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !items.isEmpty
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.panelFace
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        closeButton.tintColor = theme.accent
        backspaceButton.tintColor = theme.accent
        emptyLabel.textColor = theme.barSecondaryText
        categoryBar.backgroundColor = theme.barFace
        syncCategorySelection()
        collection.reloadData()
    }
}

// MARK: - Izgara veri kaynağı

extension EmojiPanel: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: EmojiCell.id,
                                          for: indexPath) as! EmojiCell
        cell.show(items[indexPath.item], color: theme.panelText)
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        onPick?(items[indexPath.item])
        cv.deselectItem(at: indexPath, animated: false)
    }

    /// Satıra sığan kadar hücre; kalan boşluk hücrelere dağıtılıyor ki ızgara
    /// sağda yamuk bir şerit bırakmasın.
    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = cv.bounds.width
        guard width > 0 else { return CGSize(width: Self.cellSide, height: Self.cellSide) }
        let perRow = max(1, Int(width / Self.cellSide))
        let side = width / CGFloat(perRow)
        return CGSize(width: side, height: Self.cellSide)
    }
}

/// Tek emoji hücresi.
private final class EmojiCell: UICollectionViewCell {
    static let id = "emoji"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        // Emoji fontu boyutla ölçekleniyor; sabit bir punto farklı hücre
        // boyutlarında taşardı.
        label.font = .systemFont(ofSize: 28)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ emoji: String, color: UIColor) {
        label.text = emoji
        label.textColor = color
        accessibilityLabel = emoji
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.4 : 1 }
    }
}
