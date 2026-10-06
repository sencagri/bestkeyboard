import Foundation

/// Klavye yüzeyinin **tek** geometri kaynağı.
///
/// ## Neden UIKit'te değil
///
/// İşlev tuşlarının çerçeveleri eskiden `KeyboardView.layoutSubviews` içinde,
/// harf tuşlarının merkezleri ise `TurkishQ.layout()` içinde hesaplanıyordu.
/// İki hesap birbirini görmediği için tutarsızlaştılar: 3. satır `1.5 + 9×1 +
/// 1.5 = 12` birim yer istiyordu, oysa satır 11 birim. Fark `z` ve `ç`'nin
/// üstüne binen işlev tuşları olarak göründü — ve dokunma testi işlev tuşlarına
/// öncelik verdiği için o harflerin yarısı **basılamıyordu**.
///
/// Buradaki hesabın tamamı saf Swift; `swift test` altında koşuyor ve
/// çakışmama invariantı test edilebiliyor (`LayoutGeometryTests`).
public enum KeyboardGeometry {

    /// Üst sayı sırasının karakterleri. Rakam düzleminin 1. satırıyla aynı
    /// olması bilinçli: kullanıcı `123`'e geçtiğinde aradığı rakamı aynı
    /// yatay konumda buluyor.
    public static let numberRowChars: [Character] = SymbolPlanes.numbersRow1

    /// **Harf/rakam** satırlarının normalize yüksekliği.
    ///
    /// Satırlar artık tekdüze değil: alt satır `bottomRowScale` katı.
    /// Normalize uzay [0,1]'e sabit olduğu için alt satır uzayınca harf
    /// satırları normalize olarak *kısalıyor* — fiziksel yükseklikleri aynı
    /// kalıyor, klavyenin kendisi büyüyor (`KeyboardMetrics.heightUnits`).
    public static func rowHeight(_ m: KeyboardMetrics) -> Double {
        1.0 / m.heightUnits
    }

    /// İşlev (boşluk) satırının normalize yüksekliği.
    public static func bottomRowHeight(_ m: KeyboardMetrics) -> Double {
        rowHeight(m) * m.bottomRowScale
    }

    /// Harf satırlarının başladığı satır indeksi — sayı sırası açıksa 1.
    public static func firstLetterRow(_ m: KeyboardMetrics) -> Int {
        m.showsNumberRow ? 1 : 0
    }

    /// İçerik satırlarının (harf ya da sembol, 3 satır) kapladığı `y` bandı.
    /// Dokunma testi harfe düşmeden önce bu bandı kontrol eder.
    public static func contentBand(_ m: KeyboardMetrics) -> Range<Double> {
        let h = rowHeight(m)
        let top = Double(firstLetterRow(m)) * h
        return top..<(top + 3 * h)
    }

    /// Üst sayı sırası — kapalıysa boş.
    ///
    /// Bu tuşlar **kod çözmeye girmez** (`SymbolPlanes`'in gerekçesiyle aynı:
    /// rakamın leksikonu yok, komşuluk düzeltmesi istenmez). Bu yüzden
    /// `KeyLayout`'a değil ayrı bir listeye giriyorlar ve vuruşları çerçeve
    /// testiyle çözülüyor.
    public static func numberRow(_ m: KeyboardMetrics) -> [SymbolPlanes.PlaneKey] {
        guard m.showsNumberRow else { return [] }
        let h = rowHeight(m)
        let w = 1.0 / Double(numberRowChars.count)
        return numberRowChars.enumerated().map { i, ch in
            SymbolPlanes.PlaneKey(char: ch,
                                  center: Point(x: (Double(i) + 0.5) * w, y: 0.5 * h),
                                  width: w, height: h)
        }
    }

    /// Sayı sırasında bir noktanın düştüğü rakamın indeksi.
    ///
    /// **Çerçeve testi, en yakın merkez değil**: burada uzamsal model yok,
    /// `7` isteyene `8` vermek düpedüz hata (`SymbolPlanes` ile aynı gerekçe).
    /// Ama kırpma yalnız **komşular arasında** yapılıyor:
    /// - Dikeyde hiç kırpılmıyor — satırın üstünde başka tuş yok, oradaki her
    ///   ölü piksel saf kayıp (klavyenin en üst kenarı).
    /// - Yatayda ilk tuş 0'dan, son tuş 1'e kadar uzanıyor; ekran kenarına
    ///   basmak `1` ve `0`'ı kaçırmamalı.
    static func numberRowIndex(at p: Point, _ m: KeyboardMetrics) -> Int? {
        let keys = numberRow(m)
        guard !keys.isEmpty, p.y >= 0, p.y < rowHeight(m) else { return nil }
        for (i, k) in keys.enumerated() {
            let hw = k.width * (1 - SymbolPlanes.hitGap) / 2
            let lo = i == 0 ? 0 : k.center.x - hw
            let hi = i == keys.count - 1 ? 1 : k.center.x + hw
            if p.x >= lo, p.x < hi { return i }
        }
        return nil
    }

    /// İşlev tuşu yuvaları — çizim ve dokunma testi **aynı** listeyi kullanır.
    ///
    /// 3. satır: `[⇧][9 harf][⌫]`, toplam tam 11 birim.
    /// 4. satır: `[123][🌐?][boşluk][.][⏎]`, `⏎` artanı alır.
    ///
    /// Nokta **her düzlemde** var. Yalnız harf düzleminde olsaydı boşluk
    /// tuşunun sağ kenarı düzlem değişince kayardı; sembol düzleminde ikinci
    /// bir `.` görünmesi bunun yanında küçük bir bedel (Gboard da böyle).
    public static func functionSlots(_ m: KeyboardMetrics,
                                     showsGlobe: Bool) -> [FunctionSlot] {
        let h = rowHeight(m)
        let bh = bottomRowHeight(m)
        let u = 1.0 / KeyboardMetrics.rowUnits
        let r0 = firstLetterRow(m)
        let row3y = Double(r0 + 2) * h
        let row4y = Double(r0 + 3) * h

        var slots: [FunctionSlot] = [
            FunctionSlot(role: .leftModifier,
                         rect: Rect(x: 0, y: row3y,
                                    width: m.shiftWidth * u, height: h)),
            FunctionSlot(role: .backspace,
                         rect: Rect(x: 1 - m.backspaceWidth * u, y: row3y,
                                    width: m.backspaceWidth * u, height: h)),
        ]

        var x = 0.0
        func add(_ role: FunctionRole, _ units: Double) {
            slots.append(FunctionSlot(role: role,
                                      rect: Rect(x: x, y: row4y,
                                                 width: units * u, height: bh)))
            x += units * u
        }
        add(.planeSwitch, KeyboardMetrics.planeSwitchWidth)
        if showsGlobe { add(.globe, KeyboardMetrics.globeWidth) }
        add(.space, m.effectiveSpaceWidth(showsGlobe: showsGlobe))
        add(.period, KeyboardMetrics.periodWidth)
        // `⏎` kalanı alır: yuvarlama artığı satırın sonunda birikmesin diye
        // genişlik hesaplanmıyor, 1.0'a kadar uzatılıyor.
        slots.append(FunctionSlot(role: .ret,
                                  rect: Rect(x: x, y: row4y,
                                             width: max(0, 1 - x), height: bh)))
        return slots
    }

    // MARK: - Dokunma çözümlemesi

    /// Bir dokunmanın düştüğü **yüzey**.
    ///
    /// Hangi harf/sembol olduğu burada belirlenmiyor: o karar düzleme bağlı ve
    /// harfte "en yakın merkez", sembolde "çerçeve testi" (birinde uzamsal
    /// model var, diğerinde yok). Burada yalnız **öncelik sırası** var.
    public enum Surface: Equatable, Sendable {
        /// Üst sayı sırasında, verilen indeksteki rakam.
        case digit(index: Int)
        case function(FunctionRole)
        /// İçerik bandı — harf ya da sembol düzlemi. Çözüm çağırana ait.
        case content
        /// Hiçbir tuş yok (işlev satırının dışı, klavye dışı).
        case none
    }

    /// Dokunmayı yüzeye çözer — **sıra burada normatif**.
    ///
    /// 1. Sayı sırası (kendi bandında, çerçeve testiyle)
    /// 2. İşlev tuşları
    /// 3. İçerik bandı
    ///
    /// Sıra UIKit'te gömülü kalmıştı ve test edilemiyordu; işlev tuşlarının
    /// harflerin üstüne binme hatasını görünmez kılan da tam olarak buydu —
    /// çakışma varken işlev tuşları önce kazanıyordu. Çakışma artık geometriyle
    /// imkânsız, sıra da burada sınanabiliyor.
    public static func surface(at p: Point, metrics m: KeyboardMetrics,
                               showsGlobe: Bool) -> Surface {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return .none }

        // Dikdörtgenler `[0,1)`'i tam kaplıyor (`Rect.contains` sağ ve alt
        // kenarı dışlıyor, yoksa komşu hücreler çakışırdı). Tam `1.0`'a düşen
        // dokunma bu yüzden hiçbir yuvaya girmiyordu: sağ kenar `⌫` yerine
        // içerik bandına, oradan da `nearestKey` ile son harfe düşüyordu.
        // Kenar son tuşa ait sayılıyor.
        let q = Point(x: min(p.x, (1.0 as Double).nextDown),
                      y: min(p.y, (1.0 as Double).nextDown))

        if let i = numberRowIndex(at: q, m) { return .digit(index: i) }
        for slot in functionSlots(m, showsGlobe: showsGlobe)
        where slot.rect.contains(q) {
            return .function(slot.role)
        }
        let band = contentBand(m)
        guard q.y >= band.lowerBound, q.y < band.upperBound else { return .none }
        return .content
    }
}
