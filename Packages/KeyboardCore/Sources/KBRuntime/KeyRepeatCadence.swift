/// Basılı tutma tekrarının **zamanlama politikası**.
///
/// Görünümden ayrı durmasının sebebi: kullanıcıya doğrudan toplu silme
/// uygulayan bir mekanizma bu; kademe geçişinin doğruluğu `Timer` ateşlemesini
/// beklemeden sınanabilmeli. Görünüme kalan iş yalnız zamanlayıcıyı kurmak ve
/// dokunmayı iletmek.
///
/// ## Neden kullanıcı ayarı
///
/// Basılı tutma hızı **kişisel**: aynı 85 ms bir kullanıcıya tembel, diğerine
/// kontrolden çıkmış geliyor. Tuş ölçüleriyle aynı yaklaşım — değerler
/// `init`'te kırpılıyor, geçersiz bir cadence üretilemiyor.
///
/// Geometri ayarlarının aksine bu ayar **kalibrasyon profilini etkilemiyor**:
/// zamanlama tuş merkezlerine dokunmuyor, dolayısıyla `KeyLayout.id`'ye de
/// girmiyor ve decoder'ın yeniden kurulmasını gerektirmiyor.
public struct KeyRepeatCadence: Sendable, Equatable {

    public enum Stage: Sendable, Equatable {
        /// Karakter karakter.
        case character
        /// Kelime kelime — basılı tutma sürdüğünde.
        case word
    }

    // MARK: Kullanıcıya açık aralıklar
    //
    // Alt sınırlar kazayla tetiklenmeyi, üst sınırlar "tuş bozuk mu" hissini
    // engelliyor. `initialDelay`'in tabanı normal bir dokunuşun (~120 ms)
    // hemen üstünde: 250 ms'ydi, kullanıcı "çok geldi" dedi; 150 ms hâlâ
    // sıradan bir dokunuştan uzun, altı hızlı yazarken istemsiz tekrar demek.

    public static let initialDelayRange: ClosedRange<Double> = 0.15...1.0
    public static let characterIntervalRange: ClosedRange<Double> = 0.03...0.20
    public static let wordIntervalRange: ClosedRange<Double> = 0.10...0.50
    public static let charactersBeforeWordStageRange: ClosedRange<Int> = 4...40

    /// Kademe **1 ms**. Zamanlama geometri değil: kalibrasyon profiline
    /// girmiyor, dolayısıyla ince adımın hiçbir bedeli yok — kaba tutmak
    /// yalnız kullanıcıyı istediği hıza yaklaştırmamak olurdu.
    public static let timingStep = 0.001

    public static let initialDelayStep = timingStep
    public static let characterIntervalStep = timingStep
    public static let wordIntervalStep = timingStep
    public static let charactersBeforeWordStageStep = 1

    /// İlk tekrara kadar beklenen süre. Yanlışlıkla tekrarı önler: normal bir
    /// dokunuş bunun çok altında.
    public private(set) var initialDelay: Double
    /// Karakter kademesi aralığı.
    public private(set) var characterInterval: Double
    /// Kelime kademesi aralığı. Karakter hızında kelime silmek kullanıcıya
    /// nerede durduğunu göstermez; bilerek yavaş.
    public private(set) var wordInterval: Double
    /// Kaç karakter tekrarından sonra kelime kademesine geçilir (~1.2 sn).
    public private(set) var charactersBeforeWordStage: Int

    public static let `default` = KeyRepeatCadence()

    /// Kırpma burada — kaydedilmiş bozuk bir ayar (ya da ileride başka bir
    /// sürüm) tuşu kullanılamaz hâle getiremesin.
    public init(initialDelay: Double = 0.45,
                characterInterval: Double = 0.085,
                wordInterval: Double = 0.22,
                charactersBeforeWordStage: Int = 14) {
        // Süreler 1 ms ızgarasına oturtuluyor: sürgü `Float` üzerinden geliyor
        // ve 0.0850000001 gibi değerler üretiyor. Depoya kanonik değer yazmak,
        // "85 ms" gösterip 85.0000001 saklamamayı garanti ediyor.
        //
        // Sonlu olmayan değer reddediliyor: `NaN` kırpmadan da yuvarlamadan da
        // sağ çıkıp `Timer`'a geçersiz bir aralık olarak giderdi.
        func ms(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard v.isFinite else { return fallback }
            return ((v / Self.timingStep).rounded() * Self.timingStep).clamped(to: r)
        }
        self.initialDelay = ms(initialDelay, Self.initialDelayRange, 0.45)
        self.characterInterval = ms(characterInterval, Self.characterIntervalRange, 0.085)
        self.charactersBeforeWordStage =
            charactersBeforeWordStage.clamped(to: Self.charactersBeforeWordStageRange)
        // Kelime aralığı karakter aralığından **kısa olamaz**: kelime silmeyi
        // karakterden hızlı akıtmak kullanıcıya nerede durduğunu göstermez ve
        // basılı tutan biri bir anda paragrafı kaybeder.
        self.wordInterval = max(ms(wordInterval, Self.wordIntervalRange, 0.22),
                                self.characterInterval)
    }

    /// Tek alanı değiştiren kopya — kırpma yine `init`'ten geçer.
    public func with(initialDelay: Double? = nil,
                     characterInterval: Double? = nil,
                     wordInterval: Double? = nil,
                     charactersBeforeWordStage: Int? = nil) -> KeyRepeatCadence {
        KeyRepeatCadence(
            initialDelay: initialDelay ?? self.initialDelay,
            characterInterval: characterInterval ?? self.characterInterval,
            wordInterval: wordInterval ?? self.wordInterval,
            charactersBeforeWordStage:
                charactersBeforeWordStage ?? self.charactersBeforeWordStage)
    }

    /// `tick` 1'den başlar; 1. tekrar `initialDelay` sonra gelir.
    public func stage(forTick tick: Int) -> Stage {
        tick <= charactersBeforeWordStage ? .character : .word
    }

    /// `tick` numaralı tekrar ateşlendikten sonra bir sonrakine kadar beklenecek süre.
    ///
    /// Aralık **bir sonraki** tekrarın kademesinden okunur; yoksa kelime
    /// kademesinin ilk silmesi hâlâ karakter hızında gelirdi.
    public func interval(afterTick tick: Int) -> Double {
        stage(forTick: tick + 1) == .character ? characterInterval : wordInterval
    }

    /// Basılı tutmaya başlandıktan **kelime kademesine geçene kadar** geçen süre.
    ///
    /// Ayarların tek başına anlamı yok; kullanıcının hissettiği şey bu toplam.
    /// Ayar ekranı bunu gösteriyor, testler de bunu sınırlıyor.
    public var timeToWordStage: Double {
        initialDelay + Double(charactersBeforeWordStage - 1) * characterInterval
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}

extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}
