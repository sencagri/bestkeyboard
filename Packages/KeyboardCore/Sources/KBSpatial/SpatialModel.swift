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
    }

    public mutating func setCalibration(_ c: KeyCalibration, at keyIndex: Int) {
        var c = c
        c.sigmaX = max(sigmaMin, c.sigmaX)
        c.sigmaY = max(sigmaMin, c.sigmaY)
        calib[keyIndex] = c
    }

    /// `−log p(t | key)` — truncate edilmiş ve `[0,1]²` üzerinde yeniden normalize edilmiş.
    ///
    /// Normalizasyon sabiti tuş ve kalibrasyon başına sabittir; gerçek üründe
    /// kalibrasyon tablosuyla birlikte önceden hesaplanır (§11). Burada doğrudan
    /// hesaplanıyor çünkü `-1A₁`'in hedefi doğruluk, hız değil.
    public func negLogP(_ t: TouchSample, keyIndex: Int) -> Double {
        let key = layout.keys[keyIndex]
        let c = calib[keyIndex]
        let mx = key.center.x + c.biasX
        let my = key.center.y + c.biasY

        let zx = (t.down.x - mx) / c.sigmaX
        let zy = (t.down.y - my) / c.sigmaY

        // Kesilmemiş Gaussian'ın negatif log yoğunluğu.
        let quad = 0.5 * (zx * zx + zy * zy)
        let logNorm = log(2.0 * Double.pi * c.sigmaX * c.sigmaY)

        // [0,1]² üzerindeki kütle — eksenler bağımsız olduğu için çarpım.
        let massX = Self.normalCDF((1.0 - mx) / c.sigmaX) - Self.normalCDF((0.0 - mx) / c.sigmaX)
        let massY = Self.normalCDF((1.0 - my) / c.sigmaY) - Self.normalCDF((0.0 - my) / c.sigmaY)
        let mass = max(massX * massY, 1e-12)

        // p = N(t) / mass  →  −log p = quad + logNorm + log(mass)
        return quad + logNorm + log(mass)
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
