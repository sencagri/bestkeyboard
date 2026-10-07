import Foundation
import KBFoundation
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
public struct TouchSimulator {
    public let layout: KeyLayout
    var rng: SplitMix64

    /// Kullanıcının sistematik parmak sapması — **referans tuş ölçüsü** oranında.
    ///
    /// Birim seçimi Codex turunda düzeltildi ve düzeltme deneyin geçerliliğini
    /// doğrudan etkiliyor. Önceki sürüm sapmayı `bias * key.width` diye her
    /// tuşun **kendi** genişliğiyle çarpıyordu; Türkçe Q'da üst satır 12, alt
    /// satırlar 11 tuşlu olduğu için "yalnız global sapma" senaryosu fiilen
    /// satırdan satıra değişen bir kayma üretiyordu. Yani global kolun
    /// öğrenemeyeceği bir satır etkisi senaryonun içine gizlenmişti ve
    /// hiyerarşinin oradaki üstünlüğü kendi kendine yaratılmıştı.
    ///
    /// Şimdi katmanların hepsi **normalize koordinatta sabit** bir kaymaya
    /// çevriliyor (referans = medyan tuş ölçüsü), tahmincinin modeliyle aynı
    /// uzayda. Sayısal değerler §8.3 ile karşılaştırılabilir kalıyor: 0.35
    /// hâlâ "tipik bir tuşun %35'i kadar kayma" demek.
    public var biasX: Double = 0
    public var biasY: Double = 0

    /// Satır başına **ek** sistematik sapma (referans tuş ölçüsü oranında),
    /// `global`in üstüne. Boşsa satır etkisi yok.
    ///
    /// Faz 3'ün ölçülebilmesi için gerekli: ilk simülatör yalnız tek bir global
    /// kaydırma üretiyordu, yani hiyerarşinin öğrenebileceği bir yapı **hiç
    /// yoktu**. O simülatörle hiyerarşik modeli ölçmek yalnız "fazladan
    /// katmanın gürültüsü ne kadar zarar veriyor" sorusunu yanıtlardı — bu da
    /// meşru ve gerekli bir ölçüm, ama tek başına yanıltıcı.
    ///
    /// Gerçek klavyede satır etkisi beklenen bir olgudur: başparmak alt satıra
    /// üst satırdan farklı bir açıyla iner, üst satıra uzanırken el döner.
    public var rowBiasX: [Double] = []
    public var rowBiasY: [Double] = []

    /// Tuş başına **ek** sapma (referans tuş ölçüsü oranında). Satırın da
    /// üstüne biner. Uzunluk `layout.keys.count`'tan kısaysa eksikler 0 sayılır.
    public var keyBiasX: [Double] = []
    public var keyBiasY: [Double] = []

    /// Sapmaların çevrildiği referans ölçü: medyan tuş genişliği / yüksekliği.
    /// Gürültü (`sigmaScale`) referans DEĞİL tuşun kendi ölçüsünü kullanır —
    /// `SpatialModel` yayılımı öyle kuruyor, simülatör onu taklit etmeli.
    public let refWidth: Double
    public let refHeight: Double
    /// Gaussian gürültünün ölçeği (tuş genişliği oranında).
    public var sigmaScale: Double = 0.35
    /// Kalın kuyruk: bu olasılıkla dokunma komşu bir tuşa kayar.
    public var heavyTailRate: Double = 0.03
    /// Harf atlama / fazla dokunma / harf değiştirme oranları.
    public var omissionRate: Double = 0.01
    public var insertionRate: Double = 0.01
    public var transpositionRate: Double = 0.01

    public init(layout: KeyLayout, seed: UInt64) {
        self.layout = layout
        self.rng = SplitMix64(seed: seed)
        func median(_ v: [Double]) -> Double {
            guard !v.isEmpty else { return 1 }
            let s = v.sorted()
            return s[s.count / 2]
        }
        self.refWidth = median(layout.keys.map(\.width))
        self.refHeight = median(layout.keys.map(\.height))
    }

    /// Bir kelimeyi dokunma dizisine çevirir.
    /// Yazılamayan karakter varsa `nil` (kelime layout'ta yok).
    public mutating func touches(for word: String, startTime: Double = 0) -> [TouchSample]? {
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

        // Sapma üç katmanlı üretilir — tahmincinin varsaydığı yapının aynısı.
        // Simülatörün modeli tahmincininkiyle eşleşiyor; §9'un "kendini
        // doğrulama" uyarısı burada da geçerli ve sonuç yalnız mekanizma
        // testidir, doğruluk kapısı değil.
        //
        // Kaymalar **referans** ölçüyle, gürültü **tuşun kendi** ölçüsüyle:
        // biri kullanıcının elinin sabit bir alışkanlığı, diğeri tuşun
        // büyüklüğüyle ölçeklenen nişan alma hatası.
        let r = layout.rowOfKey[idx]
        let bx = (biasX + at(rowBiasX, r) + at(keyBiasX, idx)) * refWidth
        let by = (biasY + at(rowBiasY, r) + at(keyBiasY, idx)) * refHeight

        return TouchSample(
            down: Point(x: clamp(key.center.x + bx + rng.nextGaussian() * sx),
                        y: clamp(key.center.y + by + rng.nextGaussian() * sy)),
            timestamp: time)
    }

    private func at(_ a: [Double], _ i: Int) -> Double {
        i >= 0 && i < a.count ? a[i] : 0
    }

    private mutating func jitter(_ p: Point, scale: Double) -> Point {
        Point(x: clamp(p.x + rng.nextGaussian() * scale * 0.03),
              y: clamp(p.y + rng.nextGaussian() * scale * 0.03))
    }

    private func clamp(_ v: Double) -> Double { v.clamped(to: 0.001...0.999) }

    private func neighbourIndices(of i: Int) -> [Int] {
        let c = layout.keys[i]
        return layout.keys.indices.filter { j in
            guard j != i else { return false }
            let k = layout.keys[j]
            return abs(k.center.x - c.center.x) < c.width * 1.6
                && abs(k.center.y - c.center.y) < c.height * 1.1
        }
    }

    // MARK: - Hazır ayarlar

    /// Edit olaylarını (atlama, fazla dokunma, yer değiştirme) kapatır.
    ///
    /// Literal'in hedef kelimeye eşit kalması gereken ölçümler bunu istiyor:
    /// kalibrasyon eğitimi (`commit == literal`) ve "doğru yazılmış" sondalar.
    public mutating func disableEditEvents() {
        omissionRate = 0
        insertionRate = 0
        transpositionRate = 0
    }

    /// **Temiz** yazım: yalnız Gaussian nişan hatası — edit olayı yok, kalın
    /// kuyruk yok.
    public mutating func makeClean() {
        disableEditEvents()
        heavyTailRate = 0
    }

    /// Temiz yazım simülatörü. Araçlarda dört ayrı yerde elle kuruluyordu ve
    /// hangisinin hangi gürültüyü kapattığı ancak satır satır okunarak
    /// anlaşılıyordu.
    public static func clean(layout: KeyLayout, seed: UInt64,
                             sigmaScale: Double) -> TouchSimulator {
        var s = TouchSimulator(layout: layout, seed: seed)
        s.sigmaScale = sigmaScale
        s.makeClean()
        return s
    }
}
