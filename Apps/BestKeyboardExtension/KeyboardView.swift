import UIKit
import KBGeometry
import KBRuntime
import KBSessions

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
final class KeyboardView: LazyAccessibilityView {

    /// İşlev tuşları layout verisinde değil (harf değiller), burada tanımlı.
    ///
    /// `period` karakter üretiyor ama yine buraya ait: kod çözmeye girmiyor,
    /// yani `KeyLayout`'un değil işlev yuvalarının vatandaşı
    /// (`FunctionRole.period`).
    enum FunctionKey: Hashable {
        case shift, backspace, numbers, symbols, letters, globe, space, ret
        case period
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

    /// Tuşun **nasıl** kesinleştiği.
    ///
    /// Ayrım kozmetik değil: erişilebilirlik etkinleştirmesinin bir parmak
    /// koordinatı yok. VoiceOver kullanıcısı tuşu duyup çift dokunuyor ve o çift
    /// dokunuş ekranın herhangi bir yerinde olabiliyor — sistem bize yalnız
    /// **hangi öğenin** etkinleştirildiğini söylüyor. `KeyHit.letter`'ın taşımak
    /// zorunda olduğu nokta bu yüzden tuşun merkezinden **türetiliyor**, ve
    /// türetilmiş olduğu bilgisi motora kadar gitmek zorunda (§8.9).
    enum KeyActivation: Equatable {
        /// Parmak yüzeye düştü; koordinat bir **gözlem**.
        case touch
        /// VoiceOver etkinleştirdi; koordinat tuş merkezinden türetildi.
        case accessibility
    }

    /// Tuş kesinleştiğinde çağrılır (`touchesEnded`, ya da erişilebilirlik
    /// etkinleştirmesi).
    ///
    /// Tekrar başlamışsa bırakıldığında **çağrılmaz** — yoksa uzun basma son bir
    /// fazladan silme yapardı.
    var onKeyCommit: ((KeyHit, KeyActivation) -> Void)?

    /// Basılı tutma tekrarı.
    var onKeyRepeat: ((KeyHit, RepeatStage) -> Void)?

    /// Nokta tuşu eşiği geçecek kadar basılı tutuldu — **virgül**.
    ///
    /// Ayrı bir geri çağrı, çünkü `onKeyCommit` "şu tuş basıldı" diyor ve nokta
    /// tuşu iki farklı karakter üretebiliyor. Tuşu iki ayrı `KeyHit`e bölmek de
    /// mümkündü; bölünmemesinin sebebi vurgunun, çerçevenin ve erişilebilirlik
    /// öğesinin **tek** bir tuşa ait olması — ikiye bölmek üçünü de ikiye
    /// bölerdi.
    var onPeriodLongPress: (() -> Void)?

    /// Boşluk basılı tutuldu ya da yana kaydırıldı — imleç kipi açılıyor.
    ///
    /// Çağıran jest durumunu **burada** kuruyor: imlecin etrafındaki metin
    /// jest başında bir kez okunuyor ve bir daha okunmuyor (`CursorTrackpad`).
    var onSpaceDragBegan: (() -> Void)?

    /// Parmağın **başlangıçtan** toplam ötelenmesi, nokta cinsinden.
    ///
    /// Kare farkı değil toplam öteleme veriliyor: yuvarlama artıklarının
    /// birikmemesi ve parmağı geri getirenin imleci başladığı yere
    /// döndürebilmesi buna bağlı.
    ///
    /// - Returns: jest **sıfır olmayan bir hareket istediyse** `true`.
    ///
    ///   "İmleç oynadı" demiyor ve diyemez: `adjustTextPosition` sonuç
    ///   döndürmüyor, host'un isteği karşılayıp karşılamadığı gözlemlenemiyor.
    ///   Görünüm bunu **boşluk yazımını bastırmak** için kullanıyor ve doğru
    ///   olan da bu — kullanıcı sürükledi, boşluk beklemiyor.
    /// Üçüncü değer olay zamanı (ivme için). Dönüş: bu karede imlece verilen
    /// ofset, `0` = hareket yok.
    var onSpaceDragChanged: ((CGFloat, CGFloat, TimeInterval) -> Int)?

    /// Parmak kalktı ya da jest iptal oldu.
    var onSpaceDragEnded: (() -> Void)?

    /// Sürüklemeden **bağımsız** tek kelimelik adım (erişilebilirlik eylemi).
    ///
    /// Jestin kendisi bir öteleme istiyor ve VoiceOver'da öteleme yok; bu
    /// kapı aynı yeteneği ayrık adım olarak veriyor.
    /// - Parameter direction: `-1` geri, `+1` ileri.
    /// - Returns: imleç oynadıysa `true`.
    var onSpaceDragStep: ((Int) -> Bool)?

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

        /// Kayıt şemasının dokunma olgusu.
        ///
        /// **Tek eşleme.** Kayıt ekranı ve uzantı ayrı ayrı çeviriyordu; ikisi
        /// ayrıştığında aynı dokunma iki kayıtta farklı görünürdü. `KeyboardView`
        /// zaten iki hedefte de paylaşılıyor, dolayısıyla eşlemenin de burada
        /// olması doğru yer.
        func canonical(layout: KeyLayout, shift: String) -> CanonicalSession.Touch {
            var t = CanonicalSession.Touch(
                touchID: touchID,
                phase: .init(rawValue: phase.rawValue) ?? .ended,
                outcome: .init(rawValue: outcome.rawValue) ?? .pending,
                rawX: Double(raw.x), rawY: Double(raw.y),
                normX: normalized?.x, normY: normalized?.y,
                decoderX: nil, decoderY: nil,
                timestamp: timestamp,
                majorRadius: Double(majorRadius),
                majorRadiusTolerance: Double(majorRadiusTolerance),
                plane: String(describing: plane), shift: shift,
                hitKind: nil, key: nil, keyIndex: nil)
            switch hit {
            case let .letter(index, point):
                t.hitKind = "letter"
                t.key = String(layout.keys[index].char)
                t.keyIndex = index
                // Decoder'a **fiilen verilen** nokta; ham noktayla aynı
                // olmayabilir (normalizasyon bounds origin'ini de çıkarıyor) ve
                // replay'in birebir eşleşmesi için gereken bu değer.
                t.decoderX = point.x
                t.decoderY = point.y
            case let .symbol(ch), let .digit(ch):
                t.hitKind = "symbol"; t.key = String(ch)
            case let .function(fk):
                t.hitKind = "function"; t.key = String(describing: fk)
            case nil:
                break
            }
            return t
        }
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

    func record(_ t: UITouch, _ phase: TouchRecord.Phase,
                        hit: KeyHit?, outcome: TouchRecord.Outcome) {
        guard let observer = onTouchRecord else { return }
        let id = ObjectIdentifier(t)
        let tid: Int
        if let existing = touchIDs[id] { tid = existing }
        else { tid = nextTouchID; nextTouchID += 1; touchIDs[id] = tid }

        let p = t.location(in: self)
        let norm = normalized(p)
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

    /// Klavyenin **kendi kararıyla** düşürdüğü parmaklar.
    ///
    /// ## Neden ayrı tutuluyor
    ///
    /// Düşürülen parmak `activeTouches`'tan çıkıyor ve bırakıldığında
    /// `unhitOutcome` yoluna düşüyordu: `everHitTouches` dolu olduğu için
    /// sonuç **`.leftBounds`**, yani "parmak klavye dışına kaydı". Oysa parmak
    /// yerinde duruyor; onu düşüren klavyenin kendisi. §12 telemetrisinde
    /// "klavye neden dokunmayı düşürdü" sorusunu yanıtlayan alan tam da bu ve
    /// yanlış cevap veriyordu.
    ///
    /// Yeni bir `Outcome` durumu **eklenmedi**: `.cancelled` zaten olanı
    /// doğru anlatıyor (dokunma iptal edildi) ve şemaya değer eklemek v3
    /// okuyucularının tamamını ilgilendirirdi — telemetri doğruluğu için
    /// ödenecek doğru bedel değil. `.cancelled`'ın tanımı "sistem iptal etti"
    /// değil "iptal edildi" olarak genişledi.
    ///
    /// Kusur bu jestle gelmedi: düzlem değişimi ve panel açılışı
    /// (`cancelAllTouches`) aynı yoldan geçiyordu ve orada da yalan
    /// söylüyordu.
    private var suppressedTouches: [ObjectIdentifier: KeyHit] = [:]

    /// Parmakları klavye kararıyla düşürür ve **kaydedilebilir** bırakır.
    ///
    /// `ids` bir dizi: `activeTouches.keys` görünümünü doğrudan gezmek,
    /// döngünün içinde aynı sözlüğü değiştirmek olurdu.
    func suppress(_ ids: [ObjectIdentifier]) {
        for id in ids {
            guard let h = activeTouches.removeValue(forKey: id) else { continue }
            setPressed(h, false)
            suppressedTouches[id] = h
        }
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

    /// Shift durumunu yansıtır — üretim ve kayıt ekranı aynı eşleme.
    func show(_ shift: ShiftPolicy) {
        isUppercase = shift.isUppercase
        isShiftLocked = shift.mode == .locked
    }

    /// Aktif tema. Katmanlara `cgColor` yazıldığı için dinamik renk
    /// kullanılamıyor; kip değişiminde sahibi bunu yeniden atamalı.
    var theme: KeyboardTheme = .light {
        didSet { guard theme != oldValue else { return }; applyTheme() }
    }

    /// Arka planı (gradyan/fotoğraf) görünüm kendisi mi çiziyor.
    ///
    /// Klavye uzantısında `false`: orada arka plan öneri çubuğuyla **ortak**
    /// ve denetleyicinin `ThemeBackdropView`'ü ikisinin arkasında duruyor.
    /// Tezgah ve önizlemelerde çubuk yok, görünüm kendi arkasını çiziyor.
    var drawsBackdrop = true {
        didSet { backdropView.isHidden = !drawsBackdrop; applyTheme() }
    }
    private let backdropView = ThemeBackdropView()

    /// Basışta hafif titreşim (`KeyboardSettings.haptics`).
    ///
    /// Basışta, bırakışta değil: Apple klavyesi de parmak değdiği an titriyor
    /// ve kullanıcı geri bildirimi tuşa **değdiği** anla eşliyor. Klavye
    /// uzantısında iOS titreşimi yalnız Tam Erişim açıkken çalıştırıyor;
    /// kapalıyken çağrı sessizce hiçbir şey yapmıyor.
    var hapticsEnabled = false {
        didSet { if hapticsEnabled { haptic.prepare() } }
    }
    /// 0 hafif · 1 orta · 2 güçlü.
    var hapticLevel = 0 {
        didSet {
            guard hapticLevel != oldValue else { return }
            haptic = UIImpactFeedbackGenerator(style: HapticLevel.style(hapticLevel))
            if hapticsEnabled { haptic.prepare() }
        }
    }
    private var haptic = UIImpactFeedbackGenerator(style: .light)
    /// İmleç her adım attığında ince bir tık — sistem klavyesindeki gibi.
    let cursorTick = UISelectionFeedbackGenerator()

    /// Basış sesleri (`KeyboardSettings`): `nil` sessiz. Titreşimle aynı
    /// kısıt — uzantıda yalnız Tam Erişimle duyuluyor.
    private var keySounds: (letter: KeySoundChannel, word: KeySoundChannel)? {
        didSet { if keySounds != nil { KeySoundPlayer.shared.prepare() } }
    }

    /// Kelimeyi bitiren tuşlar ayrı kanaldan çalıyor: boşluk, `⏎`, nokta ve
    /// sembol düzlemindeki noktalama.
    private static func endsWord(_ h: KeyHit) -> Bool {
        switch h {
        case .function(.space), .function(.ret), .function(.period): return true
        case let .symbol(ch): return ".,!?;:".contains(ch)
        default: return false
        }
    }

    private func tapFeedback(_ h: KeyHit) {
        if let s = keySounds {
            KeySoundPlayer.shared.play(Self.endsWord(h) ? s.word : s.letter)
        }
        guard hapticsEnabled else { return }
        haptic.impactOccurred(intensity: HapticLevel.intensity(hapticLevel))
        // Bir sonraki basış gecikmesiz gelsin diye motor hazır tutuluyor.
        haptic.prepare()
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
    var keyLabels: [CATextLayer] = []
    var keyFrames: [CGRect] = []
    private var digitBackgrounds: [CALayer] = []
    var digitLabels: [CATextLayer] = []
    var digitFrames: [CGRect] = []
    private var functionBackgrounds: [FunctionKey: CALayer] = [:]
    var functionLabels: [FunctionKey: CATextLayer] = [:]
    var functionFrames: [(FunctionKey, CGRect)] = []

    /// Parmak → o parmağın şu anki hedefi. Rollover için parmak başına izlenir.
    var activeTouches: [ObjectIdentifier: KeyHit] = [:]
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
    let repeatHold = TouchHold()
    var repeatKey: KeyHit?
    var repeatTicks = 0
    /// Tekrar üretmiş parmaklar. Tek bir sahip alanı yetmiyordu: ikinci
    /// bir parmak sahipliği devraldığında birincinin "tekrar etti" bilgisi
    /// kayboluyor, bırakıldığında fazladan bir silme commit ediliyordu.
    var repeatedTouches: Set<ObjectIdentifier> = []

    init(layout: KeyLayout, metrics: KeyboardMetrics = .default) {
        self.layout = layout
        self.metrics = metrics
        super.init(frame: .zero)
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(backdropView)
        isMultipleTouchEnabled = true
        buildLayers()
        applyTheme()
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
    var planeKeys: [SymbolPlanes.PlaneKey] { planeData?.keys ?? [] }
    /// Üst sayı sırası — kapalıysa boş. Vuruş çözümü `KeyboardGeometry`'de.
    var numberRow: [SymbolPlanes.PlaneKey] = []

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
            style(bg, face: theme.keyFace)
            layer.addSublayer(bg)
            bgs.append(bg)

            let t = keyTextLayer(color: theme.keyText)
            t.string = title
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
                   .globe, .space, .ret, .period] {
            let bg = CALayer()
            style(bg, face: face(fk))
            layer.addSublayer(bg)
            functionBackgrounds[fk] = bg

            functionLabels[fk] = keyTextLayer(color: text(fk))
        }
    }

    /// Tuş yazısı katmanı — harf, rakam ve işlev tuşları aynı biçim.
    private func keyTextLayer(color: UIColor) -> CATextLayer {
        let t = CATextLayer()
        t.alignmentMode = .center
        if let f = theme.keyFont { t.font = CTFontCopyGraphicsFont(f, nil) }
        t.foregroundColor = color.cgColor
        t.contentsScale = UIScreen.main.scale
        layer.addSublayer(t)
        return t
    }

    /// Görünüm noktasının 0…1 normalize karşılığı (çekirdeğin koordinatı);
    /// boyut yoksa `nil`.
    private func normalized(_ p: CGPoint) -> Point? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return Point(x: Double((p.x - bounds.minX) / bounds.width),
                     y: Double((p.y - bounds.minY) / bounds.height))
    }

    static let spaceDragTitle = "◂ ▸"

    func refreshFunctionTitles() {
        // Kilitli shift ayrı bir simge: kullanıcı kilidin açık olduğunu
        // görmezse neden hep büyük harf yazdığını anlamaz.
        functionLabels[.shift]?.string = isShiftLocked ? "⇪" : "⇧"
        functionLabels[.backspace]?.string = "⌫"
        functionLabels[.numbers]?.string = "123"
        functionLabels[.symbols]?.string = "#+="
        functionLabels[.letters]?.string = "ABC"
        functionLabels[.globe]?.string = "🌐"
        // İmleç kipi açıkken yazı "◂ ▸" kalıyor (yerleşim her geçişte bunu çağırıyor).
        functionLabels[.space]?.string = spaceDragArmed ? Self.spaceDragTitle : (spaceTitle ?? "boşluk")
        functionLabels[.ret]?.string = "⏎"
        // Basılı tutulurken virgül gösteriliyor: uzun basmanın ne üreteceği
        // ancak parmak kalkınca görülseydi, kullanıcı virgülü keşfetmek için
        // her seferinde bir nokta yazmayı göze almak zorunda kalırdı.
        functionLabels[.period]?.string = periodShowsAlternate ? "," : "."
    }

    /// Tema değişimi: katman renkleri `cgColor` olduğu için tek tek yazılmalı.
    func applyTheme() {
        backgroundColor = drawsBackdrop ? theme.background : .clear
        backdropView.apply(theme)
        CATransaction.beginWithoutActions()
        for l in keyBackgrounds + digitBackgrounds { style(l, face: theme.keyFace) }
        for t in keyLabels + digitLabels { t.foregroundColor = theme.keyText.cgColor }
        for (fk, l) in functionBackgrounds { style(l, face: face(fk)) }
        for (fk, t) in functionLabels { t.foregroundColor = text(fk).cgColor }
        // Tuş yazı tipi (tema düzenleyici, tasarım 25). `nil` katmanın
        // varsayılanına döndürüyor. CGFont veriliyor: sistem tasarımları
        // (yuvarlak, New York) CTFont olarak katmanda yok sayılabiliyor.
        //
        // `nil` atamak **yanlıştı**: katman varsayılanı boş değer değil, ve
        // boş atanınca işlev tuşlarının yazısı (⇧ ⌫ 123 boşluk) küçülüyordu.
        // Tema yazı tipi yoksa katmanın kendi varsayılanına dönülüyor.
        let keyFont: CFTypeRef? = theme.keyFont.map { CTFontCopyGraphicsFont($0, nil) } ?? Self.defaultLayerFont
        for t in keyLabels + digitLabels + Array(functionLabels.values) { t.font = keyFont }
        CATransaction.commit()
        setNeedsLayout()   // vurgular `layoutSubviews` sonunda geri geliyor
    }

    /// Boşluk harf tuşu renginde (Apple'daki gibi büyük, sakin bir yüzey),
    /// `⏎` temanın vurgu renginde; diğer işlev tuşları kendi renginde.
    func face(_ fk: FunctionKey) -> UIColor {
        switch fk {
        case .space: return theme.keyFace
        case .ret:   return theme.returnFace
        default:     return theme.functionFace
        }
    }

    func text(_ fk: FunctionKey) -> UIColor {
        switch fk {
        case .space: return theme.keyText
        case .ret:   return theme.returnText
        default:     return theme.functionText
        }
    }

    /// Tuş zemininin temaya bağlı biçimi — renk dışında her şey.
    ///
    /// Gölge `shadowPath` ile çiziliyor (`layoutSubviews`): yolsuz gölge her
    /// karede katmanın alfa kanalından hesaplanıyor ve 40 tuşta yazma yolunu
    /// yavaşlatırdı.
    func style(_ l: CALayer, face: UIColor) {
        l.backgroundColor = face.cgColor
        l.cornerRadius = theme.cornerRadius
        l.borderWidth = theme.keyBorder == nil ? 0 : 1
        l.borderColor = theme.keyBorder?.cgColor
        l.shadowOpacity = theme.keyShadow ? 0.30 : 0
        l.shadowColor = UIColor.black.cgColor
        l.shadowOffset = CGSize(width: 0, height: 1)
        l.shadowRadius = 0
    }

    private func setFrame(_ l: CALayer, _ r: CGRect) {
        l.frame = r
        l.shadowPath = theme.keyShadow
            ? UIBezierPath(roundedRect: l.bounds, cornerRadius: theme.cornerRadius).cgPath
            : nil
    }

    /// Türkçe büyük harf: `i → İ`, `ı → I`. Locale'siz `uppercased()` ikisini
    /// birbirine karıştırır.
    func letterTitle(_ ch: Character) -> String {
        let s = isUppercase ? String(ch).trUppercased : String(ch)
        return letterTransform?(s) ?? s
    }

    /// `CATextLayer`'ın kendi varsayılan yazı tipi (tema yazı tipi yokken).
    private static let defaultLayerFont: CFTypeRef? = CATextLayer().font

    /// Fontlu yazı açıkken tuşların üstündeki harfler de o stilde (tasarım 24).
    var letterTransform: ((String) -> String)? {
        didSet { refreshLetterLabels(); refreshFunctionTitles() }
    }
    /// Boşluk tuşunun yazısı — fontlu yazıda stilin adı.
    var spaceTitle: String? {
        didSet { if spaceTitle != oldValue { refreshFunctionTitles() } }
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
        // Düşürülen parmaklar kayda `.cancelled` olarak girebilsin diye
        // saklanıyor: doğrudan `removeAll` etmek onları bırakışta
        // "klavye dışına kaydı" (`leftBounds`) diye kaydettiriyordu.
        suppress(Array(activeTouches.keys))
        abandonHolds()
        cancelSpaceDrag()
    }

    /// Basılı tutma sayaçları ve tekrar/virgül işaretleri bırakılıyor — bütün
    /// dokunmalar iptal edilirken de imleç kipi açılırken de aynı adımlar.
    func abandonHolds() {
        repeatedTouches.removeAll()
        alternateTouches.removeAll()
        globeTouchStart.removeAll()
        cancelRepeat()
        cancelPeriodLongPress()
    }

    private func rebuildForPlane() {
        cancelAllTouches()
        buildLayers()
        announceSurfaceChange()
    }

    private func refreshLetterLabels() {
        guard plane == .letters else { return }
        CATransaction.beginWithoutActions()
        for (i, key) in layout.keys.enumerated() where i < keyLabels.count {
            keyLabels[i].string = letterTitle(key.char)
        }
        CATransaction.commit()
        // Harflerin **görünen** hâli değişti; erişilebilirlik etiketleri de
        // ondan üretiliyor. `setNeedsLayout` çağırmak bütün çerçeveleri yeniden
        // hesaplatırdı — değişen tek şey etiketler.
        //
        // Burada `announceSurfaceChange` **yok**, düzlem değişiminde var.
        // Tek seferlik shift her harften sonra düşüyor: bildirim atmak
        // VoiceOver odağını yazarken sürekli kesmek olurdu. Yeni etiket zaten
        // bir sonraki keşifte okunuyor — yüzey değişmedi, yalnız yazısı.
        invalidateAccessibilityElements()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.beginWithoutActions()
        defer { CATransaction.commit() }

        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        // **Görünen** boşluk — dokunma alanı değil. Vuruş testi tam yuvayı
        // kullanıyor (harfte en yakın merkez, işlevde yuva çerçevesi), yani
        // aralığı büyütmek tuşlar arasında ölü şerit açmıyor.
        //
        // 2 pt'ken (aralık 4 pt) klavye "duvar gibi" görünüyordu ve kullanıcı
        // hedef seçmekte zorlandığını söyledi. Apple ve AOSP yatayda ~6,
        // dikeyde ~12 pt aralık kullanıyor. Sayı sırası açıkken dikey aralık
        // daralıyor — 5 satırda tuşu değil boşluğu küçültmek (AOSP'nin
        // `key_vertical_gap_5row`'u).
        let insetX: CGFloat = 3
        let insetY: CGFloat = metrics.showsNumberRow ? 4 : 5.5

        refreshFunctionTitles()

        func rect(center: Point, w: Double, h: Double) -> CGRect {
            let kw = w * W, kh = h * H
            return CGRect(x: center.x * W - kw / 2, y: center.y * H - kh / 2,
                          width: kw, height: kh)
        }

        func placeKey(_ i: Int, _ r: CGRect, _ bgs: [CALayer], _ texts: [CATextLayer]) {
            guard i < bgs.count else { return }
            setFrame(bgs[i], r.insetBy(dx: insetX, dy: insetY))
            place(texts[i], in: r, fontSize: min(r.height * 0.5, 25))
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
            setFrame(bg, f.insetBy(dx: insetX, dy: insetY))
            paintFunction(fk, pressed: false)
            if let t = functionLabels[fk] {
                // Simge tuşları (⇧ ⌫ ⏎ .) yazılı tuşlardan büyük: 15 pt'lik bir
                // `⇧` tuşun ortasında nokta gibi kalıyor, tasarımda belirgindi.
                let glyph: Bool = [.shift, .backspace, .ret, .period].contains(fk)
                place(t, in: f, fontSize: glyph ? min(f.height * 0.46, 23)
                                                : min(f.height * 0.30, 15))
            }
        }

        // Aktif vurgular **en sonda** geri uygulanıyor.
        //
        // İşlev tuşlarının rengi yukarıda temel/kilitli renge sıfırlanıyor;
        // trait ya da tema değişimi basılı bir `⇧`/`⌫`/boşluk sırasında
        // gelirse vurgu kayboluyordu. Harflerde sıfırlama olmadığı için iki
        // tuş sınıfı farklı davranıyordu — şimdi ikisi de aynı.
        for (_, h) in activeTouches { setPressed(h, true) }

        invalidateAccessibilityElements()
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
        case .period:      return .period
        }
    }

    /// `CATextLayer` metni üstten hizalar; tek geçişte dikeyde ortalar.
    func place(_ t: CATextLayer, in r: CGRect, fontSize: CGFloat) {
        t.fontSize = fontSize
        let lineHeight = fontSize * 1.2
        t.frame = CGRect(x: r.minX, y: r.midY - lineHeight / 2, width: r.width, height: lineHeight)
    }

    /// Erişilebilirlik etkinleştirmesi karakter üretsin mi.
    ///
    /// Kayıt ekranı bunu kapatıyor: orada amaç **gerçek yazım davranışını**
    /// ölçmek ve türetilmiş bir dokunmayı ölçüme sokmak kaydı sessizce
    /// yalanlardı (§12.7 — kayıt olgu yazar, çıkarım değil). Tuşlar okunmaya
    /// devam ediyor; yalnız çift dokunuş bir şey yazmıyor.
    var allowsAccessibilityActivation = true

    // MARK: - Dokunma

    /// Öncelik sırası (sayı sırası → işlev → içerik) **çekirdekte**; burada
    /// yalnız yüzeyin o düzlemdeki karşılığı bulunuyor.
    func hit(at p: CGPoint) -> KeyHit? {
        guard let norm = normalized(p) else { return nil }

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
            // İmleç kipi açıkken **yeni parmak kabul edilmiyor**: jest sabit
            // bir bağlama göre hesaplıyor ve araya giren bir commit onu
            // geçersiz kılardı (`armSpaceDrag`). Dokunma kayda giriyor —
            // olmuş bir olay — ama `activeTouches`'a girmediği için bıraktığında
            // hiçbir şey yazmıyor.
            guard !spaceDragArmed else { continue }
            guard let h = h0 else { continue }
            let id = ObjectIdentifier(t)
            activeTouches[id] = h
            setPressed(h, true)
            tapFeedback(h)
            startHolds(h, id: id, at: t.location(in: self))
            if Self.repeats(h) { startRepeat(h, id: id) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let old = activeTouches[id] else { continue }

            // **İmleç kipi tuş değiştirmeyi devralıyor.**
            //
            // Normal yolda parmak kaydıkça altındaki tuş yeniden çözülüyor;
            // burada o davranış tam olarak yanlış olurdu — kullanıcı boşluktan
            // çıkıp `⏎`'nin üstüne geldiğinde satır sonu değil imleç hareketi
            // bekliyor. Jest parmağı bırakana kadar sahipleniyor.
            // Boşlukta **yana kaydırmak** beklemeden imleç kipini açıyor
            // (Gboard). Basılı tutma yolu da duruyor.
            if !spaceDragArmed, spaceDragHold.owner == id,
               abs(t.location(in: self).x - spaceDragOrigin.x) >= Self.spaceSlideToArm {
                armSpaceDrag()
                // Kaydırarak açılan kip zaten "boşluk değil" demek.
                alternateTouches.insert(id)
            }
            if spaceDragArmed, spaceDragHold.owner == id {
                let p = t.location(in: self)
                let moved = onSpaceDragChanged?(p.x - spaceDragOrigin.x,
                                                p.y - spaceDragOrigin.y, t.timestamp) ?? 0
                if moved != 0 {
                    // Hareket oldu: bırakışta boşluk **yazılmamalı**.
                    alternateTouches.insert(id)
                    if hapticsEnabled { cursorTick.selectionChanged(); cursorTick.prepare() }
                }
                continue
            }

            let new = hit(at: t.location(in: self))
            if new != old {
                record(t, .moved, hit: new, outcome: .pending)
                setPressed(old, false)
                // Parmak tuştan kaydıysa tekrar durur — sürükleyip başka bir
                // yerde bırakmak silmeye devam etmemeli.
                if repeatHold.owner == id { cancelRepeat() }
                // Globe'dan kayan parmak uzun basma sayacını da bırakır.
                if case .function(.globe) = old { globeTouchStart.removeValue(forKey: id) }
                // Noktadan kayan parmak virgülü de bırakır — etiket `.`'ya
                // döner. Kaymadan sonra basılan tuş virgül üretmemeli.
                if periodHold.owner == id { cancelPeriodLongPress() }
                // Boşluktan **kip açılmadan** kayan parmak da bırakır: eşiği
                // beklerken başka tuşa geçmek jesti iptal ediyor.
                if spaceDragHold.owner == id { cancelSpaceDrag() }
                if let new {
                    activeTouches[id] = new
                    setPressed(new, true)
                    startHolds(new, id: id, at: t.location(in: self))
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
            // Virgül zaten yazıldıysa bırakışta nokta **yazılmaz**. Aynı
            // gerekçeyle `repeatedTouches` guard'dan önce okunuyor.
            let didAlternate = alternateTouches.remove(id) != nil
            // Devralmadan ÖNCE bu parmak listeden düşmeli, yoksa kalkan parmak
            // sahipliği kendine devreder.
            let ended = activeTouches.removeValue(forKey: id)
            endHolds(id)

            guard let h = ended else {
                // Klavyenin kendi kararıyla düşürdüğü parmak: hangi tuşun
                // üstünde olduğu **biliniyor** ve olan şey bir iptal.
                if let dropped = suppressedTouches.removeValue(forKey: id) {
                    record(t, .ended, hit: dropped, outcome: .cancelled)
                    continue
                }
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
            // Virgül `.committed` yazılıyor, `.repeated` değil: olan şey bir
            // tekrar değil, bu tuşun **ikinci karakteri**. Hangi karakterin
            // yazıldığı komut akışında duruyor (`ReplayCommand.symbol`).
            record(t, .ended, hit: h, outcome: didRepeat ? .repeated : .committed)
            if !didRepeat, !didAlternate { onKeyCommit?(h, .touch) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // İptal: vurgu kalkar, **hiçbir karakter üretilmez**.
        for t in touches {
            let id = ObjectIdentifier(t)
            // Zaten düşürülmüş parmağın sistem iptali de aynı olguyu anlatıyor;
            // sözlükten çıkması yeter (kayıt aşağıda `.cancelled` yazıyor).
            let h = activeTouches.removeValue(forKey: id)
                ?? suppressedTouches.removeValue(forKey: id)
            if let h { setPressed(h, false) }
            repeatedTouches.remove(id)
            alternateTouches.remove(id)
            globeTouchStart.removeValue(forKey: id)
            endHolds(id)
            record(t, .cancelled, hit: h, outcome: .cancelled)
        }
    }

    /// Basılı tutmayla çalışan tuşların sayaçları — basışta ve parmak başka
    /// tuşa kaydığında aynı.
    private func startHolds(_ h: KeyHit, id: ObjectIdentifier, at p: CGPoint) {
        if case .function(.globe) = h { globeTouchStart[id] = Date() }
        if case .function(.period) = h { startPeriodLongPress(id) }
        if case .function(.space) = h { startSpaceDrag(id, at: p) }
    }

    /// Parmak kalktı ya da iptal: o parmağın tekrarı, virgülü, imleç jesti biter;
    /// başka parmak tekrar bekliyorsa devralır.
    private func endHolds(_ id: ObjectIdentifier) {
        if repeatHold.owner == id { cancelRepeat(); adoptPendingRepeat() }
        if periodHold.owner == id { cancelPeriodLongPress() }
        if spaceDragHold.owner == id { cancelSpaceDrag() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Klavye kaybolurken ne çalışan bir zamanlayıcı ne de yarım bir dokunma
        // kalmalı.
        //
        // Burası uzun süre **parçalı** temizliyordu: zamanlayıcılar duruyordu
        // ama `activeTouches`, basılı vurgular ve `globeTouchStart` yerinde
        // kalıyordu. Görünüm yeniden pencereye girerse o dokunmalara artık
        // `ended`/`cancelled` gelmiyor — sızmış durum. `cancelAllTouches`
        // hepsini birden karşılıyor ve yeni bir temizleme listesi tutmak
        // zorunda kalmıyoruz (unutulan alan = sızıntı).
        //
        // `suppressedTouches` burada **temizleniyor**: normalde parmak
        // bırakılınca sözlükten düşüyor, ama pencereden çıkarken o `ended`
        // hiç gelmeyebilir ve kayıt kimliği ölü girdilerle şişerdi.
        if newWindow == nil {
            cancelAllTouches()
            suppressedTouches.removeAll()
        }
    }

    /// Uzun basma **tek atışlık**; tekrar zamanlayıcısı kullanılmadı.
    ///
    /// İkisi farklı davranışlar: `⌫` tekrarı bir *süre* işlemi (ne kadar
    /// tutarsan o kadar sil) ve tik başına yeniden zamanlanıyor. Virgül tek bir
    /// karakter — aynı mekanizmaya bağlansaydı parmak kalkana kadar virgül
    /// yağardı. `Self.repeats(_:)`'e nokta eklemek bu yüzden yanlış olurdu.
    ///
    /// Eşik `cadence.initialDelay`'den geliyor: kullanıcının "basılı tutma"
    /// diye öğrendiği süre `⌫`'de ne ise burada da o olmalı, ve ayarlanabilir
    /// olması bu tuşta da ücretsiz.
    let periodHold = TouchHold()
    /// Etiket `.` yerine `,` gösteriyor mu — `refreshFunctionTitles` okuyor.
    var periodShowsAlternate = false
    /// Uzun basmayla virgül üretmiş parmaklar.
    ///
    /// `repeatedTouches` ile aynı işi görüyor (bırakışta commit'i bastır) ama
    /// ayrı tutuluyor: o küme kayda `.repeated` yazdırıyor ve virgül bir tekrar
    /// değil, **commit**. Tek küme kullanmak kaydı yalanlardı (§12.6.1).
    var alternateTouches: Set<ObjectIdentifier> = []
    /// Sürükleme **basılı tutmanın ardından** açılıyor, hemen değil.
    ///
    /// Eşiksiz açmak (parmak boşlukta biraz kayınca doğrudan imleç kipi) daha
    /// akıcı görünüyor ama boşluğa basıp parmağı hafifçe kaydıran herkesin
    /// imlecini oynatırdı — ve boşluk klavyenin en çok basılan tuşu. Eşik
    /// `⌫` ve nokta ile aynı (`cadence.initialDelay`): kullanıcının "basılı
    /// tutma" diye öğrendiği tek bir süre var.
    let spaceDragHold = TouchHold()
    var spaceDragOrigin: CGPoint = .zero
    /// Kip açıldı — `touchesMoved` artık tuş değiştirmiyor.
    var spaceDragArmed = false
    static let spaceHoldToArm: TimeInterval = CursorTrackpad.Arming.holdDuration
    /// Boşlukta bu kadar yana kayınca kip beklemeden açılıyor (`CursorTrackpad.Arming`).
    private static let spaceSlideToArm = CGFloat(CursorTrackpad.Arming.slideDistance)
    func setPressed(_ h: KeyHit, _ pressed: Bool) {
        CATransaction.beginWithoutActions()   // örtük CoreAnimation animasyonu istemiyoruz
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
            paintFunction(fk, pressed: pressed)
        }
        CATransaction.commit()
    }

    /// İşlev tuşu rengi. Kilitli shift basılı değilken de vurgulu kalıyor.
    private func paintFunction(_ fk: FunctionKey, pressed: Bool) {
        let on = pressed || (fk == .shift && isShiftLocked)
        functionBackgrounds[fk]?.backgroundColor = (on ? theme.pressedFace : face(fk)).cgColor
        functionLabels[fk]?.foregroundColor = (on ? theme.pressedText : text(fk)).cgColor
    }

    private func paint(_ i: Int, in bgs: [CALayer], _ texts: [CATextLayer], pressed: Bool) {
        guard i < bgs.count else { return }
        bgs[i].backgroundColor = (pressed ? theme.pressedFace : theme.keyFace).cgColor
        texts[i].foregroundColor = (pressed ? theme.pressedText : theme.keyText).cgColor
    }
}

extension KeyboardView {
    /// Bir satır birimi kaç nokta — klavye, tezgah, kayıt ve önizleme aynı ölçü.
    static let rowHeightPoints: CGFloat = 54
    static func height(for metrics: KeyboardMetrics) -> CGFloat { rowHeightPoints * CGFloat(metrics.heightUnits) }

    /// Ayarların klavyeye uygulanan kısmı (ses, titreşim, tekrar zamanlaması).
    func apply(_ s: KeyboardSettings) {
        if cadence != s.cadence { cadence = s.cadence }
        hapticsEnabled = s.haptics
        hapticLevel = s.hapticLevel
        keySounds = s.soundEnabled ? (s.letterSound, s.wordSound) : nil
    }
}
