import Foundation
import KBGeometry
import KBSpatial

/// Hiyerarşik sapma modeli — plan §3, Faz 3.
///
/// ```
/// b_c = g + r_row(c) + d_c
/// ```
///
/// ## Neden gerekti
///
/// Faz 1 (global sapma) ölçüldü ve sözleşme §8.3'e yazıldı: ortalamada kazanç
/// var, **ama en kötü tuşta −8.3 puan**. Bu beklenen ve yapısaldır — tek bir
/// kaydırma her tuşa aynı anda yardım edemez, çünkü bazı tuşlar için doğru
/// düzeltme başka yöndedir. §8.3 bu ölçümü doğrudan "Faz 3'ün gerekçesi" diye
/// kaydetti.
///
/// ## Tanımlanabilirlik — asıl zorluk
///
/// Üç katman aynı ham artıktan **bağımsız tahmin edilemez**: `g`'yi 0.1
/// artırıp her `r_row`'u 0.1 azaltmak aynı `b_c`'yi verir. Kısıtsız model
/// tanımsızdır ve backfitting keyfî bir noktada durur.
///
/// Çözüm iki parçalı ve ikisi de gerekli:
///
/// 1. **Merkezleme.** Her geçişin sonunda ince katman örnek-ağırlıklı sıfır
///    ortalamaya getirilir, çıkarılan kütle bir üst katmana **itilir**.
///    Geçiş sonunda tutan iki kısıt (`invariants(...)` bunları döndürür,
///    testler doğrular):
///
///    ```
///    Σ_{q açık}  n_q · r_q  =  0
///    Σ_{c ∈ q, açık}  n_c · d_c  =  0        her açık satır q için
///    ```
///
/// 2. **Katman başına shrinkage.** Merkezleme tekliği verir ama gürültüyü
///    engellemez; ince katman az örnekle tahmin edilir.
///
/// İkisinin sırası önemli: shrinkage **önce**, merkezleme **sonra**. Ters
/// sırada merkezleme shrinkage'ın bastırdığı kütleyi geri getirirdi.
///
/// **Codex turunda bulunan hata:** ilk uygulama satır katmanını merkezliyor,
/// sonra tuş katmanının kütlesini satıra itiyor ve **bir daha merkezlemiyordu**.
/// Yani dönen `r`'nin ağırlıklı ortalaması sıfır değildi — belgelenen invariant
/// fiilen tutmuyordu. Merkezleme artık geçişin **sonunda**, itmelerden sonra.
/// İkinci hata aynı yerdeydi: payda tüm örneklerin `n`'i, çıkarma yalnız açık
/// satırlaraydı; kapalı satır varken ağırlıklı toplam sıfırlanmıyordu.
///
/// ## Shrinkage sabit DEĞİL, veriden kestiriliyor
///
/// İlk uygulama ince katmanlarda Faz 1'in `n/(n+κ)` biçimini elle seçilmiş
/// `κ` ile kullanıyordu. Ölçüm bunu **çürüttü** (sözleşme §8.6): sapması
/// tamamen global olan bir kullanıcıda hiyerarşi 1.0 puan **kaybettiriyordu**,
/// en kötü tuşta −11.1. Sebep açık — sabit `κ` "bu kullanıcıda tuş yapısı var
/// mı" sorusunu soramaz, artığın tamamını yapı sanıp gürültüye uyar.
///
/// Yerine **ampirik Bayes** (rastgele etkiler) konuldu. Birim ortalamalarının
/// gözlenen yayılımı iki şeyin toplamıdır:
///
/// ```
/// E[ Var(m_u) ]  =  τ²          +  ort_u(v_u)
///                   gerçek yapı    örnekleme gürültüsü,  v_u = σ²_u / n_u
/// ```
///
/// `σ²_u` artıklardan ölçülür, `Var(m_u)` gözlenir; `τ²` ikisinin farkıdır.
/// Shrinkage katsayısı birim başına `τ² / (τ² + v_u)`.
///
/// Bu kendi kendini ayarlar ve tam da eksik olanı yapar: kullanıcıda tuş yapısı
/// yoksa `τ² → 0`, `d_c → 0` ve model **kendiliğinden Faz 1'e iner**. Yapı
/// varsa ve örnek yeterliyse katsayı 1'e yaklaşır. Elle sabit seçmek bu iki
/// durumu ayırt edemiyordu; sorun sabitin değerinde değil, biçimindeydi.
///
/// ## `σ²` tuş başına ölçeklenir — havuzlanmış tek sayı yanlıştı
///
/// İlk uygulama tek bir havuzlanmış `σ²` kullanıyordu. Bu, tuşların aynı
/// yayılıma sahip olmasını gerektirir; oysa `SpatialModel` yayılımı **tuş
/// ölçüsüyle orantılı** kuruyor (`σ_x = 0.45 · genişlik`) ve Türkçe Q'da üst
/// satır 12, alt satırlar 11 tuşlu — genişlikler farklı. Homoskedastik varsayım
/// sağlanmıyordu, dolayısıyla `τ²` ve tüm EB katsayıları sistematik olarak
/// yanlış çıkıyordu.
///
/// Doğrusu geometrinin ima ettiği yapıyı kullanmak: `σ²_c = s² · ölçek_c²`,
/// tek bir havuzlanmış **göreli** varyans `s²` ile. Bir parametre, ama doğru
/// biçimde.
public struct HierarchicalCalibration: Sendable {

    // MARK: - Sabitler

    /// Katman kapıları — plan §3: *"Yetersiz güçlü etiket durumu tanımlıdır."*
    ///
    /// Ampirik Bayes zaten az örnekli birimi kendiliğinden bastırıyor; kapılar
    /// buna ek olarak **`τ²`'nin kendisi ölçülemeyecek kadar az** örnekli
    /// katmanı tamamen kapatıyor. İkisi fazladan ihtiyat değil, farklı iki
    /// başarısızlığa karşı: biri gürültülü tahmine, diğeri 2-3 örnekten
    /// `τ²` kestirmeye çalışmaya.
    public static let minRowSamples = 30
    public static let minKeySamples = 20

    /// `τ²` kestirimi için gereken en az **birim** sayısı.
    ///
    /// Ayrı olmaları zorunlu, ortak sabit bir hataydı: Türkçe Q'da yalnız **üç**
    /// harf satırı var, dolayısıyla ortak eşik 4 satır katmanını üretim
    /// layout'unda **tamamen kapatıyordu** — "global+satır" senaryosundaki
    /// kazanç satırdan değil, satır etkisini emen tuş katmanından geliyordu.
    /// Codex turunda yakalandı.
    ///
    /// Üçle kestirilen bir varyansın 2 serbestlik derecesi vardır ve gürültülüdür;
    /// bunun karşılığı EB'nin kendi shrinkage'i — gürültülü `τ²` küçük çıkarsa
    /// katman zaten kapanır. Kestirilemeyecek kadar az olan sınır 2'dir.
    public static let minRowsForVarianceEstimate = 3
    public static let minKeysForVarianceEstimate = 4

    /// Backfitting üst sınırı ve durma ölçütü.
    ///
    /// Sabit geçiş sayısı yeterli değildi: `τ²` her geçişte yeniden
    /// kestirildiği için dönüşüm doğrusal değil ve "4 geçiş yakınsar" iddiası
    /// ölçütsüzdü. Şimdi ölçüt açık — ardışık iki geçiş arasında **hiçbir tuşun
    /// toplam sapması** `tolerance`'tan fazla değişmiyorsa durulur.
    ///
    /// `tolerance` normalize koordinatta: tuş genişliğinin ~%0.01'i, yani
    /// herhangi bir cihazda piksel altı. Üst sınır uzantıda koşan bir döngünün
    /// olmazsa olmazı.
    public static let maxPasses = 16
    public static let tolerance = 1e-7

    // MARK: - Sonuç

    /// Tuş başına sapma ve onu üreten ayrışma.
    ///
    /// Ayrışma teşhis için saklanıyor (`kbdiag`): "kullanıcının sapması global
    /// mi, alt satıra mı özgü" sorusu ancak katmanlar ayrı görülürse
    /// yanıtlanır. Toplam tek başına bunu gizler.
    ///
    /// **Uyarı:** `biasX/biasY` kırpılmıştır, `global + row + key` değildir.
    /// Kırpma devreye girdiyse ayrışma artık uygulanan sapmayı üretmez; teşhis
    /// okurken `clampedKeys` sayacına bakılmalı.
    public struct Estimate: Sendable, Equatable {
        public var globalX: Double
        public var globalY: Double
        /// Satır başına artık (`r_row`), merkezlenmiş.
        public var rowX: [Double]
        public var rowY: [Double]
        /// Tuş başına artık (`d_c`), satır içinde merkezlenmiş.
        public var keyX: [Double]
        public var keyY: [Double]
        /// Uygulanacak toplam sapma, **kırpılmış** (`b_c`).
        public var biasX: [Double]
        public var biasY: [Double]

        public var strongSamples: Int
        /// Eşik aşıldı mı — `false` ise hiçbir şey uygulanmamalı.
        public var isApplicable: Bool

        /// Sıfırdan farklı katsayı alan birim sayısı — teşhis.
        ///
        /// **"Katman etkili" demek değil, "katman açık" demek.** Eşik tam sıfır
        /// olduğu için tuşun binde biri kadar bir katsayı da sayılır. Ayrım
        /// önemli: null altında ölçerken bu sayaç 40 denemenin 14'ünde "açık"
        /// diyordu, ama katsayıların büyüklüğü tuşun %1'i mertebesindeydi.
        /// Zarar sorusu sorulacaksa sayaç değil **büyüklük** ölçülmeli.
        public var keysWithOwnLayer: Int
        public var rowsWithOwnLayer: Int
        /// Kırpmaya takılan tuş sayısı; > 0 ise ayrışma toplamı açıklamıyor.
        public var clampedKeys: Int
        /// Yakınsama için gereken geçiş sayısı.
        public var passes: Int
        /// Durma ölçütü sağlandı mı. `passes == maxPasses` tek başına yetmez:
        /// tam son geçişte yakınsamakla üst sınıra çarpmak farklı şeyler.
        public var converged: Bool
        /// Son geçişteki en büyük değişim — hem toplam hem bileşenler üzerinden.
        public var maxDelta: Double
    }

    // MARK: - Tahmin

    /// Tahmine girebilecek örnekler — **tek** filtre tanımı.
    ///
    /// Doğrulama `CalibrationStore` yüklemesine ek: `Sample` initializer'ı
    /// public, yani örnek dosyadan gelmek zorunda değil. Tek bir NaN koordinat
    /// kırpmayı da atlar (`NaN > x` daima false), `SpatialModel`e sızar ve
    /// **tüm** skorlamayı zehirler.
    ///
    /// Filtrenin tek yerde olması şart: `invariants()` başka bir küme sayarsa
    /// geçersiz bir örnek sahte invariant ihlali üretir (Codex turu).
    static func usable(_ samples: [CalibrationLearner.Sample],
                       layout: KeyLayout) -> [CalibrationLearner.Sample] {
        samples.filter { s in
            guard s.confidence == .strong else { return false }
            guard s.keyIndex >= 0, s.keyIndex < layout.keys.count else { return false }
            guard s.point.x.isFinite, s.point.y.isFinite else { return false }
            let k = layout.keys[s.keyIndex]
            return k.width > 0 && k.height > 0 && k.center.x.isFinite && k.center.y.isFinite
        }
    }

    /// Güçlü örneklerden hiyerarşik sapmayı kestirir.
    ///
    /// Zayıf etiketler Faz 1'deki gibi **karantinadadır**: pseudo-label
    /// havuzunda iyi görünmek kanıt sayılmaz (plan §3). Faz 3'ün ince katmanı
    /// daha az örnekle çalıştığı için zayıf etiketleri karıştırma isteği burada
    /// daha da güçlü — ve tam da bu yüzden daha tehlikeli: pseudo-label'lar
    /// mevcut modelin tercihini taşır, tuş başına tahmin onu kendi kendine
    /// pekiştirirdi.
    public static func estimate(samples: [CalibrationLearner.Sample],
                                layout: KeyLayout) -> Estimate {
        let keyCount = layout.keys.count
        let rowCount = max(layout.rowCount, 1)

        var out = Estimate(globalX: 0, globalY: 0,
                           rowX: [Double](repeating: 0, count: rowCount),
                           rowY: [Double](repeating: 0, count: rowCount),
                           keyX: [Double](repeating: 0, count: keyCount),
                           keyY: [Double](repeating: 0, count: keyCount),
                           biasX: [Double](repeating: 0, count: keyCount),
                           biasY: [Double](repeating: 0, count: keyCount),
                           strongSamples: 0, isApplicable: false,
                           keysWithOwnLayer: 0, rowsWithOwnLayer: 0,
                           clampedKeys: 0, passes: 0,
                           converged: true, maxDelta: 0)

        var resX: [Double] = [], resY: [Double] = [], key: [Int] = []
        resX.reserveCapacity(samples.count)
        resY.reserveCapacity(samples.count)
        key.reserveCapacity(samples.count)
        for s in usable(samples, layout: layout) {
            let k = layout.keys[s.keyIndex]
            resX.append(s.point.x - k.center.x)
            resY.append(s.point.y - k.center.y)
            key.append(s.keyIndex)
        }
        let n = key.count
        out.strongSamples = n
        guard n > 0 else { return out }

        let row = key.map { layout.rowOfKey[$0] }
        var nKey = [Int](repeating: 0, count: keyCount)
        var nRow = [Int](repeating: 0, count: rowCount)
        for i in 0..<n { nKey[key[i]] += 1; nRow[row[i]] += 1 }

        // İki eksen aynı hiyerarşiyi paylaşır ama bağımsız kestirilir: parmak
        // sağa kayarken yukarı da kaymak zorunda değil. Ölçek eksene göre
        // değişir — `σ_x` tuş genişliğiyle, `σ_y` yüksekliğiyle orantılı.
        let ctx = Context(key: key, row: row, rowOfKey: layout.rowOfKey,
                          nKey: nKey, nRow: nRow,
                          keyCount: keyCount, rowCount: rowCount)
        let x = backfit(res: resX, scale: layout.keys.map(\.width), ctx: ctx)
        let y = backfit(res: resY, scale: layout.keys.map(\.height), ctx: ctx)

        var clamped = 0
        for c in 0..<keyCount {
            let q = layout.rowOfKey[c]
            var bx = x.global + x.row[q] + x.key[c]
            var by = y.global + y.row[q] + y.key[c]

            // Kırpma **tuşun kendi** ölçüsünde ve vektör normu üzerinde —
            // Faz 1'in kuralının tuş başına hâli. Faz 1 tüm layout'un en dar
            // tuşunu kullanmak zorundaydı (tek bir sapma vardı); burada her
            // tuşun sınırı kendi geometrisinden geliyor.
            let w = layout.keys[c].width, h = layout.keys[c].height
            let norm = ((bx / w) * (bx / w) + (by / h) * (by / h)).squareRoot()
            if norm > CalibrationLearner.maxBiasInKeyWidths, norm > 0 {
                let f = CalibrationLearner.maxBiasInKeyWidths / norm
                bx *= f; by *= f
                clamped += 1
            }
            out.biasX[c] = bx; out.biasY[c] = by
        }

        out.globalX = x.global; out.globalY = y.global
        out.rowX = x.row; out.rowY = y.row
        out.keyX = x.key; out.keyY = y.key
        out.isApplicable = n >= CalibrationLearner.minStrongSamples
        // Kapıyı geçen değil, **sıfırdan farklı katsayı alan** birim sayılıyor:
        // ampirik Bayes'te kapıyı geçmek yetmiyor, `τ̂² = 0` çıkarsa katman açık
        // ama katkısı sıfır. Sayacın ne olduğu/olmadığı `Estimate`'te yazılı.
        out.keysWithOwnLayer = (0..<keyCount).filter { x.key[$0] != 0 || y.key[$0] != 0 }.count
        out.rowsWithOwnLayer = (0..<rowCount).filter { x.row[$0] != 0 || y.row[$0] != 0 }.count
        out.clampedKeys = clamped
        out.passes = max(x.passes, y.passes)
        out.converged = x.converged && y.converged
        out.maxDelta = max(x.maxDelta, y.maxDelta)
        return out
    }

    // MARK: - Backfitting

    /// Eksenden bağımsız, örnek başına sabit olan her şey.
    private struct Context {
        let key: [Int]          // örnek → tuş
        let row: [Int]          // örnek → satır
        let rowOfKey: [Int]
        let nKey: [Int]
        let nRow: [Int]
        let keyCount: Int
        let rowCount: Int
    }

    /// Tek eksende backfitting.
    /// - Parameter scale: tuş başına ölçek (x için genişlik, y için yükseklik).
    private static func backfit(res: [Double], scale: [Double], ctx: Context)
        -> (global: Double, row: [Double], key: [Double],
            passes: Int, converged: Bool, maxDelta: Double) {

        let n = res.count
        // Göreli varyans `s²`: artıklar tuş ölçüsüne bölünüp havuzlanır.
        // Tuş **içi** olması şart — tuşlar arası yayılım tam da ayırmak
        // istediğimiz `τ²`'yi içerir, onu gürültü saymak ince katmanı daima
        // sıfırlardı.
        let s2 = pooledRelativeVariance(res, scale: scale, ctx: ctx)

        /// Bir tuş ortalamasının örnekleme varyansı: `σ²_c / n_c`.
        func keyNoise(_ c: Int) -> Double {
            s2 * scale[c] * scale[c] / Double(ctx.nKey[c])
        }
        /// Bir satır ortalamasınınki: satırın tuşları farklı ölçekte olabilir,
        /// bu yüzden `σ²` örnekler üzerinden toplanır.
        var rowScale2 = [Double](repeating: 0, count: ctx.rowCount)
        for i in 0..<n { rowScale2[ctx.row[i]] += scale[ctx.key[i]] * scale[ctx.key[i]] }
        func rowNoise(_ q: Int) -> Double {
            s2 * rowScale2[q] / (Double(ctx.nRow[q]) * Double(ctx.nRow[q]))
        }

        var g = 0.0
        var r = [Double](repeating: 0, count: ctx.rowCount)
        var d = [Double](repeating: 0, count: ctx.keyCount)
        // Yakınsama hem uygulanan toplamı hem **ayrışmayı** izler.
        //
        // Yalnız toplamı izlemek yetmiyordu: `g`, `r` ve `d` birbirini telafi
        // ederek değişirken `g+r+d` sabit kalabilir. `Estimate` ayrışmayı
        // teşhis için yayımladığına göre onun da durulmuş olması gerekiyor.
        // Codex turunda yakalandı.
        var previous = [Double](repeating: .infinity,
                                count: ctx.keyCount + ctx.rowCount + ctx.keyCount + 1)
        var passes = 0
        var maxDelta = Double.infinity
        var converged = false

        let rowOpen = (0..<ctx.rowCount).filter { ctx.nRow[$0] >= minRowSamples }
        let keyOpen = (0..<ctx.keyCount).filter { ctx.nKey[$0] >= minKeySamples }
        let nRowOpen = rowOpen.reduce(0) { $0 + ctx.nRow[$1] }

        while passes < maxPasses {
            passes += 1

            // --- g: geri kalanın açıklayamadığı ortalama artık
            var s = 0.0
            for i in 0..<n { s += res[i] - r[ctx.row[i]] - d[ctx.key[i]] }
            g = shrink(s / Double(n), n: n, kappa: CalibrationLearner.kappa)

            // --- r_row (ampirik Bayes)
            var rs = [Double](repeating: 0, count: ctx.rowCount)
            for i in 0..<n { rs[ctx.row[i]] += res[i] - g - d[ctx.key[i]] }
            var rowMean = [Double](repeating: 0, count: ctx.rowCount)
            for q in rowOpen { rowMean[q] = rs[q] / Double(ctx.nRow[q]) }
            let tau2Row = betweenUnitVariance(mean: rowMean, units: rowOpen,
                                              noise: rowNoise,
                                              minUnits: minRowsForVarianceEstimate)
            r = [Double](repeating: 0, count: ctx.rowCount)
            for q in rowOpen { r[q] = ebShrink(rowMean[q], noise: rowNoise(q), tau2: tau2Row) }

            // --- d_c (ampirik Bayes)
            var ds = [Double](repeating: 0, count: ctx.keyCount)
            for i in 0..<n { ds[ctx.key[i]] += res[i] - g - r[ctx.row[i]] }
            var keyMean = [Double](repeating: 0, count: ctx.keyCount)
            for c in keyOpen { keyMean[c] = ds[c] / Double(ctx.nKey[c]) }
            let tau2Key = betweenUnitVariance(mean: keyMean, units: keyOpen,
                                              noise: keyNoise,
                                              minUnits: minKeysForVarianceEstimate)
            d = [Double](repeating: 0, count: ctx.keyCount)
            for c in keyOpen { d[c] = ebShrink(keyMean[c], noise: keyNoise(c), tau2: tau2Key) }

            // --- Merkezleme, geçişin SONUNDA ve kaba yönde
            //
            // Önce tuş kütlesi kendi satırına, sonra satır kütlesi global'e.
            // Sıra tersine çevrilemez: tuştan satıra itilen kütle satırın
            // ortalamasını değiştirir, o yüzden satır merkezlemesi en son
            // olmalı. İlk uygulamanın hatası tam buydu.
            for q in 0..<ctx.rowCount {
                var sw = 0.0, sn = 0
                for c in keyOpen where ctx.rowOfKey[c] == q {
                    sw += d[c] * Double(ctx.nKey[c]); sn += ctx.nKey[c]
                }
                guard sn > 0 else { continue }
                let m = sw / Double(sn)
                // Satırın kapısı kapalıysa itilecek yer yok; kütle `d`'de
                // kalır. `g`'ye taşımak diğer satırları da kaydırırdı.
                guard ctx.nRow[q] >= minRowSamples else { continue }
                for c in keyOpen where ctx.rowOfKey[c] == q { d[c] -= m }
                r[q] += m
            }
            if nRowOpen > 0 {
                // Payda **açık satırların** örnek sayısı. Tüm örneklerin `n`'i
                // kullanılırsa kapalı satır varlığında ağırlıklı toplam
                // sıfırlanmaz — ilk uygulamanın ikinci hatası.
                var rw = 0.0
                for q in rowOpen { rw += r[q] * Double(ctx.nRow[q]) }
                rw /= Double(nRowOpen)
                for q in rowOpen { r[q] -= rw }
                g += rw
                // Not: bu itme kapalı satırların tuşlarını da `rw` kadar
                // kaydırır. Kasıtlı — kendi kanıtı olmayan satır için havuzlanmış
                // tahmin, sıfırdan iyi bir varsayımdır ("borrow strength").
            }

            // --- Yakınsama: ne toplam ne de bileşenler kayda değer değişmiyorsa dur.
            var state = [Double]()
            state.reserveCapacity(previous.count)
            for c in 0..<ctx.keyCount { state.append(g + r[ctx.rowOfKey[c]] + d[c]) }
            state.append(contentsOf: r)
            state.append(contentsOf: d)
            state.append(g)

            var delta = 0.0
            for i in 0..<state.count { delta = max(delta, abs(state[i] - previous[i])) }
            previous = state
            maxDelta = delta
            if delta < tolerance { converged = true; break }
        }
        return (g, r, d, passes, converged, maxDelta)
    }

    // MARK: - İstatistik

    @inline(__always)
    private static func shrink(_ mean: Double, n: Int, kappa: Double) -> Double {
        Double(n) / (Double(n) + kappa) * mean
    }

    /// Havuzlanmış **göreli** artık varyansı `s²`, `σ²_c = s²·ölçek_c²` olacak
    /// şekilde.
    ///
    /// Artıklar tuş ölçeğine bölünerek havuzlanır; her tuşun kendi ortalaması
    /// etrafındaki kareler toplamı serbestlik derecesine bölünür. Tek örneği
    /// olan tuş paya da paydaya da katkı vermez (0/0 üretirdi).
    private static func pooledRelativeVariance(_ res: [Double], scale: [Double],
                                               ctx: Context) -> Double {
        var sum = [Double](repeating: 0, count: ctx.keyCount)
        for i in 0..<res.count { sum[ctx.key[i]] += res[i] / scale[ctx.key[i]] }
        var ss = 0.0, df = 0
        for i in 0..<res.count where ctx.nKey[ctx.key[i]] >= 2 {
            let c = ctx.key[i]
            let m = sum[c] / Double(ctx.nKey[c])
            let z = res[i] / scale[c] - m
            ss += z * z
        }
        for c in 0..<ctx.keyCount where ctx.nKey[c] >= 2 { df += ctx.nKey[c] - 1 }
        guard df > 0 else { return 0 }
        return ss / Double(df)
    }

    /// `τ²` — katman birimleri **arası** gerçek yayılım, **muhafazakâr** kestirim.
    ///
    /// ```
    /// E[ S²(m_u) ]  =  τ²  +  (1/U) Σ_u v_u        v_u = birim ortalamasının varyansı
    /// ```
    ///
    /// (Türetme: `m_u = θ_u + e_u`, `Var θ = τ²`, `Var e_u = v_u` bağımsız;
    /// örneklem varyansının beklentisi doğrudan bunu verir.)
    ///
    /// ## Neden ham moment farkı yetmiyor
    ///
    /// `max(0, S² − v̄)` doğru bir **nokta** tahminidir ama yanlış bir **kapı**.
    /// Codex turunda yakalandı: gerçek `τ² = 0` iken `S² − v̄` yaklaşık yarı yarıya
    /// pozitif çıkar — `max(0, ·)` yalnız negatif yarıyı kapatır. Yani "yapı yoksa
    /// katman kapanır" garantisi yoktu; katman vakaların ~%50'sinde boşuna
    /// açılıyordu. Tek tohumlu bir testin sıfır vermesi bunu kanıtlamıyordu.
    ///
    /// ## Muhafazakâr indirim — ve neden "güven sınırı" DEMİYORUZ
    ///
    /// Nokta tahmini yerine `S²` bir katsayıyla küçültülüp öyle kullanılıyor:
    ///
    /// ```
    /// τ̂²  =  max( 0,  S²·(U−1) / χ²_{0.90}(U−1)  −  v̄ )
    /// ```
    ///
    /// Katsayının **biçimi** χ²'den geliyor: bağımsız, normal ve ortak varyanslı
    /// birim ortalamaları olsaydı bu `E[S²]`'nin %90 düzeyinde alt güven sınırı
    /// olurdu. Etkisi de istenen yönde — yanlış açılmayı seyrekleştirir,
    /// açıldığında `τ̂²`'yi küçük tutar, dolayısıyla EB katsayısı
    /// `τ̂²/(τ̂²+v_u)` kendiliğinden ihtiyatlı olur.
    ///
    /// **Ama o varsayımların üçü de tam sağlanmıyor** ve bunu iddia etmemek
    /// önemli (Codex turu): `v_u` birimden birime değişiyor, `s²` aynı veriden
    /// kestiriliyor, ve `m_u` backfitting yüzünden bağımsız değil — diğer
    /// katmanın kestirimi çıkarılmış kısmi artıkların ortalaması. Karesel form
    /// tek bir ölçekli `χ²` değil, genelleştirilmiş `χ²` dağılımında.
    /// Dolayısıyla %90 yüzdeliği bir **garanti düzeyi değil**, indirimin ne
    /// kadar sert olacağını belirleyen bir seçim.
    ///
    /// Tam çözüm karışık model likelihood'u (REML) olurdu; bir klavye
    /// uzantısında token sınırında koşacak bir şey değil.
    ///
    /// Garantinin yerini **ölçüm** alıyor: `testFineLayersStayNegligibleUnderTheNull`
    /// null altında — dengeli ve dengesiz örnek dağılımlarında — sahte ince
    /// katsayıların büyüklüğünü doğrudan sayıyor. İddia edilen şey o testin
    /// ölçtüğüyle sınırlı: sahte sapmalar tuşun %2'sini geçmiyor.
    private static func betweenUnitVariance(mean: [Double], units: [Int],
                                            noise: (Int) -> Double,
                                            minUnits: Int) -> Double {
        guard units.count >= minUnits, units.count >= 2 else { return 0 }
        // Ağırlıksız moment tahmini: `τ²` birimlere ait bir büyüklük, örneklere
        // değil. Örnek sayısıyla ağırlıklandırmak çok yazılan tuşları öne
        // çıkarır ve `τ²`'yi onların yayılımına indirger.
        var m = 0.0
        for u in units { m += mean[u] }
        m /= Double(units.count)
        var v = 0.0
        for u in units { v += (mean[u] - m) * (mean[u] - m) }
        v /= Double(units.count - 1)

        var noiseMean = 0.0
        for u in units { noiseMean += noise(u) }
        noiseMean /= Double(units.count)

        let df = units.count - 1
        let lowerBound = v * Double(df) / chiSquare90thPercentile(df: df)
        return max(0, lowerBound - noiseMean)
    }

    /// `χ²`'nin **%90'lık** yüzdeliği — muhafazakârlık seviyesi burada sabit.
    ///
    /// Ayrı bir `α` sabiti vardı ve **hesapta hiç kullanılmıyordu**: tablo da
    /// `z` de doğrudan 0.90'a gömülüydü, yani sabiti değiştirmek davranışı
    /// değiştirmiyordu. Sahte yapılandırılabilirlik, sabitin kendisinden daha
    /// kötü — okuyana ayarlanabilir bir şey olduğunu söylüyor. Codex turunda
    /// yakalandı; sabit kaldırıldı ve seviye fonksiyonun **adına** taşındı.
    ///
    /// Seviye değişecekse hem tablo hem `z` birlikte değişmeli.
    ///
    /// Küçük `df` **tablodan**, büyüğü Wilson–Hilferty yaklaşımından:
    ///
    /// ```
    /// χ²_p(k) ≈ k · ( 1 − 2/(9k) + z_p·√(2/(9k)) )³
    /// ```
    ///
    /// Tablo bir ihtiyat değil, düzeltme. WH `df = 2`'de 4.16 veriyor, doğrusu
    /// 4.61 — %10 küçük, yani alt sınır olması gerekenden **gevşek**. Satır
    /// katmanının `df`'i üretim layout'unda tam olarak 2 (üç satır), yani hatanın
    /// düştüğü yer en çok önem taşıdığı yer. Null testinde ölçüldü ve düzeltildi.
    ///
    /// `df ≥ 9`'da WH'nin hatası %1'in altında; orada tablo taşımaya değmez.
    private static func chiSquare90thPercentile(df: Int) -> Double {
        // χ²_{0.90}
        let exact = [0.0, 2.706, 4.605, 6.251, 7.779, 9.236, 10.645, 12.017, 13.362]
        if df >= 1, df < exact.count { return exact[df] }
        // z_{0.90} = 1.2816 — aynı seviyenin normal quantile'ı.
        let z = 1.2816
        let k = Double(df)
        let a = 2.0 / (9.0 * k)
        let t = 1.0 - a + z * a.squareRoot()
        return max(k * t * t * t, 1e-12)
    }

    /// James–Stein biçimi shrinkage: `τ² / (τ² + v_u)`.
    @inline(__always)
    private static func ebShrink(_ mean: Double, noise: Double, tau2: Double) -> Double {
        guard tau2 > 0 else { return 0 }
        return tau2 / (tau2 + noise) * mean
    }

    // MARK: - Invariantlar (test kapısı)

    /// Merkezleme invariantlarının artıkları — hepsi 0 olmalı.
    ///
    /// Belgelenmiş bir kısıt test edilmiyorsa yoktur: ilk uygulamada bu
    /// invariantlar yorumda yazılıydı ama kodda tutmuyordu. Tahmincinin
    /// içinden hesaplanabilir olması yetmez, dışarıdan **doğrulanabilir**
    /// olmalı.
    ///
    /// `internal`: bu bir test kapısı, ürün API'si değil. Public olsaydı
    /// çağıranın uyması gereken bir sözleşme gibi görünürdü.
    ///
    /// - Returns: `(satır, satır başına en büyük tuş artığı)`.
    static func invariants(_ e: Estimate, layout: KeyLayout,
                           samples: [CalibrationLearner.Sample])
        -> (rowResidualX: Double, rowResidualY: Double,
            keyResidualX: Double, keyResidualY: Double) {

        var nKey = [Int](repeating: 0, count: layout.keys.count)
        var nRow = [Int](repeating: 0, count: max(layout.rowCount, 1))
        for s in usable(samples, layout: layout) {
            nKey[s.keyIndex] += 1
            nRow[layout.rowOfKey[s.keyIndex]] += 1
        }

        var rx = 0.0, ry = 0.0
        for q in 0..<nRow.count where nRow[q] >= minRowSamples {
            rx += e.rowX[q] * Double(nRow[q])
            ry += e.rowY[q] * Double(nRow[q])
        }

        var kx = 0.0, ky = 0.0
        for q in 0..<nRow.count {
            var sx = 0.0, sy = 0.0
            for c in 0..<layout.keys.count
            where layout.rowOfKey[c] == q && nKey[c] >= minKeySamples {
                sx += e.keyX[c] * Double(nKey[c])
                sy += e.keyY[c] * Double(nKey[c])
            }
            // Kapalı satırda tuş kütlesi bilerek merkezlenmiyor (itilecek üst
            // katman yok); invariant yalnız açık satırlar için iddia edilir.
            guard nRow[q] >= minRowSamples else { continue }
            kx = max(kx, abs(sx)); ky = max(ky, abs(sy))
        }
        return (rx, ry, kx, ky)
    }
}
