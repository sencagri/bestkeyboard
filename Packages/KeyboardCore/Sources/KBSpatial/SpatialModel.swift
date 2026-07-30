import Foundation
import KBGeometry

/// Dokunma örneği. `-1A₁`'de yalnız `down` kullanılır.
/// `up` ve `majorRadius` kayda alınır ama **v1 skorlamasında kullanılmaz**
/// (skor sözleşmesi: ayrı ablation ile kanıtlanmadan modele girmez).
public struct TouchSample: Sendable {
    public var down: Point
    public var timestamp: Double

    public init(down: Point, timestamp: Double = 0) {
        self.down = down
        self.timestamp = timestamp
    }
}

/// Tuş başına kalibrasyon durumu: sapma ve yayılım.
/// `-1A₁`'de sapma sıfır, yayılım layout'tan türetilir; öğrenme Faz 1/3.
public struct KeyCalibration: Sendable {
    public var biasX: Double
    public var biasY: Double
    public var sigmaX: Double
    public var sigmaY: Double

    // MARK: Önhesap — `SpatialModel` doldurur, dışarıdan yazılmaz
    //
    // §2.4 *"Normalizasyon sabiti dokunma başına hesaplanmaz — kalibrasyon
    // tablosuyla önceden hesaplanır"* diyor; bu alanlar o tablo. Değerleri tuş
    // geometrisine de bağlı olduğu için `KeyCalibration` kendi başına
    // dolduramaz — `SpatialModel` doldurur.
    //
    // **Neden AYRI bir dizi değil de burada:** ayrı bir `[Precomputed]` dizisi
    // denendi ve tuş başına gecikmeyi **%10 artırdı** — `negLogP`'nin kendisi
    // 35 kat hızlanmış olmasına rağmen. Sebep: `SpatialModel` bir struct ve
    // sıcak yolda `Decoder` üzerinden ödünç alınıyor; her ek dizi çağrı başına
    // fazladan bir retain/release çifti demek. Ölçüm ayrıştırdı: dizi eklenip
    // formül eskisi bırakıldığında da yavaşlık aynen duruyordu, yani bedel
    // formülde değil dizinin varlığındaydı. Aynı diziye daha büyük eleman
    // koymak bu bedeli hiç doğurmuyor.
    var mx = 0.0, my = 0.0
    var invSigmaX = 0.0, invSigmaY = 0.0
    /// `logNorm + log(mass)` — dokunmadan bağımsız sabit.
    var constant = 0.0

    public init(biasX: Double = 0, biasY: Double = 0, sigmaX: Double, sigmaY: Double) {
        self.biasX = biasX
        self.biasY = biasY
        self.sigmaX = sigmaX
        self.sigmaY = sigmaY
    }
}

/// Uzamsal likelihood — skor sözleşmesi §2.4.
///
/// `p(t|c)`, `[0,1]²` üzerinde **truncate edilmiş** 2B Gaussian yoğunluğudur.
/// Yoğunluk olduğu için `p(t|c) > 1` mümkündür ve `−log p` **negatif olabilir**;
/// bu yüzden `sigmaMin` zorunludur (aşırı dar kovaryans hem sayısal kararlılığı
/// hem uzunluk eğilimini bozar).
///
/// `p_bg` aynı `[0,1]²` ölçüsünde tanımlıdır — aksi halde `INS`/`SUB` dengesi
/// cihaz geometrisiyle kayar.
public struct SpatialModel: Sendable {
    public let layout: KeyLayout
    public private(set) var calib: [KeyCalibration]

    /// Kovaryans alt sınırı (§2.4). Kalibrasyon kırpma sınırıyla tutarlı seçilir.
    public let sigmaMin: Double


    /// Arka plan dokunma yoğunluğu: `[0,1]²` üzerinde düzgün → yoğunluk 1 → `−log p_bg = 0`.
    /// Gerçek veriyle değiştirilecek; imza sabit kalır.
    public func negLogPBackground(_ t: TouchSample) -> Double { 0 }

    public init(layout: KeyLayout,
                sigmaXFactor: Double = 0.45,
                sigmaYFactor: Double = 0.55,
                sigmaMin: Double = 0.012) {
        self.layout = layout
        self.sigmaMin = sigmaMin
        self.calib = layout.keys.map { k in
            KeyCalibration(sigmaX: max(sigmaMin, sigmaXFactor * k.width),
                           sigmaY: max(sigmaMin, sigmaYFactor * k.height))
        }
        for i in layout.keys.indices { calib[i] = Self.precomputed(layout.keys[i], calib[i]) }
    }

    public mutating func setCalibration(_ c: KeyCalibration, at keyIndex: Int) {
        var c = c
        c.sigmaX = max(sigmaMin, c.sigmaX)
        c.sigmaY = max(sigmaMin, c.sigmaY)
        // Önhesap **burada** tazeleniyor. Kalibrasyonun tek yazma yolu bu
        // olduğu için tabloyla durum ayrışamaz; `calib` `private(set)`.
        calib[keyIndex] = Self.precomputed(layout.keys[keyIndex], c)
    }

    /// Kalibrasyonu, türetilmiş alanları doldurulmuş hâliyle döndürür.
    private static func precomputed(_ key: Key, _ c: KeyCalibration) -> KeyCalibration {
        var c = c
        c.mx = key.center.x + c.biasX
        c.my = key.center.y + c.biasY
        c.invSigmaX = 1 / c.sigmaX
        c.invSigmaY = 1 / c.sigmaY
        let logNorm = log(2.0 * Double.pi * c.sigmaX * c.sigmaY)
        // [0,1]² üzerindeki kütle — eksenler bağımsız olduğu için çarpım.
        let massX = normalCDF((1.0 - c.mx) / c.sigmaX) - normalCDF((0.0 - c.mx) / c.sigmaX)
        let massY = normalCDF((1.0 - c.my) / c.sigmaY) - normalCDF((0.0 - c.my) / c.sigmaY)
        c.constant = logNorm + log(max(massX * massY, 1e-12))
        return c
    }

    /// `−log p(t | key)` — truncate edilmiş ve `[0,1]²` üzerinde yeniden normalize edilmiş.
    ///
    /// ```
    /// −log p = quad + logNorm + log(mass)
    ///          ↑      └──────────┬──────┘
    ///     dokunmaya      tuş başına SABİT → §2.4'ün kalibrasyon tablosu
    ///     bağlı
    /// ```
    ///
    /// Sıcak yolda kalan: 2 çıkarma, 5 çarpma, 2 toplama — sıfır `erfc`,
    /// sıfır `log`, sıfır bölme. Ölçüldü: çağrı başına 34.5 ns → 0.97 ns.
    @inline(__always)
    public func negLogP(_ t: TouchSample, keyIndex: Int) -> Double {
        let c = calib[keyIndex]
        let zx = (t.down.x - c.mx) * c.invSigmaX
        let zy = (t.down.y - c.my) * c.invSigmaY
        return 0.5 * (zx * zx + zy * zy) + c.constant
    }

    /// Standart normal CDF.
    @inline(__always)
    static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// Truncate edilmiş yoğunluğun `[0,1]²` üzerindeki integrali — test kapısı (§5.4).
    /// Sayısal integral; 1'e yakın olmalı.
    public func numericalMass(keyIndex: Int, grid: Int = 400) -> Double {
        var sum = 0.0
        let h = 1.0 / Double(grid)
        for i in 0..<grid {
            for j in 0..<grid {
                let p = Point(x: (Double(i) + 0.5) * h, y: (Double(j) + 0.5) * h)
                sum += exp(-negLogP(TouchSample(down: p), keyIndex: keyIndex)) * h * h
            }
        }
        return sum
    }
}
