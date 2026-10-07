import UIKit

/// Üç yuvalı öneri çubuğu + geliştirme HUD'u (§11.E debug HUD).
///
/// ## Neden `CATextLayer`, `UILabel`/`UIButton` değil
///
/// Bu yüzey **her tuş vuruşunda** güncelleniyor (`refreshUI`). İlk sürüm her
/// vuruşta üç `UIButton` yıkıp yeniden yaratıyordu; ikinci sürüm yalnız
/// `setTitle`/`isHidden` yazıyordu. İkisi de §11.B'yi deliyor: `setTitle`
/// intrinsic content size'ı, `isHidden` `UIStackView` yerleşimini
/// geçersizleştiriyor — yani yazma yolunda Auto Layout tetikleniyor.
///
/// Tuş yüzeyi bu disiplini baştan beri tutuyordu; çubuk tutmuyordu. Artık
/// aynı çözüm: çerçeveler yalnız boyut değişiminde hesaplanıyor, vuruş başına
/// değişen tek şey `CATextLayer.string`.
///
/// Ayar düğmesi `UIButton` olarak kalıyor: yazarken hiç değişmiyor.
final class SuggestionBar: UIView {
    var onPick: ((String) -> Void)?
    var onSettings: (() -> Void)?
    /// Pano geçmişi paneli.
    var onClipboard: (() -> Void)?
    /// Son kopyalanana dokunuldu.
    var onClipChip: (() -> Void)?
    /// Emoji yüzeyi.
    ///
    /// Giriş **çubukta**, tuş ızgarasında değil: ızgaraya bir yuva eklemek
    /// bütün harf merkezlerini kaydırır, `layoutID` değişir ve öğrenilmiş
    /// kalibrasyon başka bir kovaya düşerdi (⚙︎ ve kayıt düğmesiyle aynı
    /// gerekçe).
    var onEmoji: (() -> Void)?
    /// Klavyeyi kapat.
    ///
    /// Uzantının kendi kapatma yolu yok: sistem klavyesinde bu iş `⌄` tuşunun
    /// ya da alanın dışına dokunmanın; bazı host'larda ikisi de yok ve klavye
    /// ekranın yarısını kaplayıp duruyor.
    ///
    /// Yeri **çubuk**, ızgara değil — emoji, ⚙︎ ve kayıt düğmesiyle aynı
    /// gerekçe: ızgaraya yuva eklemek bütün harf merkezlerini kaydırırdı.
    /// Nokta tuşunda bu bedel bilerek ödendi (kullanıcı yazarken sürekli
    /// lazım); kapatma tuşu o eşiği geçmiyor.
    var onDismiss: (() -> Void)?

    private static let slotCount = 3
    private static let rowHeight: CGFloat = 32
    static let toolRowHeight: CGFloat = 40
    static let height: CGFloat = toolRowHeight + 44
    private static let gearWidth: CGFloat = 34
    /// Kayıt düğmesi de aynı genişlikte.
    ///
    /// **Harf geometrisine dokunmuyor**: tuş satırlarına bir düğme eklemek
    /// bütün merkezleri kaydırır, `layoutID` değişir ve öğrenilmiş kalibrasyon
    /// başka bir kovaya düşerdi.
    private static let captureWidth: CGFloat = 34
    /// Emoji düğmesi — aynı gerekçe, aynı genişlik.
    private static let emojiWidth: CGFloat = 34
    /// Kapatma düğmesi — aynı gerekçe, aynı genişlik.
    private static let dismissWidth: CGFloat = 34

    private var slots: [CATextLayer] = []
    private var slotWords: [String] = Array(repeating: "", count: slotCount)
    private var slotFrames: [CGRect] = []
    private let status = CATextLayer()
    private let settingsButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let clipChip = UIButton(type: .custom)
    private static let clipChipWidth: CGFloat = 96
    private var theme: KeyboardTheme = .light

    /// Son kopyalanan şeyi önerilerin solunda gösterir; `nil` gizler.
    func showClip(image: UIImage?, text: String?) {
        guard image != nil || text != nil else {
            if !clipChip.isHidden { clipChip.isHidden = true; setNeedsLayout() }
            return
        }
        var c = clipChip.configuration ?? .filled()
        if let image {
            let side: CGFloat = 26
            c.image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                             cornerRadius: 5).addClip()
                let k = max(side / image.size.width, side / image.size.height)
                let sz = CGSize(width: image.size.width * k, height: image.size.height * k)
                image.draw(in: CGRect(x: (side - sz.width) / 2, y: (side - sz.height) / 2,
                                      width: sz.width, height: sz.height))
            }
            c.title = "Resim"
            clipChip.accessibilityLabel = "Panodaki resim"
        } else {
            c.image = UIImage(systemName: "doc.on.clipboard")
            c.title = text
            clipChip.accessibilityLabel = "Panodaki metin: \(text ?? "")"
        }
        c.titleLineBreakMode = .byTruncatingTail
        c.baseBackgroundColor = theme.functionFace
        c.baseForegroundColor = theme.functionText
        c.attributedTitle = AttributedString(c.title ?? "",
                                             attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]))
        clipChip.configuration = c
        if clipChip.isHidden { clipChip.isHidden = false }
        setNeedsLayout()
        invalidateAccessibilityElements()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        for _ in 0..<Self.slotCount {
            let t = CATextLayer()
            t.alignmentMode = .center
            t.contentsScale = UIScreen.main.scale
            t.fontSize = 16
            t.truncationMode = .end
            layer.addSublayer(t)
            slots.append(t)
        }

        status.alignmentMode = .center
        status.contentsScale = UIScreen.main.scale
        status.fontSize = 9
        // `CATextLayer.font` `UIFont` kabul etmiyor. İsimle (`CTFontCreateWithName`)
        // aramak sistem fontlarında çalışmıyor — adları `.SFUI-Regular` gibi
        // private ve arama Helvetica'ya düşüyor. Descriptor `CTFontDescriptor`
        // ile toll-free köprülü, doğru yol bu.
        status.font = CTFontCreateWithFontDescriptor(
            UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular).fontDescriptor
                as CTFontDescriptor, 9, nil)
        status.isWrapped = true
        layer.addSublayer(status)
        layer.addSublayer(toolDivider)
        shortcutBackground.cornerRadius = 9
        shortcutBackground.isHidden = true
        layer.insertSublayer(shortcutBackground, at: 0)
        shortcutImageLayer.contentsGravity = .resizeAspect
        shortcutImageLayer.contentsScale = UIScreen.main.scale
        shortcutImageLayer.cornerRadius = 6
        shortcutImageLayer.masksToBounds = true
        shortcutImageLayer.isHidden = true
        layer.addSublayer(shortcutImageLayer)
        status.isHidden = true   // `showsStatus` varsayılanı

        // Bu yuvada kayıt düğmesi (⏺) duruyordu; kayıt bir geliştirici aracı
        // ve ⚙︎ paneline taşındı, yuva pano geçmişinin.
        captureButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        captureButton.accessibilityIdentifier = "key.clipboard"
        captureButton.accessibilityLabel = "Pano geçmişi"
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addAction(UIAction { [weak self] _ in self?.onClipboard?() },
                                for: .touchUpInside)
        addSubview(captureButton)

        // Son kopyalanan: küçük önizleme + kısa yazı, önerilerin solunda.
        var conf = UIButton.Configuration.filled()
        conf.cornerStyle = .medium
        conf.imagePadding = 6
        conf.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 8)
        clipChip.configuration = conf
        clipChip.isHidden = true
        clipChip.addAction(UIAction { [weak self] _ in self?.onClipChip?() }, for: .touchUpInside)
        addSubview(clipChip)

        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.accessibilityIdentifier = "key.settings"
        settingsButton.accessibilityLabel = "Klavye ayarları"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.addAction(UIAction { [weak self] _ in self?.onSettings?() },
                                 for: .touchUpInside)
        addSubview(settingsButton)

        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.accessibilityIdentifier = "key.emoji"
        emojiButton.accessibilityLabel = "Emoji"
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        emojiButton.addAction(UIAction { [weak self] _ in self?.onEmoji?() },
                              for: .touchUpInside)
        addSubview(emojiButton)

        // `chevron.down` sistem klavyesinin kapatma simgesiyle aynı: kullanıcı
        // bu şekli zaten "klavyeyi indir" diye biliyor ve öğrenilecek yeni bir
        // şey yok.
        dismissButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        dismissButton.accessibilityIdentifier = "key.dismiss"
        dismissButton.accessibilityLabel = "Klavyeyi kapat"
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() },
                                for: .touchUpInside)
        addSubview(dismissButton)

        // Çubukta **yalnız** emoji ve ⚙︎ düğmeleri sabit (sağda) ve
        // uygulama kısayolları (solda); pano emoji panelinin içinde, ⌄
        // kapatma ⚙︎ panelinde. Tasarım tuvali "11 · Öneri çubuğu".
        // ⌄ araç satırında (kullanıcı geri istedi); bazı uygulamalarda
        // klavyeyi indirmenin başka yolu yok.
        dismissButton.translatesAutoresizingMaskIntoConstraints = true
        captureButton.isHidden = true
        micButton.setImage(UIImage(systemName: "mic"), for: .normal)
        micButton.accessibilityLabel = "Sesle yaz"
        micButton.addAction(UIAction { [weak self] _ in self?.onMic?() }, for: .touchUpInside)
        addSubview(micButton)
        // ✦ yapay zeka tuşları — araç satırının en solunda (tasarım 22).
        aiButton.setImage(UIImage(systemName: "sparkles",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        aiButton.layer.cornerRadius = 9
        aiButton.accessibilityLabel = "Yapay zeka tuşları"
        aiButton.addAction(UIAction { [weak self] _ in self?.onAI?() }, for: .touchUpInside)
        addSubview(aiButton)
        // "Aa" fontlu yazı (tasarım 24).
        fontButton.setTitle("Aa", for: .normal)
        fontButton.titleLabel?.font = UIFont(descriptor: UIFont.systemFont(ofSize: 16, weight: .bold)
            .fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: 16).fontDescriptor, size: 16)
        fontButton.layer.cornerRadius = 9
        fontButton.accessibilityLabel = "Fontlu yazı"
        fontButton.addAction(UIAction { [weak self] _ in self?.onFonts?() }, for: .touchUpInside)
        addSubview(fontButton)
        styleStrip.showsHorizontalScrollIndicator = false
        styleStrip.isHidden = true
        styleRow.axis = .horizontal
        styleRow.spacing = 6
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        styleStrip.addSubview(styleRow)
        NSLayoutConstraint.activate([
            styleRow.leadingAnchor.constraint(equalTo: styleStrip.contentLayoutGuide.leadingAnchor, constant: 6),
            styleRow.trailingAnchor.constraint(equalTo: styleStrip.contentLayoutGuide.trailingAnchor, constant: -6),
            styleRow.centerYAnchor.constraint(equalTo: styleStrip.frameLayoutGuide.centerYAnchor),
            styleRow.heightAnchor.constraint(equalToConstant: 36),
        ])
        addSubview(styleStrip)
        for b in [emojiButton, settingsButton] { b.translatesAutoresizingMaskIntoConstraints = true }
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Uygulama kısayolları

    /// Uygulama düğmesine basıldı — kimlik `AIApp.id`.
    var onApp: ((String) -> Void)?
    /// 🎤 sesle yazma — uygulamanın dikte ekranını açıyor.
    var onMic: (() -> Void)?
    private let micButton = UIButton(type: .system)
    /// ✦ — yapay zeka kartı.
    var onAI: (() -> Void)?
    private let aiButton = UIButton(type: .system)
    /// "Aa" — fontlu yazı; stil şeridi öneri satırının yerine geçiyor.
    var onFonts: (() -> Void)?
    var onStylePick: ((Int) -> Void)?
    private let fontButton = UIButton(type: .system)
    private let styleStrip = UIScrollView()
    private let styleRow = UIStackView()
    private var styleButtons: [UIButton] = []
    var fontsActive = false { didSet { styleAIButton() } }

    /// Stil çiplerini gösterir (`nil` = gizle). Her çip kendi stilinde yazılı.
    func showStyles(_ samples: [String]?, selected: Int) {
        guard let samples else {
            styleStrip.isHidden = true
            slots.forEach { $0.isHidden = false }
            return
        }
        if styleButtons.count != samples.count {
            styleButtons.forEach { $0.removeFromSuperview() }
            styleButtons = samples.enumerated().map { i, _ in
                let b = UIButton(configuration: .filled(), primaryAction: UIAction { [weak self] _ in self?.onStylePick?(i) })
                styleRow.addArrangedSubview(b)
                return b
            }
        }
        for (i, b) in styleButtons.enumerated() {
            var c = UIButton.Configuration.filled()
            c.title = samples[i]
            c.cornerStyle = .medium
            c.baseBackgroundColor = i == selected ? theme.returnFace : theme.keyFace
            c.baseForegroundColor = i == selected ? theme.returnText : theme.keyText
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            c.titleTextAttributesTransformer = .init { a in var a = a; a.font = .systemFont(ofSize: 16); return a }
            b.configuration = c
            b.accessibilityTraits = i == selected ? [.button, .selected] : .button
        }
        styleStrip.isHidden = false
        slots.forEach { $0.isHidden = true }
        shortcutImageLayer.isHidden = true
        setNeedsLayout()
    }
    /// Kart açıkken ✦ dolu görünür.
    var aiActive = false { didSet { styleAIButton() } }
    /// `/komut` eşleşmesinde ilk yuva vurgulu (tasarım 23).
    var highlightsFirst = false {
        didSet { if highlightsFirst != oldValue { setNeedsLayout() } }
    }
    private func styleAIButton() {
        aiButton.backgroundColor = aiActive ? theme.accent : .clear
        aiButton.tintColor = aiActive ? .white : theme.accent
        fontButton.backgroundColor = fontsActive ? theme.accent : .clear
        fontButton.setTitleColor(fontsActive ? .white : theme.accent, for: .normal)
    }
    private var appButtons: [(id: String, button: UIButton)] = []
    private static let appSide: CGFloat = 30
    private let toolDivider = CALayer()

    func setApps(_ ids: [String]) {
        guard ids != appButtons.map(\.id) else { return }
        for (_, b) in appButtons { b.removeFromSuperview() }
        appButtons = ids.compactMap { id in
            guard let app = AIApp.byID[id] else { return nil }
            let b = UIButton(type: .custom)
            b.setImage(Bundle(for: SuggestionBar.self).path(forResource: app.icon, ofType: "png")
                        .flatMap(UIImage.init(contentsOfFile:)), for: .normal)
            b.imageView?.contentMode = .scaleAspectFill
            b.layer.cornerRadius = 8
            b.layer.cornerCurve = .continuous
            b.clipsToBounds = true
            b.accessibilityLabel = "\(app.name) aç"
            b.addAction(UIAction { [weak self] _ in self?.onApp?(id) }, for: .touchUpInside)
            addSubview(b)
            return (id, b)
        }
        setNeedsLayout()
        invalidateAccessibilityElements()
    }

    // MARK: Kısayol önerisi

    /// Kısayol önerisine dokunuldu.
    var onShortcut: (() -> Void)?
    /// Eşleşen kısayol çıktısı — ilk yuvada, vurgulu.
    private var shortcutOutput: String?
    private let shortcutBackground = CALayer()

    /// Çıkartma/GIF kısayolu: ilk yuvada küçük resim (yazı gizli, ama
    /// erişilebilirlik etiketi olarak duruyor).
    private var shortcutImage: UIImage?
    private let shortcutImageLayer = CALayer()

    func setShortcut(_ output: String?, image: UIImage? = nil) {
        guard output != shortcutOutput || image !== shortcutImage else { return }
        shortcutOutput = output
        shortcutImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shortcutImageLayer.contents = image?.cgImage
        shortcutImageLayer.isHidden = image == nil
        slots.first?.opacity = image == nil ? 1 : 0
        CATransaction.commit()
        setCandidates(lastWords)
        setNeedsLayout()
    }

    /// Tanı satırı (`KeyboardSettings.showsDiagnostics`).
    var showsStatus = false {
        didSet {
            guard showsStatus != oldValue else { return }
            status.isHidden = !showsStatus
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        let tool = Self.toolRowHeight
        let rowTop = tool + (showsStatus ? 0 : (44 - Self.rowHeight) / 2)
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }

        // Araç satırı: uygulamalar · son kopyalanan … emoji ⚙︎.
        // Sağdakiler sabit; sol taraf kalan yere sığdırılıyor. Eskiden sol
        // taraf sığıp sığmadığına bakmadan diziliyordu ve ✦ + Aa + üç
        // uygulama + pano çipi ⌄ ile 🎤'nin üstüne biniyordu.
        let right = W - 4 - Self.gearWidth - Self.emojiWidth
        settingsButton.frame = CGRect(x: W - 4 - Self.gearWidth, y: (tool - Self.rowHeight) / 2,
                                      width: Self.gearWidth, height: Self.rowHeight)
        emojiButton.frame = CGRect(x: right, y: (tool - Self.rowHeight) / 2,
                                   width: Self.emojiWidth, height: Self.rowHeight)
        micButton.frame = CGRect(x: right - Self.emojiWidth, y: (tool - Self.rowHeight) / 2,
                                 width: Self.emojiWidth, height: Self.rowHeight)
        dismissButton.frame = CGRect(x: right - Self.emojiWidth * 2, y: (tool - Self.rowHeight) / 2,
                                     width: Self.emojiWidth, height: Self.rowHeight)
        let limit = dismissButton.frame.minX - 4

        aiButton.frame = CGRect(x: 6, y: (tool - 32) / 2, width: 40, height: 32)
        fontButton.frame = CGRect(x: 48, y: (tool - 32) / 2, width: 40, height: 32)
        let start: CGFloat = 94
        let side = Self.appSide, step = side + 6
        // Pano çipi en az bu kadar yer istiyor; sığmazsa önce uygulama
        // ikonları azalıyor (çip yeni kopyalanan için, geçici ve öncelikli).
        let chipMin: CGFloat = 64
        var shownApps = appButtons.count
        func room(_ n: Int) -> CGFloat { limit - (start + CGFloat(n) * step) }
        if !clipChip.isHidden {
            while shownApps > 0, room(shownApps) < chipMin { shownApps -= 1 }
        } else {
            while shownApps > 0, room(shownApps) < 0 { shownApps -= 1 }
        }
        var x = start
        for (i, (_, b)) in appButtons.enumerated() {
            b.isHidden = i >= shownApps
            guard i < shownApps else { continue }
            b.frame = CGRect(x: x, y: (tool - side) / 2, width: side, height: side)
            x += step
        }
        if !clipChip.isHidden {
            let w = min(Self.clipChipWidth, limit - x)
            clipChip.alpha = w >= 44 ? 1 : 0
            clipChip.frame = CGRect(x: x, y: (tool - Self.rowHeight) / 2,
                                    width: max(0, w), height: Self.rowHeight)
        }
        toolDivider.frame = CGRect(x: 0, y: tool - 0.5, width: W, height: 0.5)
        // Öneri satırı: tam genişlik.
        let slotW = (W - 8) / CGFloat(Self.slotCount)
        slotFrames = (0..<Self.slotCount).map {
            CGRect(x: 4 + CGFloat($0) * slotW, y: rowTop, width: slotW, height: Self.rowHeight)
        }
        shortcutBackground.frame = slotFrames[0].insetBy(dx: 3, dy: 1)
        shortcutBackground.isHidden = shortcutOutput == nil && !highlightsFirst
        shortcutImageLayer.frame = slotFrames[0].insetBy(dx: 10, dy: 4)
        for (i, t) in slots.enumerated() {
            let f = slotFrames[i]
            // `CATextLayer` metni üstten hizalar; dikeyde tek geçişte ortalanıyor.
            // Katman yalnız kendi sınırları içine çiziyor: emoji yazı tipi
            // sistem fontundan uzun, 1,2 satırlık kutuda emojinin altı
            // kesiliyordu. Üst kenar yerinde (metin kaymasın), kutu aşağı uzuyor.
            let line = t.fontSize * 1.2
            t.frame = CGRect(x: f.minX, y: f.midY - line / 2, width: f.width, height: t.fontSize * 1.7)
        }
        styleStrip.frame = CGRect(x: 0, y: tool, width: W, height: max(0, (showsStatus ? rowTop + Self.rowHeight : H) - tool))
        status.frame = CGRect(x: 0, y: rowTop + Self.rowHeight,
                              width: W, height: max(0, H - rowTop - Self.rowHeight))
        invalidateAccessibilityElements()
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.barFace
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for t in slots { t.foregroundColor = theme.barText.cgColor }
        status.foregroundColor = theme.barSecondaryText.cgColor
        shortcutBackground.backgroundColor = theme.returnFace.withAlphaComponent(0.28).cgColor
        toolDivider.backgroundColor = theme.barSecondaryText.withAlphaComponent(0.25).cgColor
        CATransaction.commit()
        settingsButton.tintColor = theme.barSecondaryText
        captureButton.tintColor = theme.barSecondaryText
        emojiButton.tintColor = theme.barSecondaryText
        dismissButton.tintColor = theme.barSecondaryText
        micButton.tintColor = theme.barSecondaryText
        styleAIButton()
    }

    private var lastWords: [String] = []

    func setCandidates(_ incoming: [String]) {
        lastWords = incoming
        let words = shortcutOutput.map { [$0] + incoming.filter { $0 != shortcutOutput } } ?? incoming
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var changed = false
        for i in 0..<Self.slotCount {
            let w = i < words.count ? words[i] : ""
            guard slotWords[i] != w else { continue }
            slotWords[i] = w
            slots[i].string = w
            changed = true
        }
        if changed { invalidateAccessibilityElements() }
    }

    func setStatus(_ s: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        status.string = s
        CATransaction.commit()
    }

    // MARK: - Dokunma
    //
    // Tuş yüzeyiyle aynı sözleşme: eylem `touchesEnded`'de kesinleşir, parmak
    // yuvadan çıkarsa hiçbir şey seçilmez.

    private var pressedSlot: Int?

    private func slot(at p: CGPoint) -> Int? {
        guard let i = slotFrames.firstIndex(where: { $0.contains(p) }),
              !slotWords[i].isEmpty else { return nil }
        return i
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        pressedSlot = slot(at: t.location(in: self))
        setPressed(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let cur = pressedSlot else { return }
        if slot(at: t.location(in: self)) != cur { setPressed(false); pressedSlot = nil }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressedSlot = nil }
        setPressed(false)
        guard let t = touches.first, let i = pressedSlot,
              slot(at: t.location(in: self)) == i else { return }
        if i == 0, shortcutOutput != nil { onShortcut?(); return }
        onPick?(slotWords[i])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(false)
        pressedSlot = nil
    }

    private func setPressed(_ on: Bool) {
        guard let i = pressedSlot, i < slots.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots[i].foregroundColor = (on ? theme.barSecondaryText : theme.barText).cgColor
        CATransaction.commit()
    }

    // MARK: - Erişilebilirlik
    //
    // `UIButton` bunu bedava veriyordu; katmana geçince elle kuruluyor —
    // tuş yüzeyiyle aynı yaklaşım, **tembel kurulum dahil**.
    //
    // Liste eskiden `setCandidates`'ta istekli kuruluyordu, yani aday her
    // değiştiğinde — pratikte her tuş vuruşunda. Tuş yüzeyindeki ~45 nesneye
    // göre buradaki 3 nesne küçük, ama iki kardeş uygulamanın farklı davranması
    // kendi başına bir kusur: biri düzeltilirken diğeri unutulur.

    private var cachedAccessibilityElements: [Any]?

    override var accessibilityElements: [Any]? {
        get {
            if cachedAccessibilityElements == nil {
                cachedAccessibilityElements = buildAccessibilityElements()
            }
            return cachedAccessibilityElements
        }
        set { cachedAccessibilityElements = newValue }
    }

    /// Liste bayatladı — bir sonraki soruda yeniden kurulacak. O(1).
    private func invalidateAccessibilityElements() {
        cachedAccessibilityElements = nil
    }

    private func buildAccessibilityElements() -> [Any] {
        var elements: [Any] = []
        for (i, w) in slotWords.enumerated() where !w.isEmpty && i < slotFrames.count {
            let e = ActivatableAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "suggestion.\(i)"
            e.accessibilityLabel = w
            e.accessibilityTraits = .button
            e.accessibilityFrameInContainerSpace = slotFrames[i]
            let isShortcut = i == 0 && shortcutOutput != nil
            e.onActivate = { [weak self] in
                if isShortcut { self?.onShortcut?() } else { self?.onPick?(w) }
                return true
            }
            elements.append(e)
        }
        // Düğmeler de listede: özel `accessibilityElements` dizisi yalnız
        // sayılanları görünür kılıyor ve eklenmeyen düğmeye VoiceOver'la
        // ulaşılamıyor. Emoji düğmesi eklendiğinde bu satır güncellenmemişti;
        // düğme ekranda duruyor ama ekran okuyucu için **yoktu**. Hatanın
        // sessiz olmasının sebebi bu: eksiklik yalnız VoiceOver açıkken
        // görünüyor ve hiçbir test o kipte koşmuyor.
        if !clipChip.isHidden { elements.insert(clipChip, at: 0) }
        elements.insert(contentsOf: appButtons.map(\.button), at: 0)
        elements.insert(fontButton, at: 0)
        elements.insert(aiButton, at: 0)
        elements.append(dismissButton)
        elements.append(micButton)
        elements.append(emojiButton)
        elements.append(settingsButton)
        return elements
    }
}
