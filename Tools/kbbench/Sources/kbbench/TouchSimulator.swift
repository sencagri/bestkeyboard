import Foundation
import KBGeometry
import KBSpatial

/// Dokunma simülatörü.
///
/// **Sözleşme §9 uyarısı — bunu okumadan sonuçlara güvenme:**
/// Gaussian bir decoder'ı Gaussian gürültüyle test etmek *model doğrulaması
/// değil, kendini doğrulamadır*. Bu simülatör **parametre taraması ve regresyon
/// tespiti** için değerlidir; **doğruluk kapısı olarak kullanılamaz.** Gerçek
/// doğruluk kapısı, `-1B`'deki typing study'den gelen gerçek dokunma verisiyle
/// kurulacak.
///
/// Bu yüzden simülatör bilinçli olarak Gaussian'dan **sapan** bileşenler içerir:
/// kalın kuyruk (ara sıra tam bir tuş kayma), sistematik sapma alanı ve edit
/// gürültüsü. Amaç decoder'ı kendi varsayımının dışına itmek.
struct TouchSimulator {
    let layout: KeyLayout
    var rng: SplitMix64

    /// Kullanıcının sistematik parmak sapması (tuş genişliği oranında).
    var biasX: Double = 0
    var biasY: Double = 0
    /// Gaussian gürültünün ölçeği (tuş genişliği oranında).
    var sigmaScale: Double = 0.35
    /// Kalın kuyruk: bu olasılıkla dokunma komşu bir tuşa kayar.
    var heavyTailRate: Double = 0.03
    /// Harf atlama / fazla dokunma / harf değiştirme oranları.
    var omissionRate: Double = 0.01
    var insertionRate: Double = 0.01
    var transpositionRate: Double = 0.01

    init(layout: KeyLayout, seed: UInt64) {
        self.layout = layout
        self.rng = SplitMix64(seed: seed)
    }

    /// Bir kelimeyi dokunma dizisine çevirir.
    /// Yazılamayan karakter varsa `nil` (kelime layout'ta yok).
    mutating func touches(for word: String, startTime: Double = 0) -> [TouchSample]? {
        var out: [TouchSample] = []
        var t = startTime
        let chars = Array(word)
        var i = 0

        while i < chars.count {
            // Transposition: iki karakteri ters sırada bas.
            if i + 1 < chars.count, rng.nextDouble() < transpositionRate {
                guard let a = sample(chars[i + 1], t), let b = sample(chars[i], t + 0.05) else { return nil }
                out.append(a); out.append(b)
                t += 0.16
                i += 2
                continue
            }
            // Omission: harfi hiç basma.
            if rng.nextDouble() < omissionRate { i += 1; continue }
            // Insertion: fazladan bir dokunma ekle (önceki tuşun yakınına).
            if rng.nextDouble() < insertionRate, let prev = out.last {
                out.append(TouchSample(down: jitter(prev.down, scale: 0.4), timestamp: t + 0.03))
                t += 0.05
            }
            guard let s = sample(chars[i], t) else { return nil }
            out.append(s)
            t += 0.08 + rng.nextDouble() * 0.12
            i += 1
        }
        return out.isEmpty ? nil : out
    }

    private mutating func sample(_ ch: Character, _ time: Double) -> TouchSample? {
        guard var idx = layout.keyIndex(for: ch) else { return nil }
        // Kalın kuyruk: tam bir tuş kayması — Gaussian'ın üretmeyeceği hata.
        if rng.nextDouble() < heavyTailRate {
            let neighbours = neighbourIndices(of: idx)
            if !neighbours.isEmpty { idx = neighbours[Int(rng.next() % UInt64(neighbours.count))] }
        }
        let key = layout.keys[idx]
        let sx = sigmaScale * key.width
        let sy = sigmaScale * key.height
        return TouchSample(
            down: Point(x: clamp(key.center.x + biasX * key.width + rng.nextGaussian() * sx),
                        y: clamp(key.center.y + biasY * key.height + rng.nextGaussian() * sy)),
            timestamp: time)
    }

    private mutating func jitter(_ p: Point, scale: Double) -> Point {
        Point(x: clamp(p.x + rng.nextGaussian() * scale * 0.03),
              y: clamp(p.y + rng.nextGaussian() * scale * 0.03))
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0.001), 0.999) }

    private func neighbourIndices(of i: Int) -> [Int] {
        let c = layout.keys[i]
        return layout.keys.indices.filter { j in
            guard j != i else { return false }
            let k = layout.keys[j]
            return abs(k.center.x - c.center.x) < c.width * 1.6
                && abs(k.center.y - c.center.y) < c.height * 1.1
        }
    }
}

/// Deterministik, hızlı PRNG — `Math.random` yerine tohumlanabilir olması şart
/// (regresyon karşılaştırmaları aynı diziyi üretmeli).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    /// Box-Muller.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-12)
        let u2 = nextDouble()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
