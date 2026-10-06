import Foundation

/// Normalize dikdörtgen — `Point` ile aynı [0,1]×[0,1] uzayında.
public struct Rect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Sağ/alt kenarda `<` — bitişik dikdörtgenler çakışmasın diye.
    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func overlaps(_ o: Rect) -> Bool {
        minX < o.maxX && o.minX < maxX && minY < o.maxY && o.minY < maxY
    }
}

/// İşlev tuşu **rolü** — hangi tuşun o yuvada olduğu değil, yuvanın ne işe
/// yaradığı.
///
/// Rol ile tuşu ayırmanın sebebi: 3. satırın sol yuvası harf düzleminde `⇧`,
/// sembol düzlemlerinde "diğer sembol düzlemine geç" tuşudur. Geometri ikisini
/// ayırt etmek zorunda değil; yalnız görünüm ayırt eder.
public enum FunctionRole: String, Sendable, CaseIterable {
    /// 3. satırın solu: harf düzleminde shift, sembolde diğer düzleme geçiş.
    case leftModifier
    case backspace
    /// 4. satırın solu: `123` / `ABC`.
    case planeSwitch
    case globe
    case space
    case ret
    /// Alt satırda boşluğun sağında — nokta (uzun basınca virgül).
    ///
    /// **İşlev rolü olmasının sebebi karakter üretmemesi değil**, kod
    /// çözmeye girmemesi. Rol burada "sabit konumlu, çerçeveyle çözülen tuş"
    /// demek: `.` bir harf değil, leksikonu yok ve komşuluk düzeltmesi
    /// istenmiyor (rakam sırasıyla aynı gerekçe). `KeyLayout`'a koymak onu
    /// `nearestKey`'in adayı yapardı ve `ç`'ye basmak isteyen bir parmak
    /// nokta üretebilirdi.
    case period
}

public struct FunctionSlot: Sendable, Equatable {
    public let role: FunctionRole
    public let rect: Rect

    public init(role: FunctionRole, rect: Rect) {
        self.role = role
        self.rect = rect
    }
}

/// Kullanıcının ayarlayabildiği klavye ölçüleri.
///
/// ## Neden çekirdekte
///
/// Bu ölçüler yalnız çizimi değil **uzamsal modelin girdisini** değiştiriyor:
/// shift genişleyince 3. satırın harfleri daralır ve merkezleri kayar. Ölçüyü
/// UIKit tarafında tutmak, `KeyLayout`'un çizilenden farklı bir geometriye
/// inanması demekti — nitekim ilk sürümde tam olarak bu oldu: `⇧` ve `⌫`
/// 1.5 birimken 3. satır 9 harfi 1 birimden çiziyordu, toplam 12 birim, yani
/// `z` ve `ç` tuşlarının yarısı işlev tuşlarının altında kalıyordu ve
/// dokunmaları da onlara gidiyordu.
///
/// ## Birim
///
/// Genişlikler **birim tuş** cinsinden; 1 birim = satırın 1/11'i (2. satırda
/// 11 tuş var). Normalize koordinata çevirmek `× 1/11`.
public struct KeyboardMetrics: Sendable, Equatable {

    /// Bir satırdaki birim sayısı — 2. satırın tuş sayısı.
    public static let rowUnits: Double = 11

    /// Kullanıcıya açık aralıklar. Alt sınırlar dokunulabilirlikten (44 pt
    /// hedefin altına inmemek), üst sınırlar harf satırının okunabilirliğinden
    /// geliyor: `⇧ + ⌫` en fazla 5 birim alabilir, kalan 6 birim 9 harfe
    /// bölünür (harf başına 0.67 birim). Varsayılan ölçüde harf 0.89 birim.
    public static let shiftRange: ClosedRange<Double> = 1.0...2.5
    public static let backspaceRange: ClosedRange<Double> = 1.0...2.5
    public static let spaceRange: ClosedRange<Double> = 3.0...7.5

    /// Sabit genişlikler. Ayarlanabilir olmalarının bir gerekçesi yok:
    /// `123` ve `🌐` nadir basılıyor, `⏎` boşluğun artanını alıyor.
    public static let planeSwitchWidth: Double = 1.4
    public static let globeWidth: Double = 1.2
    /// Nokta — alt satırda boşluğun sağında, her düzlemde.
    public static let periodWidth: Double = 1.0
    /// `⏎` boşluktan artanı alır ama bu aralığın dışına çıkamaz.
    public static let returnRange: ClosedRange<Double> = 1.2...4.5

    /// Boşluk satırının yüksekliği, **harf satırının katı olarak**.
    ///
    /// Yalnız boşluk tuşunu uzatmak mümkün değil: satır yüksekliği bütün
    /// 4. satırı (`123`, `🌐`, `⏎`) kapsıyor ve tek tuşu büyütmek onu üstteki
    /// harf satırının üstüne bindirirdi — düzelttiğimiz hatanın aynısı.
    /// Bu yüzden ayar **satırın** yüksekliği; klavye toplamda uzayıp kısalıyor,
    /// harf satırları kendi yüksekliğini koruyor.
    public static let bottomRowRange: ClosedRange<Double> = 0.75...1.75

    /// Genişlik kademesi: 1 birim ≈ 36 pt, yani 0.05 birim ≈ 1.8 pt.
    ///
    /// İlk sürüm 0.25'ti — gerekçe `⇧`/`⌫` genişliğinin kalibrasyon profiline
    /// girmesi ve her ara değerin ayrı bir kova açmasıydı. Yanlış tartıydı:
    /// kullanıcı ölçüyü bir kez ayarlayıp bırakıyor, dolayısıyla yalnız
    /// **seçtiği** kova doluyor. Kaba kademe karşılığında hiçbir şey
    /// kazanmıyorduk.
    public static let step: Double = 0.05

    /// Yükseklik kademesi **ayrı ve çok daha ince**: 1 birim ≈ 54 pt, yani
    /// genişlik kademesini burada kullanmak 13.5 pt'lik sıçramalar demekti.
    /// 0.01 ≈ 0.5 pt — pratikte sürekli.
    ///
    /// Yüksekliğin kalibrasyon profiline girmesi bu inceliği pahalı kılmıyor:
    /// kullanıcı bir kez ayarlayıp bırakıyor, her ara değer için ayrı bir kova
    /// açılması yalnız o değerde kalınırsa anlamlı — ve orada zaten kalınıyor.
    public static let bottomRowStep: Double = 0.01

    /// Üst sayı sırası. Kapalıyken klavye 4 satır, açıkken 5.
    ///
    /// Alanlar `private(set)`: kırpma yalnız `init`'te ve geçersiz bir değer
    /// sonradan atanamamalı. Değiştirmek için `with(...)`.
    public private(set) var showsNumberRow: Bool
    public private(set) var shiftWidth: Double
    public private(set) var backspaceWidth: Double
    public private(set) var spaceWidth: Double
    /// Boşluk satırının yüksekliği, harf satırının katı olarak.
    public private(set) var bottomRowScale: Double

    public static let `default` = KeyboardMetrics()

    /// Değerler burada kırpılır — geçersiz bir `KeyboardMetrics` üretilemez.
    /// Kırpmayı çağırana bırakmak, kaydedilmiş bozuk bir ayarın (ya da ileride
    /// başka bir sürümün) çakışan tuşlar üretmesi demekti.
    public init(showsNumberRow: Bool = false,
                shiftWidth: Double = 1.5,
                backspaceWidth: Double = 1.5,
                spaceWidth: Double = 7.0,
                bottomRowScale: Double = 1.0) {
        self.showsNumberRow = showsNumberRow
        // **Bütün** ölçüler kendi kademesine oturtuluyor, yalnız kırpılmıyor.
        //
        // Kırpmak yetmiyordu: `idSuffix` değerleri yüzde bire yuvarlıyor,
        // dolayısıyla `1.3271` ile `1.3349` aynı profil kimliğini üretip
        // **farklı** geometrileri aynı kalibrasyon kovasına koyuyordu. Kademeye
        // oturtunca kimlik kayıpsız oluyor: 0.05 → 5, 0.01 → 1 yüzdelik.
        //
        // Kaynak yalnız sürgü değil: kaydedilmiş eski bir ayar, başka bir
        // sürüm ya da doğrudan çağrı da geçersiz bir değer verebilir.
        self.shiftWidth = Self.canonical(shiftWidth, step: Self.step,
                                         range: Self.shiftRange, fallback: 1.5)
        self.backspaceWidth = Self.canonical(backspaceWidth, step: Self.step,
                                             range: Self.backspaceRange, fallback: 1.5)
        self.spaceWidth = Self.canonical(spaceWidth, step: Self.step,
                                         range: Self.spaceRange, fallback: 7.0)
        self.bottomRowScale = Self.canonical(bottomRowScale, step: Self.bottomRowStep,
                                             range: Self.bottomRowRange, fallback: 1.0)
    }

    /// Kademeye oturt, aralığa kırp, **sonlu olmayanı reddet**.
    ///
    /// `NaN` kırpmadan da yuvarlamadan da sağ çıkıyor ve `idSuffix`'teki
    /// `Int((v * 100).rounded())` çalışma anında trap ediyordu — bozuk bir
    /// `UserDefaults` girdisi klavyeyi çökertirdi.
    static func canonical(_ v: Double, step: Double,
                          range: ClosedRange<Double>, fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return ((v / step).rounded() * step).clamped(to: range)
    }

    /// Tek alanı değiştiren kopya — kırpma yine `init`'ten geçer.
    public func with(showsNumberRow: Bool? = nil,
                     shiftWidth: Double? = nil,
                     backspaceWidth: Double? = nil,
                     spaceWidth: Double? = nil,
                     bottomRowScale: Double? = nil) -> KeyboardMetrics {
        KeyboardMetrics(showsNumberRow: showsNumberRow ?? self.showsNumberRow,
                        shiftWidth: shiftWidth ?? self.shiftWidth,
                        backspaceWidth: backspaceWidth ?? self.backspaceWidth,
                        spaceWidth: spaceWidth ?? self.spaceWidth,
                        bottomRowScale: bottomRowScale ?? self.bottomRowScale)
    }

    /// İki ölçü **aynı harf geometrisini** mi üretiyor.
    ///
    /// Boşluk **genişliği** 4. satırda; harf merkezlerine dokunmuyor. Bunu
    /// ayırt etmemek, boşluğu genişleten kullanıcının kalibrasyon profilini
    /// boşuna sıfırlamak ve decoder'ı boşuna yeniden kurmak demekti.
    ///
    /// Boşluk **yüksekliği** ise dokunuyor: normalize uzay [0,1]'e sabit,
    /// dolayısıyla alt satır uzayınca harf satırlarının normalize yüksekliği
    /// ve merkezleri kayıyor. O yüzden burada karşılaştırılıyor.
    public func sharesLetterGeometry(with o: KeyboardMetrics) -> Bool {
        showsNumberRow == o.showsNumberRow
            && shiftWidth == o.shiftWidth
            && backspaceWidth == o.backspaceWidth
            && bottomRowScale == o.bottomRowScale
    }

    // MARK: - Türetilmiş ölçüler

    /// 3. satırın **yuva sayısı**: 9 harf.
    ///
    /// Bir dönem 10'du — nokta 3. satırdaydı ve her harfi %10 daraltıyordu.
    /// Bedel benchmark'ta ölçülemiyordu (simüle parmak tuşla birlikte
    /// daralıyor, §8.1.1), ama gerçek kullanımda ölçüldü: kullanıcı "çok zor
    /// yazıyorum" dedi ve Apple'ın Türkçe Q'suna göre 3. satır harfleri ~%13
    /// dardı. Nokta alt satıra taşındı (Gboard'un yeri, §8.10).
    public static let row3SlotCount: Double = 9

    /// 3. satırdaki **tek harfin** genişliği, birim cinsinden.
    ///
    /// `⇧` ve `⌫` ne alırsa kalanı 9 harf paylaşır — satır her zaman tam dolar.
    public var letterWidthUnitsRow3: Double {
        (Self.rowUnits - shiftWidth - backspaceWidth) / Self.row3SlotCount
    }

    /// Verilen globe durumunda boşluğun alabileceği aralık.
    ///
    /// 4. satırın toplamı sabit: boşluk büyüyünce `⏎` küçülür. Panel bu aralığı
    /// okuyup kademeyi ona göre sınırlıyor; kullanıcı ulaşamayacağı bir değere
    /// basmak zorunda kalmıyor.
    /// Uçlar `step` ızgarasına oturtuluyor (alt sınır yukarı, üst sınır aşağı):
    /// sürgü kademeye yuvarlıyor, aralık ızgara dışı olsaydı panelin gösterdiği
    /// değer ile klavyenin çizdiği (`effectiveSpaceWidth`) ayrışırdı.
    public static func spaceBounds(showsGlobe: Bool) -> ClosedRange<Double> {
        let fixed = planeSwitchWidth + (showsGlobe ? globeWidth : 0) + periodWidth
        let rawLo = max(spaceRange.lowerBound, rowUnits - fixed - returnRange.upperBound)
        let rawHi = min(spaceRange.upperBound, rowUnits - fixed - returnRange.lowerBound)
        let lo = (rawLo / step).rounded(.up) * step
        let hi = (rawHi / step).rounded(.down) * step
        return lo...max(lo, hi)
    }

    /// Globe durumuna göre kırpılmış boşluk genişliği.
    public func effectiveSpaceWidth(showsGlobe: Bool) -> Double {
        spaceWidth.clamped(to: Self.spaceBounds(showsGlobe: showsGlobe))
    }

    /// `⏎` — 4. satırın artanı.
    public func returnWidth(showsGlobe: Bool) -> Double {
        let fixed = Self.planeSwitchWidth + (showsGlobe ? Self.globeWidth : 0)
            + Self.periodWidth
        return Self.rowUnits - fixed - effectiveSpaceWidth(showsGlobe: showsGlobe)
    }

    /// Klavyenin toplam yüksekliği, **harf satırı** cinsinden.
    ///
    /// Harf satırları hep 1 birim; alt satır `bottomRowScale` birim. Sayı
    /// sırası açılınca ya da alt satır uzayınca klavye **büyüyor**; satırları
    /// sıkıştırmak tuş merkezlerini birbirine yaklaştırıp uzamsal ayrımı
    /// zayıflatırdı.
    public var heightUnits: Double {
        Double(contentRowCount) + bottomRowScale
    }

    /// Harf/sembol/rakam satırlarının sayısı — işlev satırı hariç.
    public var contentRowCount: Int { showsNumberRow ? 4 : 3 }

    // MARK: - Profil kimliği

    /// `KeyLayout.id` eki — **kalibrasyon profilinin parçası**.
    ///
    /// Geometri değişince eski profil sessizce yeniden kullanılmamalı
    /// (`CalibrationStore.ProfileKey`): shift'i genişletmek 3. satırın bütün
    /// merkezlerini kaydırıyor, o geometride öğrenilen sapma bu geometride
    /// yanlış.
    ///
    /// `spaceWidth` **kasten yok**: 4. satırda ve harf merkezlerine dokunmuyor.
    /// Kimliğe katmak, boşluğu bir kademe genişleten kullanıcının öğrenilmiş
    /// sapmasını çöpe atardı. `bottomRowScale` ise **var**: alt satır uzayınca
    /// normalize uzayda harf satırları da yerinden oynuyor.
    public var idSuffix: String {
        func f(_ v: Double) -> String { String(Int((v * 100).rounded())) }
        return "n\(showsNumberRow ? 1 : 0)-s\(f(shiftWidth))-b\(f(backspaceWidth))"
             + "-r\(f(bottomRowScale))-g\(Self.layoutGeneration)"
    }

    /// Harf geometrisinin **kuşağı**.
    ///
    /// ## Neden ayarların kodlanması yetmiyor
    ///
    /// `idSuffix`'in geri kalanı kullanıcının seçtiği ölçüleri kodluyor ve
    /// mantık şuydu: ölçüler aynıysa geometri aynıdır. Nokta tuşu bu çıkarımı
    /// bozdu. Satır 9 yuva yerine 10 yuvaya bölünüyor, yani `⇧` ve `⌫` **hiç
    /// değişmeden** 3. satırın bütün harf merkezleri kaydı. Kimlik eski hâlinde
    /// kalsaydı:
    ///
    /// - `CalibrationStore.ProfileKey` eski profili yeni geometriye bağlardı —
    ///   0.889 birimlik tuşlarda öğrenilen sapma 0.8 birimlik tuşlara
    ///   uygulanırdı. Sessiz, çünkü kalibrasyon zaten küçük sayılar üretiyor
    ///   ve "biraz kaymış" ile "yanlış geometri" dışarıdan aynı görünür.
    /// - Eski kayıtlar yeni düzenle çözülürdü. `layoutFingerprint` v3'te bunu
    ///   yakalıyor ama v2 kayıtlarında parmak izi **yok**; orada tek koruma
    ///   kimliğin kendisi.
    ///
    /// Kuşak bu yüzden ayrı bir alan: ölçülerden **türetilemeyen** bir geometri
    /// değişikliğini kimliğe sokuyor. Harf sayısı, satır bölünmesi ya da yuva
    /// ızgarası değişirse burası artar.
    ///
    /// 1 → nokta tuşundan önce (9 yuva), 2 → nokta 3. satırda (10 yuva),
    /// 3 → nokta alt satırda (yine 9 yuva — ama 1. kuşakla karıştırılmamalı:
    /// alt satır da değişti ve o kuşağın kayıtları bugünün koduyla üretilmedi).
    public static let layoutGeneration = 3

    /// `idSuffix`'i **geri** çözer — kayıttan geometriyi kurmak için.
    ///
    /// ## Neden gerekli
    ///
    /// Kayıt kendi `layoutID`'sini taşıyor ve o kimlik ölçüleri kayıpsız
    /// kodluyor (`init` her değeri kendi kademesine oturtuyor, yani yuvarlama
    /// bilgi kaybetmiyor). Ama replay tarafı varsayılan geometriyle kuruluyordu:
    /// kullanıcı klavyeyi bir kademe genişlettiği anda **bütün** kayıtları
    /// doğrulanamaz hâle geliyordu — 28 gerçek kayıtta ölçüldü, hepsinde
    /// "layout parmak izi farklı".
    ///
    /// `spaceWidth` kimliğe girmiyor (harf merkezlerine dokunmuyor); geri
    /// çözümde varsayılan kalıyor ve **harf geometrisini etkilemiyor**.
    /// Doğruluğun tek kanıtı yine parmak izi: çağıran onu karşılaştırmak
    /// zorunda.
    public init?(idSuffix: String) {
        var number: Bool?
        var shift: Double?, backspace: Double?, bottom: Double?
        var generation: Int?
        for field in idSuffix.split(separator: "-") {
            guard let tag = field.first else { return nil }
            let raw = String(field.dropFirst())
            switch tag {
            case "n":
                guard raw == "0" || raw == "1" else { return nil }
                number = raw == "1"
            case "s":
                guard let v = Int(raw) else { return nil }
                shift = Double(v) / 100
            case "b":
                guard let v = Int(raw) else { return nil }
                backspace = Double(v) / 100
            case "r":
                guard let v = Int(raw) else { return nil }
                bottom = Double(v) / 100
            case "g":
                guard let v = Int(raw) else { return nil }
                generation = v
            default:
                // Tanınmayan alan: başka bir sürümün kimliği. Yok saymak,
                // bilmediğimiz bir geometriyi bildiğimiz sanmak olurdu.
                return nil
            }
        }
        guard let number, let shift, let backspace, let bottom else { return nil }
        // Kuşak alanı **zorunlu ve bu kuşağa eşit** olmalı.
        //
        // Eksik olması eski bir kimlik demek (nokta tuşundan önce, 9 yuva) ve
        // onu bugünün geometrisiyle kurmak tam da kuşak alanının engellemek
        // için var olduğu şey. `nil` dönmek çağırana `unknownLayoutID` olarak
        // ulaşıyor: kayıt atlanıyor, sessizce yanlış çözülmüyor.
        //
        // İleri yön de kapalı: bilmediğimiz bir kuşağın kimliğini bugünün
        // ızgarasıyla kurmak aynı hatanın simetriği.
        guard generation == Self.layoutGeneration else { return nil }
        self.init(showsNumberRow: number, shiftWidth: shift,
                  backspaceWidth: backspace, bottomRowScale: bottom)
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}
