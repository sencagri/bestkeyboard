import UIKit
import KBGeometry

/// Tuş çizimi ve dokunma yakalama.
///
/// Skor sözleşmesi §11.B gereği:
/// - Tuş başına `UIView` **yok** — tek barındırıcı view + `CALayer` alt katmanları.
/// - Yazarken Auto Layout **yok** — çerçeveler yalnız boyut değişiminde hesaplanır.
/// - Görsel vurgu decoder'ı **asla beklemez**; iki yol arasında bağ yoktur.
final class KeyboardView: UIView {

    /// İşlev tuşları layout verisinde değil (harf değiller), burada tanımlı.
    enum FunctionKey {
        case shift, backspace, numbers, globe, space, ret
    }

    enum KeyHit {
        case letter(index: Int, point: Point)
        case function(FunctionKey)
    }

    var onKeyDown: ((KeyHit) -> Void)?
    var onKeyUp: ((KeyHit) -> Void)?

    private let layout: KeyLayout
    private var letterLayers: [CATextLayer] = []
    private var letterFrames: [CGRect] = []
    private var functionLayers: [(FunctionKey, CATextLayer)] = []
    private var functionFrames: [(FunctionKey, CGRect)] = []
    private var activeHit: KeyHit?
    private var highlightLayer = CALayer()

    /// Harf satırlarının kapladığı alan — normalize koordinatın referansı.
    private var keyAreaFrame: CGRect = .zero

    init(layout: KeyLayout) {
        self.layout = layout
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.82, alpha: 1)
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayers() {
        highlightLayer.backgroundColor = UIColor.white.cgColor
        highlightLayer.cornerRadius = 5
        highlightLayer.opacity = 0
        layer.addSublayer(highlightLayer)

        for key in layout.keys {
            let t = CATextLayer()
            t.string = String(key.char)
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.backgroundColor = UIColor.white.cgColor
            t.cornerRadius = 5
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            letterLayers.append(t)
        }

        for (fk, label) in [(FunctionKey.shift, "⇧"), (.backspace, "⌫"),
                            (.numbers, "123"), (.globe, "🌐"),
                            (.space, "boşluk"), (.ret, "⏎")] {
            let t = CATextLayer()
            t.string = label
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.backgroundColor = UIColor(white: 0.68, alpha: 1).cgColor
            t.cornerRadius = 5
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            functionLayers.append((fk, t))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Çerçeveler yalnız burada hesaplanır; yazma sırasında tekrar edilmez.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        keyAreaFrame = bounds
        let W = bounds.width, H = bounds.height
        let inset: CGFloat = 2

        letterFrames.removeAll(keepingCapacity: true)
        for (i, key) in layout.keys.enumerated() {
            let w = key.width * W, h = key.height * H
            let r = CGRect(x: key.center.x * W - w / 2 + inset,
                           y: key.center.y * H - h / 2 + inset,
                           width: w - 2 * inset, height: h - 2 * inset)
            letterFrames.append(r)
            let t = letterLayers[i]
            t.frame = r
            t.fontSize = min(r.height * 0.45, 22)
            // Dikey ortalama: CATextLayer metni üstten hizalar.
            t.frame = r.offsetBy(dx: 0, dy: (r.height - t.fontSize * 1.2) / 2)
            t.frame.size.height = t.fontSize * 1.2
            t.backgroundColor = UIColor.white.cgColor
        }
        // Arka plan kutusu için ayrı katman yerine metin katmanının kendisini
        // kullanmak yerine tam boy dikdörtgeni geri koy.
        for (i, r) in letterFrames.enumerated() {
            let t = letterLayers[i]
            let fs = t.fontSize
            t.frame = r
            t.fontSize = fs
            // Metni dikeyde ortalamak için sublayer yerine padding taklidi:
            t.string = layout.keys[i].char.uppercased()
            t.alignmentMode = .center
            t.truncationMode = .none
        }

        // İşlev satırı (row 3) ve row 2 kenarları.
        let rowH = H * TurkishQ.rowHeight
        let unit = W / 11.0
        functionFrames = [
            (.shift,     CGRect(x: 0, y: rowH * 2, width: unit * 1.0, height: rowH)),
            (.backspace, CGRect(x: W - unit, y: rowH * 2, width: unit, height: rowH)),
            (.numbers,   CGRect(x: 0, y: rowH * 3, width: unit * 1.5, height: rowH)),
            (.globe,     CGRect(x: unit * 1.5, y: rowH * 3, width: unit * 1.2, height: rowH)),
            (.space,     CGRect(x: unit * 2.7, y: rowH * 3, width: W - unit * 4.4, height: rowH)),
            (.ret,       CGRect(x: W - unit * 1.7, y: rowH * 3, width: unit * 1.7, height: rowH)),
        ]
        for (fk, t) in functionLayers {
            guard let f = functionFrames.first(where: { $0.0 == fk })?.1 else { continue }
            t.frame = f.insetBy(dx: inset, dy: inset)
            t.fontSize = min(f.height * 0.32, 15)
        }
    }

    // MARK: - Dokunma

    private func hitTest(_ p: CGPoint) -> KeyHit? {
        for (fk, f) in functionFrames where f.contains(p) { return .function(fk) }
        // Harf alanı: en yakın merkezli tuş (çerçeve testi değil — kenarlarda
        // boşluk kalmasın; uzamsal model zaten belirsizliği çözüyor).
        guard keyAreaFrame.height > 0 else { return nil }
        let norm = Point(x: Double(p.x / keyAreaFrame.width),
                         y: Double(p.y / keyAreaFrame.height))
        // Yalnız harf satırlarında (row 0..2).
        guard norm.y < TurkishQ.rowHeight * 3 else { return nil }
        guard let idx = layout.nearestKey(to: norm) else { return nil }
        return .letter(index: idx, point: norm)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        guard let hit = hitTest(p) else { return }
        activeHit = hit
        // Görsel geri bildirim ANINDA — decoder beklenmez.
        showHighlight(for: hit)
        onKeyDown?(hit)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        hideHighlight()
        if let hit = activeHit { onKeyUp?(hit) }
        activeHit = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        hideHighlight()
        activeHit = nil
    }

    private func showHighlight(for hit: KeyHit) {
        let frame: CGRect?
        switch hit {
        case let .letter(i, _): frame = i < letterFrames.count ? letterFrames[i] : nil
        case let .function(fk): frame = functionFrames.first(where: { $0.0 == fk })?.1
        }
        guard let f = frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // örtük animasyon istemiyoruz
        highlightLayer.frame = f.insetBy(dx: 1, dy: 1)
        highlightLayer.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1, alpha: 1).cgColor
        highlightLayer.opacity = 0.55
        CATransaction.commit()
    }

    private func hideHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.opacity = 0
        CATransaction.commit()
    }
}
