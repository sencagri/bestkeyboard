import UIKit
import KBGeometry
import KBRuntime

/// Tuş çizimi ve dokunma yakalama.
///
/// Skor sözleşmesi §11.B gereği:
/// - Tuş başına `UIView` **yok** — tek barındırıcı view + `CALayer` alt katmanları.
/// - Yazarken Auto Layout **yok**; çerçeveler yalnız boyut değişiminde hesaplanır.
/// - Görsel vurgu decoder'ı **asla beklemez**; iki yol arasında bağ yoktur.
///
/// Dokunma sözleşmesi:
/// - Vurgu `touchesBegan`'de (düşük gecikme), **eylem `touchesEnded`'de** kesinleşir.
///   Parmak tuştan kayarsa hedef güncellenir; klavyeden çıkarsa veya sistem iptal
///   ederse hiçbir karakter üretilmez.
/// - Çoklu dokunma parmak başına izlenir (rollover): ikinci parmak birincinin
///   durumunu ezmez.
///
/// Geometri sözleşmesi:
/// - Çerçevelerin **hiçbiri** burada uydurulmaz. Harf merkezleri
///   `TurkishQ.layout(metrics:)`'ten, işlev tuşu yuvaları
///   `KeyboardGeometry.functionSlots`'tan geliyor. Bu ayrım bir hatadan doğdu:
///   iki hesap ayrı yerlerdeyken tutarsızlaştı ve `⇧`/`⌫` `z` ile `ç`'nin
///   üstüne bindi — dokunma testi işlev tuşlarına öncelik verdiği için o
///   harflerin yarısı basılamaz oldu.
final class KeyboardView: UIView {

    /// İşlev tuşları layout verisinde değil (harf değiller), burada tanımlı.
    enum FunctionKey: Hashable {
        case shift, backspace, numbers, symbols, letters, globe, space, ret
    }

    enum KeyHit: Equatable {
        /// Harf düzlemi — **kod çözmeye girer**, uzamsal kanıt taşır.
        case letter(index: Int, point: Point)
        /// Rakam/sembol düzlemi — doğrudan yazılır, model yok.
        case symbol(Character)
        /// Üst sayı sırası — sembol gibi doğrudan yazılır ama **ayrı yüzey**:
        /// rakam düzleminde aynı karakter iki yerde birden bulunabiliyor ve
        /// vurgunun hangi katmana gideceği belirsiz kalırdı.
        case digit(Character)
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

    // MARK: - Dokunma kaydı (sözleşme §12.7)

    /// Bir dokunmanın **tam yaşam döngüsü**.
    ///
    /// ## Neden `KeyHit` yetmiyor
    ///
    /// `KeyHit` yalnız *kesinleşmiş* bir tuşu taşır ve yalnız normalize
    /// koordinat içerir. Ölçüm için üç şey daha gerekiyor:
    ///
    /// 1. **Hiç kesinleşmeyen dokunmalar.** `touchesBegan` `hit(at:)` `nil`
    ///    dönerse dokunmayı hiç kaydetmiyor; parmak tuş çerçevelerinin dışına,
    ///    aralarındaki boşluğa ya da alt kenara düşerse **hiçbir iz kalmıyor**
    ///    (görsel geri bildirim de yok). Kullanıcının "boşluğa bastım ama
    ///    olmadı" gözlemi ancak bu kaydedilirse yanıtlanabilir: dokunma hiç
    ///    başlamadıysa isabet edilmemiştir, başlayıp `leftBounds` ile bittiyse
    ///    klavye düşürmüştür.
    /// 2. **Ham koordinat.** Normalize koordinat cihaz bağımsız; ham nokta ve
    ///    `bounds` olmadan "tuşun neresine basıldı" fiziksel olarak yeniden
    ///    kurulamaz. `bounds` tam gerekiyor çünkü normalizasyon `minX/minY`'yi
    ///    de çıkarıyor.
    /// 3. **Down ile up ayrımı.** `KeyHit.point` `touchesBegan`'de kurulup
    ///    `touchesMoved`'da değişiyor ve `touchesEnded`'da yeniden
    ///    hesaplanmıyor — yani "dokunmanın yeri" tek anlamlı değil. Ölçüm
    ///    aracında bu belirsizlik kabul edilemez.
    struct TouchRecord {
        enum Phase: String { case began, moved, ended, cancelled }

        /// Dokunmanın **sonu** ne oldu. Yalnız `ended`/`cancelled`'da anlamlı.
        enum Outcome: String {
            /// Tuş kesinleşti, `onKeyCommit` çağrıldı.
            case committed
            /// Sistem iptal etti (çağrı geldi, uygulama arkaya alındı…).
            case cancelled
            /// Parmak bir tuşa isabet etmişti ama kayıp klavye dışına çıktı —
            /// sessizce düştü.
            case leftBounds
            /// Dokunma **hiçbir zaman** bir tuşa isabet etmedi: tuş çerçeveleri
            /// dışına, aralarındaki boşluğa ya da alt kenara düştü. `leftBounds`
            /// ile karıştırılmamalı — biri "bastın, klavye düşürdü", diğeri
            /// "isabet etmedin".
            case neverHit
            /// Basılı tutma tekrarı çalıştı; bırakma fazladan karakter üretmez.
            case repeated
            /// Henüz bitmedi (`began`/`moved`).
            case pending
        }

        /// Dizinin indeksi DEĞİL, kalıcı kimlik: fazlar arası eşleme bunun
        /// üzerinden yapılır ve silinen dokunmalar numaraları kaydırmaz.
        var touchID: Int
        var phase: Phase
        /// Görünüm koordinatı, **nokta** cinsinden (piksel değil).
        var raw: CGPoint
        /// Decoder'ın gördüğü değer — isabet yoksa `nil`.
        var normalized: Point?
        /// Normalizasyonu yeniden kurmak için; `origin` dahil.
        var bounds: CGRect
        /// `UITouch.timestamp` — sistem açılışından beri monoton.
        var timestamp: TimeInterval
        var majorRadius: CGFloat
        var majorRadiusTolerance: CGFloat
        var hit: KeyHit?
        var plane: Plane
        var outcome: Outcome
    }

    /// Dokunma kaydı gözlemcisi. `nil` iken **hiçbir kayıt üretilmez**.
    ///
    /// Üretimde `nil` kalır. Gözlemci yokken tek maliyet fazın başındaki
    /// opsiyonel kontrolüdür; `TouchRecord` o kontrolden sonra kurulur, önce
    /// değil — aksi hâlde "sıfır maliyet" iddiası yanlış olurdu.
    var onTouchRecord: ((TouchRecord) -> Void)?

    /// Dokunma başına kalıcı kimlik üreteci.
    private var nextTouchID = 0
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    /// Hangi dokunmalar bir noktada bir tuşa isabet etti — `leftBounds` ile
    /// `neverHit`'i ayırmak için. Yalnız gözlemci varken doldurulur.
    private var everHitTouches: Set<ObjectIdentifier> = []

    private func record(_ t: UITouch, _ phase: TouchRecord.Phase,
                        hit: KeyHit?, outcome: TouchRecord.Outcome) {
        guard let observer = onTouchRecord else { return }
        let id = ObjectIdentifier(t)
        let tid: Int
        if let existing = touchIDs[id] { tid = existing }
        else { tid = nextTouchID; nextTouchID += 1; touchIDs[id] = tid }

        let p = t.location(in: self)
        var norm: Point?
        if bounds.width > 0, bounds.height > 0 {
            norm = Point(x: Double((p.x - bounds.minX) / bounds.width),
                         y: Double((p.y - bounds.minY) / bounds.height))
        }
        if hit != nil { everHitTouches.insert(id) }
        observer(TouchRecord(touchID: tid, phase: phase, raw: p, normalized: norm,
                             bounds: bounds, timestamp: t.timestamp,
                             majorRadius: t.majorRadius,
                             majorRadiusTolerance: t.majorRadiusTolerance,
                             hit: hit, plane: plane, outcome: outcome))
        if phase == .ended || phase == .cancelled {
            touchIDs[id] = nil
            everHitTouches.remove(id)
        }
    }

    /// İsabet etmeden biten dokunmanın sonucu.
    private func unhitOutcome(_ t: UITouch) -> TouchRecord.Outcome {
        everHitTouches.contains(ObjectIdentifier(t)) ? .leftBounds : .neverHit
    }
    /// Globe uzun basma / sürükleme — sistem input-mode listesi için.
    var onGlobeLongPress: ((UIView, UIEvent?) -> Void)?
    /// `needsInputModeSwitchKey` false ise globe çizilmez.
    var showsGlobeKey: Bool = true {
        didSet { guard showsGlobeKey != oldValue else { return }; setNeedsLayout() }
    }

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

    /// Aktif tema. Katmanlara `cgColor` yazıldığı için dinamik renk
    /// kullanılamıyor; kip değişiminde sahibi bunu yeniden atamalı.
    var theme: KeyboardTheme = .light {
        didSet { guard theme != oldValue else { return }; applyTheme() }
    }

    private(set) var layout: KeyLayout
    private(set) var metrics: KeyboardMetrics

    /// Ölçü değişimi geometriyi baştan kurar.
    ///
    /// `layout` dışarıdan geliyor çünkü decoder'ın uzamsal modeli **aynı**
    /// nesneden kurulmalı; görünümün kendi başına bir layout üretmesi, çizilen
    /// ile skorlanan geometrinin ayrışması demekti.
    func apply(layout: KeyLayout, metrics: KeyboardMetrics) {
        self.layout = layout
        self.metrics = metrics
        cancelAllTouches()
        buildLayers()
    }

    private var keyBackgrounds: [CALayer] = []
    private var keyLabels: [CATextLayer] = []
    private var keyFrames: [CGRect] = []
    private var digitBackgrounds: [CALayer] = []
    private var digitLabels: [CATextLayer] = []
    private var digitFrames: [CGRect] = []
    private var functionBackgrounds: [FunctionKey: CALayer] = [:]
    private var functionLabels: [FunctionKey: CATextLayer] = [:]
    private var functionFrames: [(FunctionKey, CGRect)] = []

    /// Parmak → o parmağın şu anki hedefi. Rollover için parmak başına izlenir.
    private var activeTouches: [ObjectIdentifier: KeyHit] = [:]
    /// Globe basış anı **parmak başına**. Tek alan yetmiyordu: rollover'da
    /// başka bir parmağın kalkması alanı temizliyor, globe sonradan
    /// bırakıldığında uzun basma kısa dokunmaya düşüyordu.
    private var globeTouchStart: [ObjectIdentifier: Date] = [:]

    // MARK: Basılı tutma tekrarı
    //
    // Zamanlama politikası `KBRuntime.KeyRepeatCadence`'ta; burada yalnız
    // zamanlayıcı ve dokunma sahipliği var.
    /// Zamanlama politikası kullanıcı ayarı. Değişimi **çalışan** bir tekrarı
    /// etkilemiyor: aralık her tikte yeniden okunuyor, bir sonraki basıştan
    /// itibaren yeni değer geçerli.
    var cadence = KeyRepeatCadence.default
    private var repeatTouch: ObjectIdentifier?
    private var repeatKey: KeyHit?
    private var repeatTimer: Timer?
    private var repeatTicks = 0
    /// Tekrar üretmiş parmaklar. Tek bir `repeatTouch` alanı yetmiyordu: ikinci
    /// bir parmak sahipliği devraldığında birincinin "tekrar etti" bilgisi
    /// kayboluyor, bırakıldığında fazladan bir silme commit ediliyordu.
    private var repeatedTouches: Set<ObjectIdentifier> = []

    init(layout: KeyLayout, metrics: KeyboardMetrics = .default) {
        self.layout = layout
        self.metrics = metrics
        super.init(frame: .zero)
        backgroundColor = theme.background
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

    /// Aktif sembol düzlemi — harf düzleminde `nil`. Dokunma yolunda yeniden
    /// üretilmiyor: `hit(at:)` her dokunuşta çağrılıyor ve düzlemi orada
    /// kurmak tuş başına bir dizi ayırması demekti.
    private var planeData: SymbolPlanes.Plane?
    private var planeKeys: [SymbolPlanes.PlaneKey] { planeData?.keys ?? [] }
    /// Üst sayı sırası — kapalıysa boş. Vuruş çözümü `KeyboardGeometry`'de.
    private var numberRow: [SymbolPlanes.PlaneKey] = []

    private func buildLayers() {
        for l in keyBackgrounds + digitBackgrounds { l.removeFromSuperlayer() }
        for l in keyLabels + digitLabels { l.removeFromSuperlayer() }
        keyBackgrounds.removeAll(); keyLabels.removeAll()
        digitBackgrounds.removeAll(); digitLabels.removeAll()

        // Arka plan ve metin AYRI katmanlar: basılı rengi arka planda
        // değiştiririz, metin üstte kalır. (Tek katmanda tutmak, vurgu
        // katmanının opak arka planların altında kalmasına yol açıyordu.)
        func addKey(_ title: String, into bgs: inout [CALayer],
                    _ texts: inout [CATextLayer]) {
            let bg = CALayer()
            bg.backgroundColor = theme.keyFace.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            bgs.append(bg)

            let t = CATextLayer()
            t.string = title
            t.alignmentMode = .center
            t.foregroundColor = theme.keyText.cgColor
            t.contentsScale = UIScreen.main.scale
            layer.addSublayer(t)
            texts.append(t)
        }

        switch plane {
        case .letters:
            planeData = nil
            for key in layout.keys { addKey(letterTitle(key.char), into: &keyBackgrounds, &keyLabels) }
        case .numbers, .symbols:
            planeData = plane == .numbers
                ? SymbolPlanes.numbersPlane(metrics: metrics)
                : SymbolPlanes.symbolsPlane(metrics: metrics)
            for k in planeKeys { addKey(String(k.char), into: &keyBackgrounds, &keyLabels) }
        }

        // Sayı sırası her düzlemde duruyor. Rakam düzleminde 1. satırı
        // tekrarlıyor ama gizlemek düzlem geçişinde bütün tuşları kaydırırdı;
        // "düzlem değişince tuşlar yerinden oynamamalı" kuralı ağır basıyor.
        numberRow = KeyboardGeometry.numberRow(metrics)
        for k in numberRow { addKey(String(k.char), into: &digitBackgrounds, &digitLabels) }

        if functionBackgrounds.isEmpty { buildFunctionLayers() }
        refreshFunctionTitles()
        setNeedsLayout()
    }

    private func buildFunctionLayers() {
        for fk in [FunctionKey.shift, .backspace, .numbers, .symbols, .letters,
                   .globe, .space, .ret] {
            let bg = CALayer()
            bg.backgroundColor = theme.functionFace.cgColor
            bg.cornerRadius = 5
            layer.addSublayer(bg)
            functionBackgrounds[fk] = bg

            let t = CATextLayer()
            t.alignmentMode = .center
            t.foregroundColor = theme.functionText.cgColor
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

    /// Tema değişimi: katman renkleri `cgColor` olduğu için tek tek yazılmalı.
    private func applyTheme() {
        backgroundColor = theme.background
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in keyBackgrounds + digitBackgrounds { l.backgroundColor = theme.keyFace.cgColor }
        for t in keyLabels + digitLabels { t.foregroundColor = theme.keyText.cgColor }
        for (_, l) in functionBackgrounds { l.backgroundColor = theme.functionFace.cgColor }
        for (_, t) in functionLabels { t.foregroundColor = theme.functionText.cgColor }
        CATransaction.commit()
        setNeedsLayout()   // vurgular `layoutSubviews` sonunda geri geliyor
    }

    /// Türkçe büyük harf: `i → İ`, `ı → I`. Locale'siz `uppercased()` ikisini
    /// birbirine karıştırır.
    private func letterTitle(_ ch: Character) -> String {
        isUppercase ? String(ch).uppercased(with: Locale(identifier: "tr"))
                    : String(ch)
    }

    /// Dış dünyanın etkileşimi kesme yolu — ayar paneli açılırken çağrılır.
    ///
    /// Panel klavyenin üstünü kaplıyor ama **zaten basılı** parmaklar olaylarını
    /// almaya devam ediyor: ⌫'yi basılı tutarken ikinci parmakla ⚙︎'ye basmak
    /// panelin arkasında silmeyi sürdürüyordu.
    func cancelInteraction() { cancelAllTouches() }

    private func cancelAllTouches() {
        // Bekleyen dokunmalar **iptal edilir**.
        //
        // Çoklu dokunmada bir parmak basılıyken ikincisi `123`/`ABC` yaparsa,
        // birincinin eski `KeyHit`'i yeni düzlemde commit edilirdi — `setPressed`
        // de eski karakteri yeni `planeKeys` içinde arardı.
        for (_, h) in activeTouches { setPressed(h, false) }
        activeTouches.removeAll()
        repeatedTouches.removeAll()
        globeTouchStart.removeAll()
        cancelRepeat()
    }

    private func rebuildForPlane() {
        cancelAllTouches()
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

        func rect(center: Point, w: Double, h: Double) -> CGRect {
            let kw = w * W, kh = h * H
            return CGRect(x: center.x * W - kw / 2, y: center.y * H - kh / 2,
                          width: kw, height: kh)
        }

        func placeKey(_ i: Int, _ r: CGRect, _ bgs: [CALayer], _ texts: [CATextLayer]) {
            guard i < bgs.count else { return }
            bgs[i].frame = r.insetBy(dx: inset, dy: inset)
            place(texts[i], in: r, fontSize: min(r.height * 0.42, 22))
        }

        // İçerik satırları (harf ya da sembol).
        keyFrames.removeAll(keepingCapacity: true)
        switch plane {
        case .letters:
            for (i, k) in layout.keys.enumerated() {
                let r = rect(center: k.center, w: k.width, h: k.height)
                keyFrames.append(r)
                placeKey(i, r, keyBackgrounds, keyLabels)
            }
        case .numbers, .symbols:
            for (i, k) in planeKeys.enumerated() {
                let r = rect(center: k.center, w: k.width, h: k.height)
                keyFrames.append(r)
                placeKey(i, r, keyBackgrounds, keyLabels)
            }
        }

        // Üst sayı sırası.
        digitFrames.removeAll(keepingCapacity: true)
        for (i, k) in numberRow.enumerated() {
            let r = rect(center: k.center, w: k.width, h: k.height)
            digitFrames.append(r)
            placeKey(i, r, digitBackgrounds, digitLabels)
        }

        // İşlev tuşları — yuvalar çekirdekten, rol → tuş eşlemesi burada.
        var frames: [(FunctionKey, CGRect)] = []
        for slot in KeyboardGeometry.functionSlots(metrics, showsGlobe: showsGlobeKey) {
            guard let fk = functionKey(for: slot.role) else { continue }
            frames.append((fk, CGRect(x: slot.rect.x * W, y: slot.rect.y * H,
                                      width: slot.rect.width * W,
                                      height: slot.rect.height * H)))
        }
        functionFrames = frames

        for (fk, bg) in functionBackgrounds {
            guard let f = frames.first(where: { $0.0 == fk })?.1 else {
                bg.isHidden = true; functionLabels[fk]?.isHidden = true; continue
            }
            bg.isHidden = false; functionLabels[fk]?.isHidden = false
            bg.frame = f.insetBy(dx: inset, dy: inset)
            // Kilitli shift vurgulu çizilir.
            let locked = (fk == .shift && isShiftLocked)
            bg.backgroundColor = (locked ? theme.pressedFace : theme.functionFace).cgColor
            if let t = functionLabels[fk] {
                t.foregroundColor = (locked ? theme.pressedText : theme.functionText).cgColor
                place(t, in: f, fontSize: min(f.height * 0.30, 15))
            }
        }

        // Aktif vurgular **en sonda** geri uygulanıyor.
        //
        // İşlev tuşlarının rengi yukarıda temel/kilitli renge sıfırlanıyor;
        // trait ya da tema değişimi basılı bir `⇧`/`⌫`/boşluk sırasında
        // gelirse vurgu kayboluyordu. Harflerde sıfırlama olmadığı için iki
        // tuş sınıfı farklı davranıyordu — şimdi ikisi de aynı.
        for (_, h) in activeTouches { setPressed(h, true) }

        rebuildAccessibilityElements()
    }

    /// Rol → o düzlemde o yuvada duran tuş.
    ///
    /// 3. satırın solu harf düzleminde `⇧`, sembol düzlemlerinde diğer sembol
    /// düzlemine geçiş; 4. satırın solu harf düzleminde `123`, diğerlerinde
    /// `ABC`.
    private func functionKey(for role: FunctionRole) -> FunctionKey? {
        switch role {
        case .leftModifier:
            return plane == .letters ? .shift : (plane == .numbers ? .symbols : .numbers)
        case .backspace:   return .backspace
        case .planeSwitch: return plane == .letters ? .numbers : .letters
        case .globe:       return showsGlobeKey ? .globe : nil
        case .space:       return .space
        case .ret:         return .ret
        }
    }

    /// `CATextLayer` metni üstten hizalar; tek geçişte dikeyde ortalar.
    private func place(_ t: CATextLayer, in r: CGRect, fontSize: CGFloat) {
        t.fontSize = fontSize
        let lineHeight = fontSize * 1.2
        t.frame = CGRect(x: r.minX, y: r.midY - lineHeight / 2, width: r.width, height: lineHeight)
    }

    // MARK: - Erişilebilirlik
    //
    // Öğeler **okunabilir ama etkinleştirilemez**: `accessibilityActivate()`
    // bağlı değil, yani VoiceOver çift dokunuşu karakter üretmiyor. Bilinçli
    // bir boşluk (README'de VoiceOver ❌).
    //
    // Sebebi bağlamanın kolay olmaması değil, **kanıtın sahte olması**: harf
    // aktivasyonu tuş merkezinden bir `Point` üretmek zorunda kalırdı ve o
    // dokunma kalibrasyon öğrenimine girerdi. Tam merkeze konan dokunmalar
    // uzamsal sinyali silen şeyin ta kendisi (§8.1.1'de ölçüm bu yüzden
    // hatalıydı) — sapma öğrenimini sistematik olarak sıfıra çekerdi.
    // Doğru çözüm `InputCoordinator`'ın sentetik kanıtı ayırt etmesi
    // (`beginEditingSelectionSynthetic`'in yaptığı gibi); bu turun kapsamı
    // değil.

    private func rebuildAccessibilityElements() {
        var elements: [UIAccessibilityElement] = []

        func add(_ id: String, _ label: String, _ frame: CGRect) {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = id
            e.accessibilityLabel = label
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = frame
            elements.append(e)
        }

        // Sayı sırası ayrı bir önek alıyor: rakam düzleminin 1. satırı aynı
        // karakterleri taşıyor ve sayı sırası açıkken `key.1` iki öğeye birden
        // ait oluyordu — hem XCUITest seçimi hem teşhis belirsizleşiyordu.
        for (i, k) in numberRow.enumerated() where i < digitFrames.count {
            add("key.numRow.\(k.char)", String(k.char), digitFrames[i])
        }
        let titles: [String] = plane == .letters
            ? layout.keys.map { String($0.char) }
            : planeKeys.map { String($0.char) }
        for (i, title) in titles.enumerated() where i < keyFrames.count {
            add("key.\(title)", title, keyFrames[i])
        }
        for (fk, f) in functionFrames { add("key.\(fk)", "\(fk)", f) }
        accessibilityElements = elements
    }

    // MARK: - Dokunma

    /// Öncelik sırası (sayı sırası → işlev → içerik) **çekirdekte**; burada
    /// yalnız yüzeyin o düzlemdeki karşılığı bulunuyor.
    private func hit(at p: CGPoint) -> KeyHit? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let norm = Point(x: Double((p.x - bounds.minX) / bounds.width),
                         y: Double((p.y - bounds.minY) / bounds.height))

        switch KeyboardGeometry.surface(at: norm, metrics: metrics,
                                        showsGlobe: showsGlobeKey) {
        case .none:
            return nil
        case let .digit(i):
            guard i < numberRow.count else { return nil }
            return .digit(numberRow[i].char)
        case let .function(role):
            guard let fk = functionKey(for: role) else { return nil }
            return .function(fk)
        case .content:
            switch plane {
            case .letters:
                // Çerçeve testi değil **en yakın merkez**: tuşlar arası boşlukta
                // da bir aday üretilir; belirsizliği uzamsal model zaten çözer.
                guard let idx = layout.nearestKey(to: norm) else { return nil }
                return .letter(index: idx, point: norm)
            case .numbers, .symbols:
                // Burada model YOK — çerçeve testi. En yakın merkez kullanmak,
                // iki sembol arasındaki boşluğa dokunanın rastgele birini
                // almasına yol açardı; `3` yerine `4` yazmak düpedüz hata.
                guard let pd = planeData, let i = pd.hit(at: norm) else { return nil }
                return .symbol(pd.keys[i].char)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let h0 = hit(at: t.location(in: self))
            // Kayıt guard'dan ÖNCE: isabet etmeyen dokunma da olmuş bir olaydır
            // ve tam da onu görmek isteniyor.
            record(t, .began, hit: h0, outcome: .pending)
            guard let h = h0 else { continue }
            let id = ObjectIdentifier(t)
            activeTouches[id] = h
            setPressed(h, true)
            if case .function(.globe) = h { globeTouchStart[id] = Date() }
            if Self.repeats(h) { startRepeat(h, id: id) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let old = activeTouches[id] else { continue }
            let new = hit(at: t.location(in: self))
            if new != old {
                record(t, .moved, hit: new, outcome: .pending)
                setPressed(old, false)
                // Parmak tuştan kaydıysa tekrar durur — sürükleyip başka bir
                // yerde bırakmak silmeye devam etmemeli.
                if repeatTouch == id { cancelRepeat() }
                // Globe'dan kayan parmak uzun basma sayacını da bırakır.
                if case .function(.globe) = old { globeTouchStart.removeValue(forKey: id) }
                if let new {
                    activeTouches[id] = new
                    setPressed(new, true)
                    if case .function(.globe) = new { globeTouchStart[id] = Date() }
                } else { activeTouches[id] = nil }   // klavye dışına sürüklendi
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

            guard let h = ended else {
                // Parmak klavye dışına sürüklenmiş ve `touchesMoved` kaydı
                // silmiş. Kullanıcı açısından "bastım ama olmadı" tam olarak
                // burası; iz bırakmadan geçmemeli.
                record(t, .ended, hit: nil, outcome: unhitOutcome(t))
                continue
            }
            setPressed(h, false)

            // Globe uzun basma → sistem input-mode listesi.
            let globeStart = globeTouchStart.removeValue(forKey: id)
            if case .function(.globe) = h, let start = globeStart,
               Date().timeIntervalSince(start) > 0.5 {
                record(t, .ended, hit: h, outcome: .committed)
                onGlobeLongPress?(self, event)
                continue
            }
            // Kayıt commit'ten ÖNCE: `onKeyCommit` senkron olarak decode'u
            // tetikliyor ve kayıtçının aday anlık görüntüsünü commit'ten SONRA
            // alması gerekiyor. Ters sırada kaydedilen adaylar bir önceki
            // prefix'e ait olurdu (§12.7).
            record(t, .ended, hit: h, outcome: didRepeat ? .repeated : .committed)
            if !didRepeat { onKeyCommit?(h) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // İptal: vurgu kalkar, **hiçbir karakter üretilmez**.
        for t in touches {
            let id = ObjectIdentifier(t)
            let h = activeTouches.removeValue(forKey: id)
            if let h { setPressed(h, false) }
            repeatedTouches.remove(id)
            globeTouchStart.removeValue(forKey: id)
            if repeatTouch == id { cancelRepeat(); adoptPendingRepeat() }
            record(t, .cancelled, hit: h, outcome: .cancelled)
        }
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
            paint(i, in: keyBackgrounds, keyLabels, pressed: pressed)
        case let .symbol(ch):
            // Sembol düzleminde indeks yerine karakterle bulunuyor: `planeKeys`
            // ve katmanlar aynı sırada kuruluyor.
            if let i = planeKeys.firstIndex(where: { $0.char == ch }) {
                paint(i, in: keyBackgrounds, keyLabels, pressed: pressed)
            }
        case let .digit(ch):
            if let i = numberRow.firstIndex(where: { $0.char == ch }) {
                paint(i, in: digitBackgrounds, digitLabels, pressed: pressed)
            }
        case let .function(fk):
            // Kilitli shift basılı değilken de vurgulu kalmalı.
            let locked = (fk == .shift && isShiftLocked)
            let on = pressed || locked
            functionBackgrounds[fk]?.backgroundColor =
                (on ? theme.pressedFace : theme.functionFace).cgColor
            functionLabels[fk]?.foregroundColor =
                (on ? theme.pressedText : theme.functionText).cgColor
        }
        CATransaction.commit()
    }

    private func paint(_ i: Int, in bgs: [CALayer], _ texts: [CATextLayer], pressed: Bool) {
        guard i < bgs.count else { return }
        bgs[i].backgroundColor = (pressed ? theme.pressedFace : theme.keyFace).cgColor
        texts[i].foregroundColor = (pressed ? theme.pressedText : theme.keyText).cgColor
    }
}
