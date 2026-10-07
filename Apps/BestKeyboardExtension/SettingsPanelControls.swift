import UIKit
import KBGeometry
import KBRuntime

/// Etiket + değer + sürgü. Değer her zaman yazılı: "geniş/dar" gibi göreli bir
/// ifade, kullanıcının aynı ayarı ikinci cihazda tekrarlamasını imkânsız kılar.
final class SliderRow: UIStackView {
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let step: Double
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    var value: Double {
        get { Double(slider.value) }
        set {
            slider.value = Float(newValue)
            valueLabel.text = format(newValue)
            // Değer sürgünün **kendi** erişilebilirlik değeri oluyor.
            //
            // `UISlider` varsayılan olarak yüzde okuyor ("%40") — oysa burada
            // anlamlı olan biçimlendirilmiş değer ("1.25 birim"). Yüzde,
            // kullanıcının aynı ayarı ikinci bir cihazda tekrarlamasını
            // imkânsız kılıyor; `valueLabel`'ın var olma sebebiyle aynı gerekçe.
            slider.accessibilityValue = format(newValue)
        }
    }

    /// - Parameter step: kademe **parametre başına**. Genişlik ile yükseklik
    ///   aynı ızgarada olamaz: 1 birim genişlik ≈ 36 pt, 1 birim yükseklik
    ///   ≈ 54 pt, aynı adım birinde ince diğerinde kaba kalıyor.
    convenience init(_ spec: SliderSpec, onChange: @escaping (Double) -> Void) {
        self.init(title: spec.title, range: spec.range, step: spec.step, format: spec.format, onChange: onChange)
    }

    init(title text: String, range: ClosedRange<Double>, step: Double,
         format: @escaping (Double) -> String = { SettingsFormat.decimal("%.2f", $0) },
         onChange: @escaping (Double) -> Void) {
        self.step = step
        self.format = format
        self.onChange = onChange
        super.init(frame: .zero)

        title.text = text
        title.font = .systemFont(ofSize: 14)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        // Sürgünün adı başlıktan geliyor. Başlık ayrı bir `UILabel` ve VoiceOver
        // onu ayrı bir durak olarak okuyor; sürgüye gelindiğinde elde yalnız
        // isimsiz bir değer kalıyordu ("%40, ayarlanabilir") — hangi ayar
        // olduğu ancak bir önceki durağı hatırlayarak anlaşılıyordu.
        slider.accessibilityLabel = text
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Sürekli değeri kademeye oturt: sürgü serbest bıraksa 1.3271 gibi
            // değerler üretir ve her biri ayrı bir kalibrasyon profili olurdu.
            let snapped = (Double(self.slider.value) / self.step).rounded() * self.step
            self.value = snapped
            self.onChange(snapped)
        }, for: .valueChanged)

        let head = UIStackView(arrangedSubviews: [title, valueLabel])
        head.axis = .horizontal
        axis = .vertical
        spacing = 2
        addArrangedSubview(head)
        addArrangedSubview(slider)
    }

    required init(coder: NSCoder) { fatalError() }

    func apply(theme: KeyboardTheme) {
        title.textColor = theme.panelText
        valueLabel.textColor = theme.barSecondaryText
        slider.tintColor = theme.controlTint
        slider.minimumTrackTintColor = theme.controlTint
    }
}

/// Tema seçici: her tema kendi zemini ve tuş renkleriyle küçük bir kare.
///
/// Bölümlü denetim (`Sistem/Açık/Koyu`) üç seçenekte işe yarıyordu; on iki
/// seçenekte adlar okunmaz hâle geliyor ve "Okyanus" yazısı temanın neye
/// benzediğini söylemiyor. Kare temanın **kendisini** gösteriyor.
final class ThemeStrip: UIScrollView {
    var onPick: ((ThemeChoice) -> Void)?
    var selected: ThemeChoice = .system { didSet { refreshRings() } }
    var ringColor: UIColor = .systemBlue { didSet { refreshRings() } }

    private let row = UIStackView()
    private var tiles: [(ThemeChoice, UIButton)] = []
    private var nameLabels: [UILabel] = []
    var nameColor: UIColor = .label { didSet { for l in nameLabels { l.textColor = nameColor } } }
    private static let side: CGFloat = 48

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        disableEdgeEffects()
        clipsToBounds = false
        row.axis = .horizontal
        row.spacing = 4
        NSLayoutConstraint.activate(contentConstraints(row, insets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
            + [heightAnchor.constraint(equalToConstant: Self.side + 26)])
        for choice in ThemeChoice.allCases {
            let name = UILabel()
            name.text = choice.title
            name.font = .systemFont(ofSize: 11)
            name.textAlignment = .center
            name.isAccessibilityElement = false
            nameLabels.append(name)
            let col = UIStackView(arrangedSubviews: [tile(for: choice), name])
            col.axis = .vertical
            col.alignment = .center
            col.spacing = 4
            col.widthAnchor.constraint(equalToConstant: 64).isActive = true
            row.addArrangedSubview(col)
        }
        refreshRings()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tile(for choice: ThemeChoice) -> UIButton {
        let b = UIButton(type: .custom)
        b.accessibilityLabel = "Tema: \(choice.title)"
        b.layer.cornerRadius = 12
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: Self.side),
            b.heightAnchor.constraint(equalToConstant: Self.side),
        ])
        func preview(_ t: KeyboardTheme, in frame: CGRect) {
            let back = ThemeBackdropView(frame: frame)
            back.apply(t)
            b.addSubview(back)
            for (i, face) in [t.keyFace, t.keyFace, t.returnFace].enumerated() {
                let k = UIView(frame: CGRect(x: 7 + CGFloat(i) * 12, y: Self.side - 24,
                                             width: 10, height: 16))
                k.backgroundColor = face
                k.layer.cornerRadius = 3
                k.isUserInteractionEnabled = false
                b.addSubview(k)
            }
        }
        let full = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        if choice == .system {
            // Sistem: yarısı açık, yarısı koyu — "kipi izler" demenin kısa yolu.
            preview(.dark, in: full)
            let half = UIView(frame: CGRect(x: 0, y: 0, width: Self.side / 2, height: Self.side))
            half.clipsToBounds = true
            half.isUserInteractionEnabled = false
            let light = ThemeBackdropView(frame: full)
            light.apply(.light)
            half.addSubview(light)
            b.insertSubview(half, at: 1)
        } else {
            preview(choice.resolved(for: traitCollection), in: full)
        }
        for v in b.subviews { v.isUserInteractionEnabled = false }
        b.addAction(UIAction { [weak self] _ in
            self?.selected = choice
            self?.onPick?(choice)
        }, for: .touchUpInside)
        tiles.append((choice, b))
        return b
    }

    private func refreshRings() {
        for (choice, b) in tiles {
            let on = choice == selected
            b.layer.borderWidth = on ? 3 : 1
            b.layer.borderColor = (on ? ringColor : UIColor(white: 0.5, alpha: 0.35)).cgColor
            b.markSelected(on)
        }
    }
}
