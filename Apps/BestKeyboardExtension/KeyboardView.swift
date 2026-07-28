import UIKit
import KBGeometry
import KBRuntime

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
        case shift, backspace, numbers, symbols, letters, globe, space, ret
    }

    enum KeyHit: Equatable {
        /// Harf düzlemi — **kod çözmeye girer**, uzamsal kanıt taşır.
        case letter(index: Int, point: Point)
        /// Rakam/sembol — doğrudan yazılır, model yok.
        case symbol(Character)
        case function(FunctionKey)
    }

    /// Hangi tuş düzlemi çiziliyor.
    enum Plane: Equatable {
        case letters
        case numbers
        case symbols
    }

    /// Basılı tutma kademesi.
    ///
    /// Görünüm yalnız **ne zaman** tetikleneceğini bilir; "karakter" ve "kelime"
    /// silmenin ne demek olduğunu bilmez — anlamı controller verir.
    typealias RepeatStage = KeyRepeatCadence.Stage

    /// Tuş kesinleştiğinde çağrılır (`touchesEnded`).
    ///
    /// Tekrar başlamışsa bırakıldığında **çağrılmaz** — yoksa uzun basma son bir
    /// fazladan silme yapardı.
    var onKeyCommit: ((KeyHit) -> Void)?

    /// Basılı tutma tekrarı.
    var onKeyRepeat: ((KeyHit, RepeatStage) -> Void)?
    /// Globe uzun basma / sürükleme — sistem input-mode listesi için.
    var onGlobeLongPress: ((UIView, UIEvent?) -> Void)?
    /// `needsInputModeSwitchKey` false ise globe çizilmez.
    var showsGlobeKey: Bool = true { didSet { setNeedsLayout() } }

    /// Aktif düzlem. Değişince katmanlar yeniden kurulur.
    var plane: Plane = .letters {
        didSet { guard plane != oldValue else { return }; rebuildForPlane() }
    }

    /// Harf düzleminde büyük harf gösterilsin mi.
    var isUppercase = false {
        didSet { guard isUppercase != oldValue else { return }; refreshLetterLabels() }
    }

    /// Shift kilitli mi — görsel olarak ayırt edilmeli, yoksa kullanıcı
    /// kilidin açık olduğunu fark etmez.
    var isShiftLocked = false { didSet { setNeedsLayout() } }

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

    // MARK: Basılı tutma tekrarı
    //
    // Zamanlama politikası `KBRuntime.KeyRepeatCadence`'ta; burada yalnız
    // zamanlayıcı ve dokunma sahipliği var.
    private let cadence = KeyRepeatCadence()
    private var repeatTouch: ObjectIdentifier?
    private var repeatKey: KeyHit?
    private var repeatTimer: Timer?
    private var repeatTicks = 0
    /// Tekrar üretmiş parmaklar. Tek bir `repeatTouch` alanı yetmiyordu: ikinci
    /// bir parmak sahipliği devraldığında birincinin "tekrar etti" bilgisi
    /// kayboluyor, bırakıldığında fazladan bir silme commit ediliyordu.
    private var repeatedTouches: Set<ObjectIdentifier> = []

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

    // MARK: - Katmanlar
    //
    // Düzlem değişince katmanlar **yeniden kurulur**. Üç düzlemin katmanlarını
    // birden tutup gizlemek daha hızlı görünür ama tuş sayıları farklı (harf 32,
    // rakam 25) ve gizli katmanlar da backing store tutar (§11.D). Düzlem
    // değişimi kullanıcı eylemi, sıcak yolda değil.

    /// Aktif düzlemin sembol tuşları — harf düzleminde boş.
    private var planeKeys: [SymbolPlanes.PlaneKey] = []

    private func buildLayers() {
        for l in keyBackgrounds + keyLabels { l.removeFromSuperlayer() }
        keyBackgrounds.removeAll(); keyLabels.removeAll()

        // Arka plan ve metin AYRI katmanlar: basılı rengi arka planda
        // değiştiririz, metin üstte kalır. (Tek katmanda tutmak, vurgu
        // katmanının opak arka planların altında kalmasına yol açıyordu.)
        func addKey(_ title: String) {
            let bg = CALayer()
            bg.backgroundColor = Self.normalKeyColor.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            keyBackgrounds.append(bg)

            let t = CATextLayer()
            t.string = title
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            keyLabels.append(t)
        }

        switch plane {
        case .letters:
            planeKeys = []
            for key in layout.keys { addKey(letterTitle(key.char)) }
        case .numbers, .symbols:
            planeKeys = (plane == .numbers ? SymbolPlanes.numbers : SymbolPlanes.symbols).keys
            for k in planeKeys { addKey(String(k.char)) }
        }

        if functionBackgrounds.isEmpty { buildFunctionLayers() }
        refreshFunctionTitles()
        setNeedsLayout()
    }

    private func buildFunctionLayers() {
        for fk in [FunctionKey.shift, .backspace, .numbers, .symbols, .letters,
                   .globe, .space, .ret] {
            let bg = CALayer()
            bg.backgroundColor = Self.functionKeyColor.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            functionBackgrounds[fk] = bg

            let t = CATextLayer()
            t.alignmentMode = .center
            t.foregroundColor = UIColor.black.cgColor
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            functionLabels[fk] = t
        }
    }

    private func refreshFunctionTitles() {
        // Kilitli shift ayrı bir simge: kullanıcı kilidin açık olduğunu
        // görmezse neden hep büyük harf yazdığını anlamaz.
        functionLabels[.shift]?.string = isShiftLocked ? "⇪" : "⇧"
        functionLabels[.backspace]?.string = "⌫"
        functionLabels[.numbers]?.string = "123"
        functionLabels[.symbols]?.string = "#+="
        functionLabels[.letters]?.string = "ABC"
        functionLabels[.globe]?.string = "🌐"
        functionLabels[.space]?.string = "boşluk"
        functionLabels[.ret]?.string = "⏎"
    }

    /// Türkçe büyük harf: `i → İ`, `ı → I`. Locale'siz `uppercased()` ikisini
    /// birbirine karıştırır.
    private func letterTitle(_ ch: Character) -> String {
        isUppercase ? String(ch).uppercased(with: Locale(identifier: "tr"))
                    : String(ch)
    }

    private func rebuildForPlane() {
        // Düzlem değişince bekleyen dokunmalar **iptal edilir**.
        //
        // Çoklu dokunmada bir parmak basılıyken ikincisi `123`/`ABC` yaparsa,
        // birincinin eski `KeyHit`'i yeni düzlemde commit edilirdi — `setPressed`
        // de eski karakteri yeni `planeKeys` içinde arardı.
        for (_, h) in activeTouches { setPressed(h, false) }
        activeTouches.removeAll()
        repeatedTouches.removeAll()
        cancelRepeat()
        buildLayers()
    }

    private func refreshLetterLabels() {
        guard plane == .letters else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, key) in layout.keys.enumerated() where i < keyLabels.count {
            keyLabels[i].string = letterTitle(key.char)
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let inset: CGFloat = 2

        refreshFunctionTitles()
        letterFrames.removeAll(keepingCapacity: true)

        func layoutKey(index: Int, center: Point, w: Double, h: Double) {
            let kw = w * W, kh = h * H
            let r = CGRect(x: center.x * W - kw / 2, y: center.y * H - kh / 2,
                           width: kw, height: kh)
            letterFrames.append(r)
            guard index < keyBackgrounds.count else { return }
            keyBackgrounds[index].frame = r.insetBy(dx: inset, dy: inset)
            place(keyLabels[index], in: r, fontSize: min(r.height * 0.42, 22))
        }

        switch plane {
        case .letters:
            for (i, k) in layout.keys.enumerated() {
                layoutKey(index: i, center: k.center, w: k.width, h: k.height)
            }
        case .numbers, .symbols:
            for (i, k) in planeKeys.enumerated() {
                layoutKey(index: i, center: k.center, w: k.width, h: k.height)
            }
        }

        let rowH = H * TurkishQ.rowHeight
        let unit = W / 11.0
        // 3. satırın kenarları düzleme göre değişir: harfte shift, sembolde
        // diğer sembol düzlemine geçiş.
        let leftKey: FunctionKey = plane == .letters ? .shift
                                 : (plane == .numbers ? .symbols : .numbers)
        var frames: [(FunctionKey, CGRect)] = [
            (leftKey,    CGRect(x: 0, y: rowH * 2, width: unit * 1.5, height: rowH)),
            (.backspace, CGRect(x: W - unit * 1.5, y: rowH * 2, width: unit * 1.5, height: rowH)),
        ]
        // 4. satır: düzlem değiştirme tuşu harf düzleminde "123", diğerlerinde "ABC".
        let planeSwitch: FunctionKey = plane == .letters ? .numbers : .letters
        frames.append((planeSwitch, CGRect(x: 0, y: rowH * 3, width: unit * 1.5, height: rowH)))
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
            // Kilitli shift vurgulu çizilir.
            let locked = (fk == .shift && isShiftLocked)
            bg.backgroundColor = (locked ? Self.pressedColor : Self.functionKeyColor).cgColor
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

    private func rebuildAccessibilityElements() {
        var elements: [UIAccessibilityElement] = []
        let titles: [String] = plane == .letters
            ? layout.keys.map { String($0.char) }
            : planeKeys.map { String($0.char) }
        for (i, title) in titles.enumerated() where i < letterFrames.count {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "key.\(title)"
            e.accessibilityLabel = title
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
        guard norm.y >= 0, norm.y < TurkishQ.rowHeight * 3, norm.x >= 0, norm.x <= 1
        else { return nil }

        switch plane {
        case .letters:
            // Çerçeve testi değil **en yakın merkez**: tuşlar arası boşlukta da
            // bir aday üretilir; belirsizliği uzamsal model zaten çözer.
            guard let idx = layout.nearestKey(to: norm) else { return nil }
            return .letter(index: idx, point: norm)
        case .numbers, .symbols:
            // Burada model YOK — çerçeve testi. En yakın merkez kullanmak, iki
            // sembol arasındaki boşluğa dokunanın rastgele birini almasına yol
            // açardı; `3` yerine `4` yazmak düpedüz hata.
            let planeData = plane == .numbers ? SymbolPlanes.numbers : SymbolPlanes.symbols
            guard let i = planeData.hit(at: norm) else { return nil }
            return .symbol(planeData.keys[i].char)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let h = hit(at: t.location(in: self)) else { continue }
            let id = ObjectIdentifier(t)
            activeTouches[id] = h
            setPressed(h, true)
            if case .function(.globe) = h { globeTouchStart = Date() }
            if Self.repeats(h) { startRepeat(h, id: id) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let old = activeTouches[id] else { continue }
            let new = hit(at: t.location(in: self))
            if new != old {
                setPressed(old, false)
                // Parmak tuştan kaydıysa tekrar durur — sürükleyip başka bir
                // yerde bırakmak silmeye devam etmemeli.
                if repeatTouch == id { cancelRepeat() }
                if let new { activeTouches[id] = new; setPressed(new, true) }
                else { activeTouches[id] = nil }   // klavye dışına sürüklendi
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            // Tekrar temizliği `activeTouches` guard'ından ÖNCE: parmak klavye
            // dışına sürüklenmişse kaydı orada silinmiş oluyor ve guard erken
            // çıkıyordu — `repeatedTouches` sızıyordu.
            let didRepeat = repeatedTouches.remove(id) != nil
            // Devralmadan ÖNCE bu parmak listeden düşmeli, yoksa kalkan parmak
            // sahipliği kendine devreder.
            let ended = activeTouches.removeValue(forKey: id)
            if repeatTouch == id { cancelRepeat(); adoptPendingRepeat() }

            guard let h = ended else { continue }
            setPressed(h, false)

            // Globe uzun basma → sistem input-mode listesi.
            if case .function(.globe) = h, let start = globeTouchStart,
               Date().timeIntervalSince(start) > 0.5 {
                globeTouchStart = nil
                onGlobeLongPress?(self, event)
                continue
            }
            globeTouchStart = nil
            if !didRepeat { onKeyCommit?(h) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // İptal: vurgu kalkar, **hiçbir karakter üretilmez**.
        for t in touches {
            let id = ObjectIdentifier(t)
            if let h = activeTouches.removeValue(forKey: id) { setPressed(h, false) }
            repeatedTouches.remove(id)
            if repeatTouch == id { cancelRepeat(); adoptPendingRepeat() }
        }
        globeTouchStart = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Klavye kaybolurken çalışan bir zamanlayıcı kalmasın.
        if newWindow == nil { cancelRepeat(); repeatedTouches.removeAll() }
    }

    // MARK: - Tekrar zamanlayıcısı

    /// Şimdilik yalnız geri silme tekrar ediyor. Boşlukta imleç sürükleme ve
    /// harf tekrarı ayrı davranışlar; buraya girerlerse kendi kademeleriyle girer.
    private static func repeats(_ h: KeyHit) -> Bool { h == .function(.backspace) }

    private func startRepeat(_ h: KeyHit, id: ObjectIdentifier) {
        // Sahiplik devredilmez: ikinci bir parmak zaten tekrar eden bir tuşa
        // basarsa hızı ikiye katlamamalı, birincinin durumunu da ezmemeli.
        guard repeatTouch == nil else { return }
        repeatKey = h
        repeatTouch = id
        repeatTicks = 0
        schedule(after: cadence.initialDelay)
    }

    /// Her tekrar kendi zamanlayıcısını kurar. Tek bir tekrarlayan `Timer`
    /// kullanmak kademe değişiminde aralığı güncelleyemiyordu; tik başına bir
    /// zamanlayıcı saniyede ~11 tane demek, ölçülebilir bir maliyet değil.
    private func fireRepeat() {
        guard let h = repeatKey else { return }
        if let id = repeatTouch { repeatedTouches.insert(id) }
        repeatTicks += 1
        onKeyRepeat?(h, cadence.stage(forTick: repeatTicks))
        schedule(after: cadence.interval(afterTick: repeatTicks))
    }

    /// Zamanlayıcı `.common` modlarına eklenir: `.default` modda kalmak, ileride
    /// klavye içinde kaydırılabilir bir yüzey (emoji, öneri şeridi) çıktığında
    /// tekrarın sessizce durmasına yol açardı.
    private func schedule(after interval: TimeInterval) {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.fireRepeat()
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    /// Sahip parmak kalktığında hâlâ basılı duran bir tekrar adayı varsa
    /// sahipliği ona verir.
    ///
    /// Olmasa tekrar sessizce dururdu: iki parmakla geri silerken birini
    /// kaldırmak silmeyi kesiyor, kullanıcıya tuş takılmış gibi geliyordu.
    /// Gecikme baştan işliyor — devralma yeni bir basış sayılıyor.
    private func adoptPendingRepeat() {
        guard repeatTouch == nil else { return }
        for (id, h) in activeTouches where Self.repeats(h) {
            startRepeat(h, id: id)
            return
        }
    }

    private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
        repeatTouch = nil
        repeatTicks = 0
    }

    private func setPressed(_ h: KeyHit, _ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // örtük CoreAnimation animasyonu istemiyoruz
        switch h {
        case let .letter(i, _):
            if i < keyBackgrounds.count {
                keyBackgrounds[i].backgroundColor = (pressed ? Self.pressedColor : Self.normalKeyColor).cgColor
            }
        case let .symbol(ch):
            // Sembol düzleminde indeks yerine karakterle bulunuyor: `planeKeys`
            // ve katmanlar aynı sırada kuruluyor.
            if let i = planeKeys.firstIndex(where: { $0.char == ch }),
               i < keyBackgrounds.count {
                keyBackgrounds[i].backgroundColor = (pressed ? Self.pressedColor : Self.normalKeyColor).cgColor
            }
        case let .function(fk):
            // Kilitli shift basılı değilken de vurgulu kalmalı.
            let base = (fk == .shift && isShiftLocked)
                ? Self.pressedColor : Self.functionKeyColor
            functionBackgrounds[fk]?.backgroundColor =
                (pressed ? Self.pressedColor : base).cgColor
        }
        CATransaction.commit()
    }
}
