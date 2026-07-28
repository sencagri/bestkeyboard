import UIKit
import KBGeometry

/// Tuş çizimi ve dokunma yakalama.
///
/// Skor sözleşmesi §11.B gereği:
/// - Tuş başına `UIView` **yok** — tek barındırıcı view + `CALayer` alt katmanları.
/// - Yazarken Auto Layout **yok** — çerçeveler yalnız boyut değişiminde hesaplanır.
/// - Görsel vurgu decoder'ı **asla beklemez**; iki yol arasında bağ yoktur.
///
/// Dokunma sözleşmesi:
/// - Vurgu `touchesBegan`'de (düşük gecikme), **eylem `touchesEnded`'de** kesinleşir.
///   Parmak tuştan kayarsa hedef güncellenir; klavyeden çıkarsa veya sistem iptal
///   ederse hiçbir karakter üretilmez.
/// - Çoklu dokunma parmak başına izlenir (rollover): ikinci parmak birincinin
///   durumunu ezmez.
final class KeyboardView: UIView {

    /// İşlev tuşları layout verisinde değil (harf değiller), burada tanımlı.
    enum FunctionKey: Hashable {
        case shift, backspace, numbers, globe, space, ret
    }

    enum KeyHit: Equatable {
        case letter(index: Int, point: Point)
        case function(FunctionKey)
    }

    /// Tuş kesinleştiğinde çağrılır (`touchesEnded`).
    var onKeyCommit: ((KeyHit) -> Void)?
    /// Globe uzun basma / sürükleme — sistem input-mode listesi için.
    var onGlobeLongPress: ((UIView, UIEvent?) -> Void)?
    /// `needsInputModeSwitchKey` false ise globe çizilmez.
    var showsGlobeKey: Bool = true { didSet { setNeedsLayout() } }

    private let layout: KeyLayout
    private var keyBackgrounds: [CALayer] = []
    private var keyLabels: [CATextLayer] = []
    private var letterFrames: [CGRect] = []
    private var functionBackgrounds: [FunctionKey: CALayer] = [:]
    private var functionLabels: [FunctionKey: CATextLayer] = [:]
    private var functionFrames: [(FunctionKey, CGRect)] = []

    /// Parmak → o parmağın şu anki hedefi. Rollover için parmak başına izlenir.
    private var activeTouches: [ObjectIdentifier: KeyHit] = [:]
    private var globeTouchStart: Date?

    private static let normalKeyColor = UIColor.white
    private static let functionKeyColor = UIColor(white: 0.68, alpha: 1)
    private static let pressedColor = UIColor(red: 0.62, green: 0.78, blue: 1.0, alpha: 1)

    init(layout: KeyLayout) {
        self.layout = layout
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.82, alpha: 1)
        isMultipleTouchEnabled = true
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayers() {
        // Arka plan ve metin AYRI katmanlar: basılı rengi arka planda değiştiririz,
        // metin üstte kalır. (Tek katmanda hem arka plan hem metin tutmak, vurgu
        // katmanının opak arka planların altında kalmasına yol açıyordu.)
        for key in layout.keys {
            let bg = CALayer()
            bg.backgroundColor = Self.normalKeyColor.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            keyBackgrounds.append(bg)

            let t = CATextLayer()
            t.string = String(key.char).uppercased(with: Locale(identifier: "tr"))
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            keyLabels.append(t)
        }

        for (fk, label) in [(FunctionKey.shift, "⇧"), (.backspace, "⌫"),
                            (.numbers, "123"), (.globe, "🌐"),
                            (.space, "boşluk"), (.ret, "⏎")] {
            let bg = CALayer()
            bg.backgroundColor = Self.functionKeyColor.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            functionBackgrounds[fk] = bg

            let t = CATextLayer()
            t.string = label
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            functionLabels[fk] = t
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let inset: CGFloat = 2

        letterFrames.removeAll(keepingCapacity: true)
        for (i, key) in layout.keys.enumerated() {
            let w = key.width * W, h = key.height * H
            let r = CGRect(x: key.center.x * W - w / 2,
                           y: key.center.y * H - h / 2,
                           width: w, height: h)
            letterFrames.append(r)
            keyBackgrounds[i].frame = r.insetBy(dx: inset, dy: inset)
            place(keyLabels[i], in: r, fontSize: min(r.height * 0.42, 22))
        }

        let rowH = H * TurkishQ.rowHeight
        let unit = W / 11.0
        var frames: [(FunctionKey, CGRect)] = [
            (.shift,     CGRect(x: 0, y: rowH * 2, width: unit, height: rowH)),
            (.backspace, CGRect(x: W - unit, y: rowH * 2, width: unit, height: rowH)),
            (.numbers,   CGRect(x: 0, y: rowH * 3, width: unit * 1.5, height: rowH)),
        ]
        if showsGlobeKey {
            frames.append((.globe, CGRect(x: unit * 1.5, y: rowH * 3, width: unit * 1.2, height: rowH)))
            frames.append((.space, CGRect(x: unit * 2.7, y: rowH * 3, width: W - unit * 4.4, height: rowH)))
        } else {
            frames.append((.space, CGRect(x: unit * 1.5, y: rowH * 3, width: W - unit * 3.2, height: rowH)))
        }
        frames.append((.ret, CGRect(x: W - unit * 1.7, y: rowH * 3, width: unit * 1.7, height: rowH)))
        functionFrames = frames

        for (fk, bg) in functionBackgrounds {
            guard let f = frames.first(where: { $0.0 == fk })?.1 else {
                bg.isHidden = true; functionLabels[fk]?.isHidden = true; continue
            }
            bg.isHidden = false; functionLabels[fk]?.isHidden = false
            bg.frame = f.insetBy(dx: inset, dy: inset)
            if let t = functionLabels[fk] { place(t, in: f, fontSize: min(f.height * 0.30, 15)) }
        }

        rebuildAccessibilityElements()
    }

    /// `CATextLayer` metni üstten hizalar; tek geçişte dikeyde ortalar.
    private func place(_ t: CATextLayer, in r: CGRect, fontSize: CGFloat) {
        t.fontSize = fontSize
        let lineHeight = fontSize * 1.2
        t.frame = CGRect(x: r.minX, y: r.midY - lineHeight / 2, width: r.width, height: lineHeight)
    }

    // MARK: - Erişilebilirlik
    //
    // Her tuş ayrı bir erişilebilirlik öğesi. İki işe yarar:
    // (1) VoiceOver (Faz 5 kabul kriteri), (2) UI testlerinin tuş geometrisini
    // **çoğaltmadan** dokunabilmesi — testte layout'u yeniden yazmak, layout
    // değişince sessizce yanlış yere dokunmaya yol açıyordu.

    private func rebuildAccessibilityElements() {
        var elements: [UIAccessibilityElement] = []
        for (i, key) in layout.keys.enumerated() {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "key.\(key.char)"
            e.accessibilityLabel = String(key.char)
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = letterFrames[i]
            elements.append(e)
        }
        for (fk, f) in functionFrames {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "key.\(fk)"
            e.accessibilityLabel = "\(fk)"
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = f
            elements.append(e)
        }
        accessibilityElements = elements
    }

    // MARK: - Dokunma

    private func hit(at p: CGPoint) -> KeyHit? {
        for (fk, f) in functionFrames where f.contains(p) { return .function(fk) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let norm = Point(x: Double((p.x - bounds.minX) / bounds.width),
                         y: Double((p.y - bounds.minY) / bounds.height))
        // Harf alanı yalnız ilk üç satır; son satır işlev tuşlarına ait.
        guard norm.y >= 0, norm.y < TurkishQ.rowHeight * 3, norm.x >= 0, norm.x <= 1 else { return nil }
        // Çerçeve testi değil **en yakın merkez**: tuşlar arası boşlukta da bir
        // aday üretilir; belirsizliği uzamsal model zaten çözer.
        guard let idx = layout.nearestKey(to: norm) else { return nil }
        return .letter(index: idx, point: norm)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let h = hit(at: t.location(in: self)) else { continue }
            activeTouches[ObjectIdentifier(t)] = h
            setPressed(h, true)
            if case .function(.globe) = h { globeTouchStart = Date() }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let old = activeTouches[id] else { continue }
            let new = hit(at: t.location(in: self))
            if new != old {
                setPressed(old, false)
                if let new { activeTouches[id] = new; setPressed(new, true) }
                else { activeTouches[id] = nil }   // klavye dışına sürüklendi
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let h = activeTouches.removeValue(forKey: id) else { continue }
            setPressed(h, false)
            // Globe uzun basma → sistem input-mode listesi.
            if case .function(.globe) = h, let start = globeTouchStart,
               Date().timeIntervalSince(start) > 0.5 {
                globeTouchStart = nil
                onGlobeLongPress?(self, event)
                continue
            }
            globeTouchStart = nil
            onKeyCommit?(h)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // İptal: vurgu kalkar, **hiçbir karakter üretilmez**.
        for t in touches {
            if let h = activeTouches.removeValue(forKey: ObjectIdentifier(t)) { setPressed(h, false) }
        }
        globeTouchStart = nil
    }

    private func setPressed(_ h: KeyHit, _ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // örtük CoreAnimation animasyonu istemiyoruz
        switch h {
        case let .letter(i, _):
            if i < keyBackgrounds.count {
                keyBackgrounds[i].backgroundColor = (pressed ? Self.pressedColor : Self.normalKeyColor).cgColor
            }
        case let .function(fk):
            functionBackgrounds[fk]?.backgroundColor =
                (pressed ? Self.pressedColor : Self.functionKeyColor).cgColor
        }
        CATransaction.commit()
    }
}
