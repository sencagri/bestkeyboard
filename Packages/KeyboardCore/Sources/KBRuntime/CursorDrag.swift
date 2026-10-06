import Foundation

/// Boşluk tuşunda imleç sürükleme — **saf mantık**.
///
/// ## Neden çekirdekte
///
/// Jestin tamamı iki karardan ibaret: *hangi eksen* ve *kaç adım*. İkisi de
/// metin ve mesafe aritmetiği, UIKit'e ait hiçbir şey yok. `KeyboardView`'da
/// yazılsaydı `swift test` altında koşamazdı ve kelime sınırı hesabı —
/// asıl kırılgan kısım — yalnız cihazda denenerek doğrulanabilirdi.
///
/// UIKit tarafında kalan tek şey: parmağın nereye gittiğini ölçmek ve sonucu
/// `UITextDocumentProxy.adjustTextPosition`'a vermek.

// MARK: - Kelime sınırları

/// İmlecin etrafındaki metinden **karakter ofsetleri** hesaplar.
///
/// ## Kelime tanımı
///
/// Kelime = boşluk olmayan karakterlerin maksimal dizisi. Noktalama kelimeye
/// **dahil**: `kalem.` tek bir kelime.
///
/// Alternatif (noktalamayı ayırmak) daha "doğru" görünüyor ama kullanıcının
/// beklediği şey değil — `kalem.` üzerinde bir kelime geri giden bir imlecin
/// noktadan önce durması, iki basışta geçilen bir engel demek. Sistem
/// klavyesi de böyle davranıyor ve buradaki jest onun kas hafızasını
/// kullanıyor.
///
/// ## Ofsetler imlece göre
///
/// Hepsi imlecin bulunduğu yerden **işaretli** ofset: negatif = geriye.
/// `adjustTextPosition(byCharacterOffset:)` tam da bu birimi istiyor.
///
/// ## Bağlam kırpılabilir
///
/// `documentContextBeforeInput` host'un verdiği kadarını veriyor — çoğu
/// host'ta yalnız içinde bulunulan paragraf. Bu bir kusur değil sınır:
/// verilenin dışına çıkan bir ofset üretmiyoruz, dolayısıyla en kötü ihtimalle
/// jest paragraf başında **duruyor**. Yanlış yere gitmiyor.
public enum WordBoundaries {

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.isNewline
    }

    /// Ofsetlerin birimi: **UTF-16 kod birimi**, grapheme değil.
    ///
    /// `adjustTextPosition(byCharacterOffset:)` `UITextInput` konumlarına
    /// dayanıyor ve o katmanın tamamı `NSString` semantiği, yani UTF-16.
    /// Kelime sınırını grapheme üzerinde bulup ofseti grapheme sayarak vermek
    /// emoji ve birleşik aksan içeren metinde imleci **kelimenin ortasına**
    /// düşürürdü: `👨‍👩‍👧` tek `Character` ama 8 UTF-16 birimi.
    ///
    /// Sınır tespiti yine grapheme üzerinde — kelime "karakter" kavramıyla
    /// tanımlı ve bir emoji'nin yarısında kelime bitmiyor. Ölçüm ile tespit
    /// farklı birimlerde ve bu bilinçli.
    ///
    /// **Cihazda doğrulanmalı**: host'ların `UITextInput` uygulamaları
    /// teoride grapheme tabanlı olabilir. Türkçe düz metinde iki birim
    /// birebir aynı, fark yalnız emoji/ZWJ dizilerinde ortaya çıkıyor.
    private static func units(_ s: Substring) -> Int { s.utf16.count }

    /// Bir kelime **geriye**: negatif ofset.
    ///
    /// Önce boşluklar, sonra kelime atlanıyor. Bu sıra "kelimenin ortasındaysan
    /// kelimenin başına, başındaysan önceki kelimenin başına" davranışını
    /// kendiliğinden veriyor — ayrı bir "ortada mıyım" kontrolü gerekmiyor.
    public static func toPreviousWordStart(before: String) -> Int {
        var i = before.endIndex
        while i > before.startIndex {
            let p = before.index(before: i)
            guard isSeparator(before[p]) else { break }
            i = p
        }
        while i > before.startIndex {
            let p = before.index(before: i)
            guard !isSeparator(before[p]) else { break }
            i = p
        }
        return -units(before[i...])
    }

    /// Bir kelime **ileriye**: pozitif ofset.
    ///
    /// Simetrik değil ve olmamalı: ileri giderken önce kelimenin kalanı, sonra
    /// boşluklar atlanıyor, yani imleç bir **sonraki kelimenin başında**
    /// duruyor. Geriye giderken de kelime başında duruluyor — iki yön aynı tür
    /// konumu hedefliyor, ki tekrarlanan basışlar aynı yerlere uğrasın.
    public static func toNextWordStart(after: String) -> Int {
        var i = after.startIndex
        while i < after.endIndex, !isSeparator(after[i]) {
            i = after.index(after: i)
        }
        while i < after.endIndex, isSeparator(after[i]) {
            i = after.index(after: i)
        }
        return units(after[..<i])
    }

    /// `count` kelime **geriye**: negatif ofset.
    ///
    /// ## Neden tek çağrıda birden çok kelime
    ///
    /// Adımları tek tek uygulayıp her seferinde host'a bağlam sormak doğru
    /// görünüyor ama değil: `adjustTextPosition` proxy'yi **anında**
    /// güncellemiyor ve aynı tur içinde okunan `documentContextBeforeInput`
    /// hâlâ eski konumu anlatabiliyor. İkinci adım o zaman yanlış yerden
    /// hesaplanır.
    ///
    /// Tek bir bağlam okumasından `count` kelimelik ofseti hesaplamak bu
    /// yarışı tamamen ortadan kaldırıyor: kare başına **bir** okuma, **bir**
    /// mutasyon.
    public static func toPreviousWordStart(before: String, count: Int) -> Int {
        var i = before.endIndex
        for _ in 0..<max(0, count) {
            let mark = i
            while i > before.startIndex, isSeparator(before[before.index(before: i)]) {
                i = before.index(before: i)
            }
            while i > before.startIndex, !isSeparator(before[before.index(before: i)]) {
                i = before.index(before: i)
            }
            // Bağlamın başına dayanıldı: kalan adımlar **sessizce yutuluyor**.
            // Ofset her hâlde okunan pencerenin dışına çıkmıyor.
            if i == mark { break }
        }
        return -units(before[i...])
    }

    /// `count` kelime **ileriye**: pozitif ofset.
    public static func toNextWordStart(after: String, count: Int) -> Int {
        var i = after.startIndex
        for _ in 0..<max(0, count) {
            let mark = i
            while i < after.endIndex, !isSeparator(after[i]) { i = after.index(after: i) }
            while i < after.endIndex, isSeparator(after[i]) { i = after.index(after: i) }
            if i == mark { break }
        }
        return units(after[..<i])
    }

    /// İmlecin **içinde bulunduğu** kelimenin sınırları, imlece göre.
    ///
    /// İmleç boşluktaysa ikisi de `0`: dolaşılacak bir kelime yok ve dikey
    /// eksen o jestte hiçbir şey yapmıyor. Sessizce en yakın kelimeye atlamak
    /// da mümkündü — yapılmadı, çünkü kullanıcı parmağını kaldırmadan hangi
    /// kelimeye "girdiğini" göremez ve yanlış kelimede karakter karakter
    /// dolaşmak, jestin engellemek için var olduğu şey.
    public static func currentWord(before: String, after: String) -> (start: Int, end: Int) {
        var i = before.endIndex
        while i > before.startIndex {
            let p = before.index(before: i)
            guard !isSeparator(before[p]) else { break }
            i = p
        }
        var j = after.startIndex
        while j < after.endIndex, !isSeparator(after[j]) { j = after.index(after: j) }
        return (-units(before[i...]), units(after[..<j]))
    }
}

// MARK: - Jest durum makinesi

/// Boşluk sürüklemesinin durumu: eksen kilidi + kaç adım gidildiği.
///
/// ## Neden mutlak, artımlı değil
///
/// Hedef parmağın **başlangıçtan** toplam ötelenmesinden hesaplanıyor, kareler
/// arası farktan değil. Artımlı toplamada yuvarlama artıkları birikir ve
/// kullanıcı parmağını geri getirdiğinde imleç başladığı yere dönmez — jestin
/// en çok güven isteyen kısmı tam da geri dönebilmek.
///
/// Aynı sebep hedefin **mutlak** bildirilmesini de gerektiriyor: yakalanmış
/// bağlam kırpılmış olabiliyor (belgenin başına dayanmak) ve istenen kelime
/// sayısı oraya sığmayabiliyor. Mutlak hedefte bu kendiliğinden düzeliyor —
/// her kare "nerede olmalıyım" sorusunu yeniden cevaplıyor, çağıran farkı
/// alıyor ve birikim olmuyor.
///
/// **Host'un geçerli bir ofseti kısmen uygulaması ayrı bir şey ve burada
/// yönetilmiyor**: `adjustTextPosition` sonuç döndürmüyor, dolayısıyla ne bu
/// tip ne de çağıran gerçekleşeni görebiliyor. Güvence yalnız yakalanmış
/// bağlamın içinde geçerli.
///
/// ## İmlecin fiilen oynayıp oynamadığını **bilmiyor**
///
/// `didMove` gibi bir alan yok ve olmamalı: hedef üretmek hareket demek değil.
/// Belgenin başında bir kelime geri istemek geçerli bir hedef ama sıfır
/// karakter hareket eder. Boşluk yazımının bastırılıp bastırılmayacağına
/// yalnız **çağıran** karar verebilir, çünkü gerçekleşen ofseti yalnız o
/// biliyor.
public struct CursorDragGesture {

    /// Kilitlenen eksen.
    public enum Axis: Equatable {
        /// Yatay — **kelime kelime**.
        case horizontal
        /// Dikey — kelimenin **içinde** karakter karakter.
        case vertical
    }

    /// Mesafe eşikleri, nokta cinsinden.
    public struct Metrics: Equatable, Sendable {
        /// Eksen kilidi bu mesafeden sonra kuruluyor.
        ///
        /// Sıfır olamaz: parmak hiç kıpırdamadan da bir kaç noktalık gürültü
        /// üretiyor ve ilk gürültü ekseni kilitlerdi.
        public var axisLock: Double
        /// Bir kelime adımı kaç nokta.
        public var wordStride: Double
        /// Bir karakter adımı kaç nokta.
        ///
        /// Kelimeden **küçük**: dikey eksen ince ayar için var ve aynı mesafeye
        /// daha çok adım sığması gerekiyor.
        public var charStride: Double

        public init(axisLock: Double = 12, wordStride: Double = 26, charStride: Double = 14) {
            self.axisLock = max(1, axisLock)
            self.wordStride = max(1, wordStride)
            self.charStride = max(1, charStride)
        }

        public static let `default` = Metrics()
    }

    public private(set) var axis: Axis?

    private let metrics: Metrics
    /// Dikey eksende dolaşılabilir aralık (jest başında yakalandı).
    private let word: (start: Int, end: Int)

    /// - Parameter word: imlecin içinde bulunduğu kelimenin sınırları.
    ///   Jest **başında** okunuyor ve bir daha okunmuyor: dikey eksen
    ///   kelimeyi değiştirmediği için sınırlar da değişmiyor, ve her adımda
    ///   host'a bağlam sormak hem gereksiz hem de imleç oynarken kırpılmış
    ///   bağlamda kayabilirdi.
    public init(word: (start: Int, end: Int), metrics: Metrics = .default) {
        self.word = word
        self.metrics = metrics
    }

    /// Parmağın **şu anki** yerinin hedefi — jest başlangıcına göre **mutlak**.
    ///
    /// ## Neden adım listesi değil
    ///
    /// İlk tasarım "şunu uygula" diyen bir adım listesi döndürüyordu ve iki
    /// yerden birden yanlıştı:
    ///
    /// 1. Çağıran her adımı uygulamak için host'a imlecin yerini sormak
    ///    zorundaydı; `adjustTextPosition` proxy'yi anında güncellemediği için
    ///    **ardışık karelerde** bayat bağlam okunabiliyordu.
    /// 2. Host isteği kısmen karşılarsa (belgenin başına dayanmak) durum
    ///    makinesi bunu bilmiyordu: `applied` istenen değeri sayıyordu, gerçekte
    ///    olanı değil, ve parmağı geri getirmek başlangıç noktasını aşıyordu.
    ///
    /// Mutlak hedefte ikisi de yok: çağıran "başlangıçtan **N kelime** uzakta
    /// olmalıyım" cevabını alıyor, bunu jest başında bir kez okunmuş bağlamdan
    /// karakter ofsetine çeviriyor ve kendi uyguladığı toplamla farkını
    /// alıyor. Kısmi karşılanma kendiliğinden düzeliyor — bir sonraki kare yine
    /// mutlak hedefi soruyor.
    public enum Target: Equatable {
        /// Jest başındaki imleçten kaç **kelime** uzağa. Negatif = geriye.
        ///
        /// Karaktere çevirme çağıranda: kelime sınırının kaç karakter olduğu
        /// belgeye bağlı ve burada bilinmiyor.
        case words(Int)
        /// Jest başındaki imleçten kaç **karakter** uzağa — kelime sınırlarına
        /// zaten kırpılmış.
        case characters(Int)
    }

    /// En son bildirilen hedef; aynı hedef iki kez döndürülmüyor.
    private var lastTarget: Target?

    /// Parmağın **başlangıçtan** toplam ötelenmesi.
    ///
    /// - Returns: hedef değiştiyse yeni hedef, değişmediyse `nil`. Eksen henüz
    ///   kilitlenmediyse de `nil`.
    public mutating func update(dx: Double, dy: Double) -> Target? {
        if axis == nil {
            let ax = abs(dx), ay = abs(dy)
            guard max(ax, ay) >= metrics.axisLock else { return nil }
            // Beraberlikte yatay kazanıyor: jestin ilan edilen işi kelime
            // kelime gezinmek, dikey eksen onun ince ayarı.
            axis = ax >= ay ? .horizontal : .vertical
        }

        let target: Target
        switch axis {
        case .horizontal:
            target = .words(Int((dx / metrics.wordStride).rounded(.towardZero)))

        case .vertical:
            // Aşağı = kelimenin sonuna doğru. UIKit'te `y` aşağı büyüyor, yani
            // işaret çevirmeye gerek yok.
            //
            // Kırpma **hedefte**, adımda değil: kullanıcı parmağını kelimenin
            // dışına taşırsa imleç sınırda durup bekliyor ve geri gelince
            // oradan devam ediyor. Adımı kırpsaydık sınırın ötesinde harcanan
            // mesafe birikir, parmak geri geldiğinde imleç gecikmeli tepki
            // verirdi.
            let raw = Int((dy / metrics.charStride).rounded(.towardZero))
            target = .characters(min(max(raw, word.start), word.end))

        case nil:
            return nil
        }

        guard target != lastTarget else { return nil }
        lastTarget = target
        return target
    }
}

// MARK: - Jest + belge: uygulanacak ofset

/// Jestin **belgeye** bağlanmış hâli: hedefi karakter ofsetine çeviriyor.
///
/// ## Neden ayrı bir tip
///
/// Bu mantık önce `KeyboardViewController`'daydı ve orada `swift test` altında
/// koşamıyordu — `UIInputViewController` alt sınıfı. Oysa buradaki kararlar
/// jestin en kırılgan kısmı: hangi bağlamın okunduğu, ofsetin nereden
/// hesaplandığı ve boşluk yazımının bastırılıp bastırılmayacağı.
///
/// Controller'da kalan tek iş: `update`'in verdiği ofseti proxy'ye vermek.
///
/// ## Bağlam **bir kez** okunuyor
///
/// `before`/`after` jest başında yakalanıyor ve jest boyunca sabit kalıyor.
/// Her karede host'a sormak doğru görünüyor ve değil: `adjustTextPosition`
/// proxy'yi anında güncellemiyor, bir sonraki kare hâlâ eski konumu anlatan
/// bir bağlam okuyabiliyor ve ofset yanlış yerden hesaplanıyordu.
///
/// Bedeli: bağlam host tarafından kırpılıyor (çoğu host'ta içinde bulunulan
/// paragraf) ve jest o pencerenin dışına çıkamıyor. Sınıra dayanan sürükleme
/// **duruyor** — yanlış yere gitmiyor.
public struct CursorDragSession {

    /// Jest **sıfır olmayan bir ofset istedi** mi.
    ///
    /// ## Ne söylediğine dikkat
    ///
    /// "İmleç oynadı" **demiyor** ve diyemez: `adjustTextPosition` bir sonuç
    /// döndürmüyor ve host'un isteği karşılayıp karşılamadığı gözlemlenemiyor.
    /// Söylediği tam olarak şu: *jest başında okunan bağlam içinde, sıfır
    /// olmayan bir hareket istendi.*
    ///
    /// Boşluk yazımının bastırılması buna bağlı ve doğru olan da bu — kullanıcı
    /// gerçekten sürükledi, boşluk beklemiyor. Belgenin başında bir kelime geri
    /// istemek ise sıfır ofset üretiyor ve o jest boşluk yazmaya devam ediyor.
    public private(set) var didRequestMove = false

    public var axis: CursorDragGesture.Axis? { gesture.axis }

    private var gesture: CursorDragGesture
    private let before: String
    private let after: String
    /// Şimdiye kadar proxy'ye verilmiş net ofset.
    private var applied = 0

    public init(before: String, after: String,
                metrics: CursorDragGesture.Metrics = .default) {
        self.before = before
        self.after = after
        self.gesture = CursorDragGesture(
            word: WordBoundaries.currentWord(before: before, after: after),
            metrics: metrics)
    }

    /// Parmağın **başlangıçtan** toplam ötelenmesi.
    ///
    /// - Returns: proxy'ye verilecek işaretli ofset. `0` = yapılacak bir şey yok.
    public mutating func update(dx: Double, dy: Double) -> Int {
        guard let target = gesture.update(dx: dx, dy: dy) else { return 0 }

        // Hedef **mutlak**: jest başındaki imlece göre. Uygulanacak fark, o
        // hedefin ofset karşılığı eksi şimdiye kadar verdiğimiz toplam.
        let absolute: Int
        switch target {
        case let .words(n) where n < 0:
            absolute = WordBoundaries.toPreviousWordStart(before: before, count: -n)
        case let .words(n) where n > 0:
            absolute = WordBoundaries.toNextWordStart(after: after, count: n)
        case .words:
            absolute = 0
        case let .characters(n):
            absolute = n
        }

        let delta = absolute - applied
        guard delta != 0 else { return 0 }
        applied = absolute
        didRequestMove = true
        return delta
    }
}
