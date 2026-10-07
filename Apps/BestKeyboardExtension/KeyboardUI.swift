import UIKit

/// Klavye panellerinin (emoji, pano, medya) ortak parçaları — alt sıra
/// düğmeleri, ızgara ve kutucuk. Üç panel bunları ayrı ayrı yazıyordu ve
/// yazı kalınlığı, erişilebilirlik adı gibi ayrıntılar ayrışmıştı.
enum PanelUI {
    static let footerHeight: CGFloat = 40
    /// Geçici mesajların (balon, panel ipucu, düğme yazısı) görünme süresi.
    static let messageDuration: TimeInterval = 2.5

    /// Erişilebilirlik adları — düğmenin **ne yaptığı** (görünen yazı değil).
    enum Label {
        /// "ABC, düğme" denince üç harf yazan bir tuş sanılıyor; panel kapanıp
        /// klavyeye dönülüyor. Tuş yüzeyindeki aynı rol de "harfler".
        static let letters = "harflere dön"
        static let clipboard = "Pano geçmişi"
        static let dismissKeyboard = "Klavyeyi kapat"
    }

    /// "ABC" — paneli kapatıp harflere döner.
    static func lettersButton(_ action: @escaping () -> Void) -> UIButton {
        button(title: "ABC", weight: .semibold, label: Label.letters, action)
    }

    static func emojiButton(_ action: @escaping () -> Void) -> UIButton {
        button(title: " Emoji", symbol: "face.smiling", action)
    }

    static func clipboardButton(_ action: @escaping () -> Void) -> UIButton {
        button(title: " Pano", symbol: "doc.on.clipboard", label: Label.clipboard, action)
    }

    static func button(title: String?, symbol: String? = nil, weight: UIFont.Weight = .medium,
                       label: String? = nil, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        if let symbol { b.setImage(UIImage(systemName: symbol), for: .normal) }
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: weight)
        if let label { b.accessibilityLabel = label }
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// Alt sıra: soldakiler yan yana, sağdakiler sağa yaslı.
    static func footer(_ leading: [UIView], trailing: [UIView] = []) -> UIStackView {
        let s = UIStackView(arrangedSubviews: leading + [UIView()] + trailing)
        s.spacing = 20
        return s
    }

    /// Kaydırılan ızgara (kenar efektleri kapalı, saydam).
    static func grid(spacing: CGFloat, inset: UIEdgeInsets = .zero, cell: UICollectionViewCell.Type,
                     id: String, owner: UICollectionViewDataSource & UICollectionViewDelegate) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = inset
        let c = UICollectionView(frame: .zero, collectionViewLayout: layout)
        c.backgroundColor = .clear
        c.dataSource = owner
        c.delegate = owner
        c.register(cell, forCellWithReuseIdentifier: id)
        c.disableEdgeEffects()
        return c
    }
}

extension UIView {
    /// Panelin zemini, açık/koyu kipi ve çubuk rengindeki düğmeleri — bütün
    /// paneller aynı (klavyenin bir parçası gibi dursun).
    func applyPanelChrome(_ theme: KeyboardTheme, buttons: [UIButton]) {
        applyPanelBackdrop(theme)
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        for b in buttons {
            b.tintColor = theme.barText
            b.setTitleColor(theme.barText, for: .normal)
        }
    }

    /// Alt sırayı panelin dibine yerleştirir.
    func pinFooter(_ footer: UIView) -> [NSLayoutConstraint] {
        [footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
         footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
         footer.bottomAnchor.constraint(equalTo: bottomAnchor),
         footer.heightAnchor.constraint(equalToConstant: PanelUI.footerHeight)]
    }
}

/// Dokunulan kutucuk: düğme olarak okunur, basılınca solar; köşeleri 12 pt
/// (`isRounded`).
class PanelCell: UICollectionViewCell {
    var pressedAlpha: CGFloat { 0.5 }
    class var isRounded: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        if Self.isRounded {
            contentView.layer.cornerRadius = 12
            contentView.clipsToBounds = true
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? pressedAlpha : 1 }
    }
}

extension UIScrollView {
    /// İçerik görünümünü kaydırma alanına ekleyip bağlayan kısıtlar. `fillHeight`
    /// / `fillWidth`: o eksende kaydırma yok, içerik alanı doldurur.
    func contentConstraints(_ v: UIView, insets: UIEdgeInsets = .zero,
                            fillHeight: Bool = false, fillWidth: Bool = false) -> [NSLayoutConstraint] {
        if v.superview !== self {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let g = contentLayoutGuide, f = frameLayoutGuide
        var c = [v.topAnchor.constraint(equalTo: g.topAnchor, constant: insets.top),
                 v.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -insets.bottom),
                 v.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: insets.left),
                 v.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -insets.right)]
        if fillHeight { c.append(v.heightAnchor.constraint(equalTo: f.heightAnchor, constant: -(insets.top + insets.bottom))) }
        if fillWidth { c.append(v.widthAnchor.constraint(equalTo: f.widthAnchor, constant: -(insets.left + insets.right))) }
        return c
    }
}

extension UIView {
    /// Seçili çip/sekme ekran okuyucuya "seçili" diye okunsun.
    func markSelected(_ on: Bool) {
        accessibilityTraits = on ? [.button, .selected] : .button
    }
}

extension UIButton.Configuration {
    /// Başlığın yazı tipi (sistem yazı tipi ölçeklemesini ezmeden).
    mutating func setTitleFont(_ font: UIFont) {
        titleTextAttributesTransformer = .init { a in var a = a; a.font = font; return a }
    }
}

extension CATransaction {
    /// Katman güncellemesi **animasyonsuz** (yazma yolunda örtük CoreAnimation
    /// animasyonu istemiyoruz). `commit()` çağıranın işi.
    static func beginWithoutActions() {
        begin()
        setDisableActions(true)
    }
}

extension Timer {
    /// Ana döngüde, kaydırma ve dokunma sırasında da çalışan (`.common` kip)
    /// tek seferlik zamanlayıcı.
    @discardableResult
    static func onMainLoop(after interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

/// Etkinleştirilebilir erişilebilirlik öğesi.
///
/// `UIButton` bunu bedava veriyordu; `CALayer`'a geçince kaybolan tek şey buydu.
/// Düz bir `UIAccessibilityElement` etiketi **okutuyor** ama çift dokunuşu
/// hiçbir yere iletmiyor: VoiceOver kullanıcısı tuşu duyup basamıyordu.
///
/// Tuş yüzeyi ve öneri çubuğu aynı sınıfı kullanıyor. Ayrı ayrı yazıldıklarında
/// ikisi de aynı kusuru taşıyordu; iki kopyanın ayrışması an meselesiydi.
final class ActivatableAccessibilityElement: UIAccessibilityElement {
    /// Etkinleştirmeyi **kabul edip etmediğini** döndürür.
    ///
    /// `Void` dönseydi reddedilen bir etkinleştirme (kayıt ekranındaki tuşlar)
    /// VoiceOver'a "oldu" diye bildirilirdi ve kullanıcı hiçbir şey olmadığını
    /// ancak metne bakarak anlardı.
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}
