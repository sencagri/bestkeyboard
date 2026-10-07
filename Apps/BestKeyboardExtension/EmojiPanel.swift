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
    /// Pano geçmişi — öneri çubuğundaki 📋 düğmesi buraya taşındı.
    var onClipboard: (() -> Void)?
    private lazy var clipboardButton = PanelUI.clipboardButton { [weak self] in self?.onClipboard?() }
    /// Stüdyo GIF'leri ve çıkartmaları.
    var onMedia: (() -> Void)?
    private lazy var mediaButton = PanelUI.button(title: "GIF", weight: .bold, label: "GIF ve çıkartmalar") { [weak self] in self?.onMedia?() }

    private enum Section: Hashable { case grid }

    private let categoryBar = UIScrollView()
    private let categoryStack = UIStackView()
    private var collection: UICollectionView!
    private lazy var closeButton = PanelUI.lettersButton { [weak self] in self?.onClose?() }
    private lazy var backspaceButton = PanelUI.button(title: nil, symbol: "delete.left", label: "Sil") { [weak self] in self?.onBackspace?() }
    private let emptyLabel = UILabel()

    private var theme: KeyboardTheme
    /// Ekranda gösterilen sıra. Panel açıkken **donuk**: her dokunuşta
    /// basılan emoji başa geçince ızgara parmağın altında kayıyor, art arda
    /// basılan iki emoji sürekli yer değiştiriyordu. En güncel liste
    /// `latestRecents`'te bekliyor; sekmeye yeniden geçince ya da panel bir
    /// sonraki açılışında uygulanıyor.
    private var recents: EmojiRecents
    private var latestRecents: EmojiRecents
    private var categoryButtons: [(id: String, button: UIButton)] = []

    /// Son kullanılanlar sekmesinin kimliği — katalogla çakışmaması için
    /// katalogda bulunmayan bir değer.
    private static let recentsID = "__recents"

    private var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            if selectedID == Self.recentsID { recents = latestRecents }
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
        self.latestRecents = recents
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
        collection = PanelUI.grid(spacing: 0, cell: EmojiCell.self, id: EmojiCell.id, owner: self)
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
        categoryBar.showsHorizontalScrollIndicator = false
        categoryBar.disableEdgeEffects()
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
        closeButton.accessibilityIdentifier = "key.emoji.close"
        backspaceButton.accessibilityIdentifier = "key.emoji.backspace"
        let footer = PanelUI.footer([closeButton, clipboardButton, mediaButton], trailing: [backspaceButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        NSLayoutConstraint.activate([
            categoryBar.topAnchor.constraint(equalTo: topAnchor),
            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: Self.barHeight),


            collection.topAnchor.constraint(equalTo: categoryBar.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor,
                                               constant: -PanelUI.footerHeight),

            emptyLabel.centerXAnchor.constraint(equalTo: collection.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
        ] + categoryBar.contentConstraints(categoryStack, fillHeight: true, fillWidth: true) + pinFooter(footer))
    }

    private static let barHeight: CGFloat = 40
    /// Hücre kenarı — parmak hedefi için alt sınır 40 pt.
    private static let cellSide: CGFloat = 42

    // MARK: - Durum

    /// Son kullanılanlar dışarıda değişti (yeni emoji seçildi).
    func update(recents new: EmojiRecents) {
        latestRecents = new
        // Sekme başka bir kategorideyken gösterilen liste yok; hemen uygulanabilir.
        if selectedID != Self.recentsID { recents = new }
    }

    private func syncCategorySelection() {
        for (id, b) in categoryButtons {
            let on = id == selectedID
            b.backgroundColor = on ? theme.pressedFace : .clear
            b.markSelected(on)
        }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !items.isEmpty
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        // Tema arka planı + öneri çubuğu yazı rengi: panel klavyenin bir
        // parçası gibi dursun (yapay zeka kartıyla aynı ilke).
        applyPanelChrome(theme, buttons: [closeButton, backspaceButton, clipboardButton, mediaButton])
        emptyLabel.textColor = theme.barSecondaryText
        categoryBar.backgroundColor = theme.functionFace.withAlphaComponent(0.35)
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
        cell.show(items[indexPath.item], color: theme.barText)
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
private final class EmojiCell: PanelCell {
    override var pressedAlpha: CGFloat { 0.4 }
    override class var isRounded: Bool { false }
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ emoji: String, color: UIColor) {
        label.text = emoji
        label.textColor = color
        accessibilityLabel = emoji
    }
}
