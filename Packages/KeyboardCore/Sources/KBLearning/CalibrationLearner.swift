import Foundation
import KBGeometry
import KBSpatial

/// Parmak sapmasının kullanıcı düzeltmelerinden öğrenilmesi — plan §3.
///
/// Kullanıcının çekirdek isteği: *"diyelim ki `a` harfi için `a` harfinin sağ
/// altına basıyor... sistemimiz öğrenmeli ve kendi kendini kalibre etmeli."*
///
/// ## Bu faz yalnız **global** sapmayı öğrenir
///
/// Plan hiyerarşik modeli (`b_c = g + r_row(c) + d_c`) Faz 3'e bırakıyor ve
/// gerekçesi ölçülebilir: üç katman aynı ham artıktan bağımsız tahmin
/// edilemez — aynı sistematik sapma üç katmana birden yazılır ve model
/// tanımsız hale gelir. Doğru çözüm backfitting, o da tuş başına anlamlı
/// örnek sayısı ister. Tek bir kullanıcının ilk oturumlarında o veri yok.
///
/// Global sapma ise **tek parametre** ve az örnekle bile kararlı: "kullanıcı
/// genelde tuşların sağ altına basıyor" gözlemi tuş başına veri gerektirmez.
///
/// ## Hizalama **çıkarılmaz, kaydedilir**
///
/// Plan §9 döngüsellik uyarısı veriyor: hizalamayı kendi decoder'ımızdan
/// çıkarıp onunla model eğitmek kendini doğrulamadır.
///
/// İlk tasarımım "dokunma sayısı = kelime uzunluğu ise hizalama benzersizdir"
/// diyordu. **Yanlıştı:** `TR` uzunluğu korur, dengeli bir `OM`+`INS` çifti de
/// net uzunluğu korur. Uzunluk eşitliği pozisyonel hizalamayı kanıtlamaz.
///
/// Doğru çözüm hizalamayı **çıkarmamak**: uzantı her dokunmada literal
/// karakteri anında yazıyor (`insertLetter`), yani "dokunma `i` → literal
/// karakter `i`" bir çıkarım değil, olan biteni kaydeden bir **olgudur**.
/// Modelin hiçbir yerde payı yok.
///
/// Bunun bedeli açık: yalnız **commit edilen metnin literal'e eşit olduğu**
/// token'lardan öğrenebiliyoruz. Otomatik düzeltme yaptıysa ya da kullanıcı
/// farklı bir öneri seçtiyse literal *hedef değildir* ve o token atılır.
///
/// Bu, tahmini **sıfıra doğru zayıflatır**: parmağı komşu tuşa taşacak kadar
/// kayan dokunmalar tam da düzeltmeye yol açanlar, yani topladıklarımızın
/// dışında kalıyorlar. Kayıp bilinçli — muhafazakâr yönde hata yapıyoruz:
/// eksik öğrenmek yalnız faydayı geciktirir, yanlış öğrenmek zarar verir.
///
public struct CalibrationLearner: Sendable {

    /// Etiket gücü — plan §3 tablosu.
    public enum Confidence: UInt8, Sendable {
        /// Kullanıcı öneriye açıkça dokundu, ya da düzeltmeyi geri alıp
        /// literal'i bıraktı. Doğrudan öğrenmeye uygun.
        case strong = 0
        /// Otomatik commit, değiştirilmedi. **Doğruluk etiketi değildir** —
        /// kullanıcı düzeltmeye üşenmiş olabilir. Karantinada tutulur.
        case weak = 1
    }

    public struct Sample: Sendable, Equatable {
        /// Dokunma noktası (normalize).
        public var point: Point
        /// Hedeflenen tuşun indeksi.
        public var keyIndex: Int
        public var confidence: Confidence

        public init(point: Point, keyIndex: Int, confidence: Confidence) {
            self.point = point
            self.keyIndex = keyIndex
            self.confidence = confidence
        }
    }

    /// Sapma tahmini için gereken en az **güçlü** örnek sayısı.
    ///
    /// Altında hiçbir şey uygulanmaz. Plan §3: *"Yetersiz güçlü etiket durumu
    /// tanımlıdır: kullanıcının güçlü etiketi eşiğin altındaysa hiyerarşinin
    /// yalnız `g` katmanı güncellenir; hiç etiket yoksa varsayılan profil
    /// korunur."* Bu fazda zaten yalnız `g` var, dolayısıyla eşik "hiç
    /// uygulama" sınırıdır.
    public static let minStrongSamples = 40

    /// Shrinkage sabiti: `n·x / (n + κ)`.
    ///
    /// Az örnekte sıfıra, çok örnekte tam tahmine yakınsar. `κ = 60` seçimi
    /// sentetik geri-kazanım testiyle kontrol edildi: 40 örnekte gerçek
    /// sapmanın ~%40'ı, 300 örnekte ~%83'ü uygulanıyor. Erken agresif olmamak
    /// bilinçli — yanlış yöne kayan bir kalibrasyon kullanıcıya doğrudan zarar
    /// verir, geç kalan bir kalibrasyon yalnız faydayı geciktirir.
    public static let kappa = 60.0

    /// Toplam sapmanın üst sınırı, **tuş genişliği oranında** (plan §3).
    ///
    /// Bozuk veri ya da yanlış hizalama sapmayı uçurabilir; bu sınır zararı
    /// tuşun yarısıyla kapatıyor.
    public static let maxBiasInKeyWidths = 0.6

    /// Sapmayı `maxBiasInKeyWidths`'e kırpar — **vektör normu** üzerinde ve
    /// eksenler kendi tuş ölçüsünde normalize edilerek:
    ///
    ///     √( (bx/w)² + (by/h)² )  ≤  0.6
    ///
    /// Eksen bazlı kırpma diyagonal sapmanın √2 katına, yani ~0.85 tuşa
    /// çıkmasına izin veriyordu. Eksenler AYRI normalize edilir: normalize
    /// koordinatta `x` ve `y` aynı fiziksel ölçeği temsil etmiyor (tuşlar geniş
    /// ve alçak); ortak bir `min(w,h)` ölçeği dikey sapmayı gereğinden fazla
    /// bastırırdı.
    ///
    /// Global tahmin (Faz 1) ve hiyerarşik tahmin (Faz 3) **aynı** kuralı
    /// kullanıyor; yalnız ölçü farklı (layout'un en dar tuşu ↔ tuşun kendisi).
    static func clampBias(x: Double, y: Double, keyWidth w: Double,
                          keyHeight h: Double) -> (x: Double, y: Double, clamped: Bool) {
        let norm = ((x / w) * (x / w) + (y / h) * (y / h)).squareRoot()
        guard norm > maxBiasInKeyWidths, norm > 0 else { return (x, y, false) }
        let f = maxBiasInKeyWidths / norm
        return (x * f, y * f, true)
    }

    /// Güçlü örnek rezervuarının kapasitesi (plan §3: "profil başına ~2000").
    ///
    /// Sınırsız olamaz: uzantı bellek bütçesi dar (§11.D) ve varyans
    /// yeniden hesabı (Faz 3) rezervuarı taramak zorunda.
    public static let reservoirCapacity = 2000

    /// Zayıf örnekler için **ayrı ve küçük** kapasite.
    ///
    /// Tek ortak rezervuar ciddi bir hataydı: her boşluk commit'i zayıf örnek
    /// üretiyor, FIFO ile güçlü örnekleri dışarı atıyordu. Yani kullanıcı
    /// yazdıkça geçerli kalibrasyon **azalıyor**, hatta eşiğin altına
    /// düşebiliyordu — özellik kullanıldıkça bozuluyordu.
    public static let weakReservoirCapacity = 400

    private(set) var strong: [Sample] = []
    private(set) var weak: [Sample] = []

    public init() {}

    /// Tüm örnekler — teşhis ve testler için (güçlüler önce).
    var reservoir: [Sample] { strong + weak }

    public var strongCount: Int { strong.count }
    public var sampleCount: Int { strong.count + weak.count }

    // MARK: - Örnek toplama

    /// Commit edilen bir token'dan örnek toplar.
    ///
    /// - Parameters:
    ///   - touches: token'ın dokunma dizisi.
    ///   - literal: kullanıcının **fiilen bastığı** harfler.
    ///   - committed: belgede duran metin.
    ///
    /// `committed != literal` ise **hiçbir şey toplanmaz**: o durumda literal
    /// hedef değildir ve onu hedef saymak yazım hatasını modele öğretirdi.
    ///
    /// - Returns: eklenen örnek sayısı (teşhis için).
    @discardableResult
    public mutating func observe(touches: [TouchSample],
                                 literal: String,
                                 committed: String,
                                 layout: KeyLayout,
                                 confidence: Confidence) -> Int {
        guard committed == literal else { return 0 }

        let chars = Array(literal)
        guard chars.count == touches.count, !chars.isEmpty else { return 0 }

        // Tek bir karakter bile eşlenemiyorsa **token'ın tamamı** reddedilir.
        // Kısmi kabul, casing ya da Unicode normalizasyonu yüzünden kayan bir
        // token'ı sessizce içeri alırdı.
        var keys: [Int] = []
        keys.reserveCapacity(chars.count)
        for ch in chars {
            guard let k = layout.keyIndex(for: ch) else { return 0 }
            keys.append(k)
        }

        for (t, k) in zip(touches, keys) {
            append(Sample(point: t.down, keyIndex: k, confidence: confidence))
        }
        return keys.count
    }

    /// Örneği rezervuara ekler.
    ///
    /// `public`: cihazdan çekilen yazım kayıtlarını offline replay'de öğreniciye
    /// vermenin yolu bu (§12). `observe(...)` orada kullanılamaz — o, canlı
    /// oturumun `commit == literal` kuralını uyguluyor, oysa hedefli kayıtta
    /// niyet **protokolden** biliniyor ve etiket kuralı farklı (§12.5).
    public mutating func append(_ s: Sample) {
        switch s.confidence {
        case .strong:
            strong.append(s)
            if strong.count > Self.reservoirCapacity {
                strong.removeFirst(strong.count - Self.reservoirCapacity)
            }
        case .weak:
            weak.append(s)
            if weak.count > Self.weakReservoirCapacity {
                weak.removeFirst(weak.count - Self.weakReservoirCapacity)
            }
        }
    }

    // MARK: - Tahmin

    public struct Estimate: Sendable, Equatable {
        /// Global sapma, normalize koordinatta.
        public var globalBiasX: Double
        public var globalBiasY: Double
        /// Tahmine katılan güçlü örnek sayısı.
        public var strongSamples: Int
        /// Eşik aşıldı mı — `false` ise uygulanmamalı.
        public var isApplicable: Bool
    }

    /// Global sapmayı tahmin eder.
    ///
    /// Artık, dokunma ile **hedef tuşun merkezi** arasındaki fark. Zayıf
    /// etiketler tahmine **girmez** (karantina): pseudo-label havuzunda iyi
    /// görünmek kanıt sayılmaz (plan §3).
    public func estimate(layout: KeyLayout) -> Estimate {
        var sx = 0.0, sy = 0.0, n = 0
        for s in strong {
            guard s.keyIndex < layout.keys.count else { continue }
            let c = layout.keys[s.keyIndex].center
            sx += s.point.x - c.x
            sy += s.point.y - c.y
            n += 1
        }
        guard n > 0 else {
            return Estimate(globalBiasX: 0, globalBiasY: 0,
                            strongSamples: 0, isApplicable: false)
        }

        let shrink = Double(n) / (Double(n) + Self.kappa)
        // Tek sapma tüm layout'a uygulandığı için ölçü en dar tuş.
        let b = Self.clampBias(x: shrink * (sx / Double(n)), y: shrink * (sy / Double(n)),
                               keyWidth: layout.minKeyWidth, keyHeight: layout.minKeyHeight)

        return Estimate(globalBiasX: b.x, globalBiasY: b.y,
                        strongSamples: n, isApplicable: n >= Self.minStrongSamples)
    }

    /// Tahmini uzamsal modele uygular.
    ///
    /// Uygulanabilir değilse model **hiç dokunulmadan** döner — yarım
    /// kalibrasyon uygulamaktansa hiç uygulamamak yeğdir.
    public func apply(to model: inout SpatialModel) {
        let e = estimate(layout: model.layout)
        guard e.isApplicable else { return }
        for i in 0..<model.layout.keys.count {
            var c = model.calib[i]
            c.biasX = e.globalBiasX
            c.biasY = e.globalBiasY
            model.setCalibration(c, at: i)
        }
    }

    // MARK: - Faz 3: hiyerarşik

    /// `b_c = g + r_row(c) + d_c` — ayrışmasıyla birlikte.
    public func hierarchicalEstimate(layout: KeyLayout) -> HierarchicalCalibration.Estimate {
        HierarchicalCalibration.estimate(samples: strong, layout: layout)
    }

    /// Hiyerarşik tahmini uygular — tuş başına ayrı sapma.
    ///
    /// `apply(to:)` (Faz 1, global) **kaldırılmadı**: ölçüm kolu olarak duruyor.
    /// İki kolu aynı anda tutmak `kbbench --calibration`'ın üç kollu
    /// karşılaştırmasını mümkün kılan şey; hiyerarşinin global'e üstünlüğü
    /// varsayılmıyor, ölçülüyor.
    public func applyHierarchical(to model: inout SpatialModel) {
        let e = hierarchicalEstimate(layout: model.layout)
        guard e.isApplicable else { return }
        for i in 0..<model.layout.keys.count {
            var c = model.calib[i]
            c.biasX = e.biasX[i]
            c.biasY = e.biasY[i]
            model.setCalibration(c, at: i)
        }
    }

    /// Kalibrasyonu sıfırlar (kullanıcı ayarlardan isteyebilir — plan §3).
    public mutating func reset() {
        strong.removeAll(keepingCapacity: false)
        weak.removeAll(keepingCapacity: false)
    }

    // MARK: - Serileştirme

    /// Diske yazılacak örnekler — **yalnız güçlü olanlar**.
    ///
    /// Zayıf örnekler bu fazda tahmine hiç girmiyor (karantina), dolayısıyla
    /// onları kalıcılaştırmanın işlevsel faydası yok. Ham dokunma koordinatı
    /// kişisel veridir; kullanılmayan veriyi saklamamak veri minimizasyonunun
    /// gereği. Faz 3 pseudo-label havuzunu kullanmaya karar verirse format
    /// bayrağı zaten taşıyor.
    func encodedSamples() -> [Sample] { strong }

    init(samples: [Sample]) {
        for s in samples { append(s) }
    }
}
