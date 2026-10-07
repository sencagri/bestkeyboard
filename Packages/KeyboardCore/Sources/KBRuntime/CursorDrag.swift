import Foundation
import KBGeometry

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

// MARK: - İzleme yüzeyi (trackpad)

/// Boşlukta imleç sürüklemenin **ikinci nesli** — sistem klavyesinin ve
/// Gboard'ın kas hafızası.
///
/// ## Eski jest neden yetmedi
///
/// Önceki jest (`CursorDragSession`, kaldırıldı) tek bir eksene kilitleniyordu: yatay **kelime kelime**, dikey
/// yalnız içinde bulunulan kelimede karakter karakter. Kullanıcı "sağ sol
/// yukarı aşağı çok kötü" dedi ve haklıydı: yatayda harf harf gidemiyordu,
/// dikey satır değiştirmiyordu, eksen bir kez kilitlenince öbür yön ölüyordu.
///
/// Burada iki eksen **serbest**, bir trackpad gibi:
/// - Yatay: karakter karakter, **ivmeli** — yavaş sürükleme ince ayar, hızlı
///   sürükleme uzun mesafe.
/// - Dikey: satır yukarı / aşağı, sütun korunarak. Satır `\n` ile tanımlı
///   (host sarılmış satırları bildirmiyor); üstte satır yoksa metnin başına,
///   altta yoksa sonuna gidiyor.
///
/// ## Bağlam yine bir kez okunuyor
///
/// `adjustTextPosition` proxy'yi anında
/// güncellemiyor. İmlecin yeri bu tipte, yakalanmış metnin içinde tutuluyor
/// ve proxy'ye yalnız **fark** veriliyor.
public struct CursorTrackpad {

    /// Boşluk tuşunda imleç kipinin açılması: basılı tutma süresi ya da yana
    /// kaydırma mesafesi (sürükleme politikasının geri kalanıyla bir arada).
    public enum Arming {
        /// Eşik **sabit**: ⌫ gecikmesine bağlıyken kullanıcı onu 0,05 sn'ye
        /// indirince her boşluk basışı imleç kipine düşüyordu.
        public static let holdDuration: Double = 0.3
        /// Normal bir basışın titremesinden büyük, bilinçli bir kaydırmadan küçük (nokta).
        public static let slideDistance: Double = 14
    }

    public struct Metrics: Equatable, Sendable {
        /// Yavaş sürüklemede bir karakter kaç nokta.
        public var pointsPerCharacter: Double
        /// Bir satır adımı kaç nokta.
        public var pointsPerLine: Double
        /// Bu hızın (nokta/sn) altında ivme yok.
        public var slowSpeed: Double
        /// Bu hızda ivme tavanda.
        public var fastSpeed: Double
        /// Tavandaki çarpan.
        public var maxGain: Double

        public init(pointsPerCharacter: Double = 9, pointsPerLine: Double = 30,
                    slowSpeed: Double = 180, fastSpeed: Double = 900, maxGain: Double = 3.5) {
            self.pointsPerCharacter = max(1, pointsPerCharacter)
            self.pointsPerLine = max(1, pointsPerLine)
            self.slowSpeed = max(0, slowSpeed)
            self.fastSpeed = max(self.slowSpeed + 1, fastSpeed)
            self.maxGain = max(1, maxGain)
        }

        public static let `default` = Metrics()
    }

    private let metrics: Metrics
    private let chars: [Character]
    /// `utf16Prefix[i]` = ilk `i` karakterin UTF-16 uzunluğu.
    private let utf16Prefix: [Int]
    private let origin: Int
    /// İmlecin yakalanmış metindeki yeri (karakter indeksi).
    public private(set) var position: Int
    private var applied = 0
    private var xCarry = 0.0
    private var yCarry = 0.0
    private var last: (x: Double, y: Double, t: Double)?
    /// Dikeyde satır değişince yatay "istenen sütun" korunuyor.
    private var preferredColumn: Int?

    public init(before: String, after: String, metrics: Metrics = .default) {
        self.metrics = metrics
        let b = Array(before), a = Array(after)
        chars = b + a
        var prefix = [0]
        prefix.reserveCapacity(chars.count + 1)
        for c in chars { prefix.append(prefix.last! + c.utf16.count) }
        utf16Prefix = prefix
        origin = b.count
        position = b.count
    }

    /// Parmağın **başlangıçtan** toplam ötelenmesi ve olay zamanı (saniye).
    ///
    /// - Returns: proxy'ye verilecek işaretli UTF-16 ofseti. `0` = hareket yok.
    public mutating func update(dx: Double, dy: Double, time: Double) -> Int {
        defer { last = (dx, dy, time) }
        guard let prev = last else { return 0 }
        let ddx = dx - prev.x, ddy = dy - prev.y
        let dt = max(time - prev.t, 1.0 / 240)

        // Yatay: ivmeli karakter adımı.
        let speed = abs(ddx) / dt
        let k = ((speed - metrics.slowSpeed) / (metrics.fastSpeed - metrics.slowSpeed))
            .clamped(to: 0...1)
        let gain = 1 + k * (metrics.maxGain - 1)
        xCarry += ddx * gain / metrics.pointsPerCharacter
        let steps = Int(xCarry.rounded(.towardZero))
        if steps != 0 {
            xCarry -= Double(steps)
            position = (position + steps).clamped(to: 0...chars.count)
            preferredColumn = nil
        }

        // Dikey: yalnız baskınken birikiyor. Yatay sürüklerken parmağın doğal
        // eğimi satır atlatmamalı.
        if abs(ddy) > abs(ddx) { yCarry += ddy }
        while yCarry <= -metrics.pointsPerLine { yCarry += metrics.pointsPerLine; moveLine(-1) }
        while yCarry >= metrics.pointsPerLine { yCarry -= metrics.pointsPerLine; moveLine(1) }

        let target = utf16Prefix[position] - utf16Prefix[origin]
        let delta = target - applied
        applied = target
        return delta
    }

    private func lineStart(_ p: Int) -> Int {
        var i = p
        while i > 0, chars[i - 1] != "\n" { i -= 1 }
        return i
    }

    private func lineEnd(_ p: Int) -> Int {
        var i = p
        while i < chars.count, chars[i] != "\n" { i += 1 }
        return i
    }

    private mutating func moveLine(_ dir: Int) {
        let start = lineStart(position)
        let column = preferredColumn ?? (position - start)
        preferredColumn = column
        if dir < 0 {
            guard start > 0 else { position = 0; return }
            let prevStart = lineStart(start - 1)
            position = min(prevStart + column, start - 1)
        } else {
            let end = lineEnd(position)
            guard end < chars.count else { position = chars.count; return }
            let nextStart = end + 1
            position = min(nextStart + column, lineEnd(nextStart))
        }
    }
}
