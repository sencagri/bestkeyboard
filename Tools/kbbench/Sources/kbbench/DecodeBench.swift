import Foundation
import KBDecoder
import KBGeometry
import KBToolSupport

/// Kod çözme doğruluğu ve gecikmesi — varsayılan kip.
///
/// Raporlanan metrikler:
///   - top-1 / top-3 doğruluk
///   - temiz yazımda top-1 hatası (yanlış düzeltme **değil** — bkz. aşağısı)
///   - aday uzunluğuna göre hata dağılımı (uzunluk yanlılığı görünür olsun)
///   - tuş başına p50/p95/p99/max gecikme
///
/// ÖNEMLİ: doğruluk sayıları **simüle edilmiş** dokunmalardan gelir ve model
/// doğrulaması DEĞİLDİR (§9). Gerçek kapı gerçek dokunma verisiyle kurulacak.
/// Buradaki değer regresyon tespiti ve parametre taramasıdır.
enum DecodeBench {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        let words = ctx.words
        let decoder = ctx.makeDecoder()
        var sim = ctx.makeSimulator(seed: opt.seed)

        // Isınma — ilk çağrılar sayfa hatası ve tembel kurulum içerir.
        // AYRI bir PRNG kullanılır: aynı simülatörü tüketmek `--warmup` değişince
        // ölçülen dokunma setini de değiştiriyordu, yani karşılaştırmalar bozuluyordu.
        var warmSim = ctx.makeSimulator(seed: opt.seed &+ 999, withBias: false)
        for (w, _) in words.prefix(opt.warmup) {
            if let t = warmSim.touches(for: w) { _ = decoder.decode(touches: t, topK: 3) }
        }

        var top1 = 0, top3 = 0, attempted = 0, skipped = 0
        var latencies: [Double] = []
        /// **Gerçek** tuş başına gecikme: her `append` ayrı ölçülür.
        /// Önceki sürüm kelime süresini dokunma sayısına bölüyordu — bu bir
        /// ORTALAMA; pahalı ilk adımı uzun kelimelerde seyreltiyor ve tek bir
        /// tuşun kuyruğunu gizliyordu. p99 iddiası bu yüzden yanlıştı.
        var appendLatencies: [Double] = []
        var resultsLatencies: [Double] = []
        /// Temiz yazımda top-1 hatası. **Bu YANLIŞ DÜZELTME DEĞİLDİR** — commit
        /// kararı (`Δ > θ`, literal kanalı, kişisel sözlük koruması) burada hiç
        /// çalışmıyor. Gerçek yanlış düzeltme ancak commit politikası ölçülerek
        /// raporlanabilir.
        var cleanAttempts = 0, cleanTop1Errors = 0
        /// Uzunluğa göre hata: [uzunluk: (deneme, hata)]
        var byLength: [Int: (Int, Int)] = [:]
        /// Darboğaz teşhisi: kelime başına üretilen durum ve bunların kaçının
        /// omission kapanışından geldiği.
        var statesTotal = 0, omissionTotal = 0, subTotal = 0, trTotal = 0, touchTotal = 0

        // Çok az gürültü: "doğru yazılmış" senaryo.
        var cleanSim = TouchSimulator.clean(layout: ctx.layout, seed: opt.seed &+ 1,
                                            sigmaScale: 0.12)

        for (word, _) in words {
            guard let touches = sim.touches(for: word) else { skipped += 1; continue }
            attempted += 1

            let t0 = Stopwatch()
            var inc = IncrementalDecoder(decoder: decoder)
            for t in touches {
                let a0 = Stopwatch()
                inc.append(t)
                appendLatencies.append(a0.elapsedMs)
            }
            let r0 = Stopwatch()
            let results = inc.results(topK: 3)
            resultsLatencies.append(r0.elapsedMs)
            let ms = t0.elapsedMs
            statesTotal += inc.statesCreated
            omissionTotal += inc.omissionStates
            subTotal += inc.subStates
            trTotal += inc.transpositionStates
            touchTotal += touches.count
            latencies.append(ms)

            let names = results.map(\.word)
            if names.first == word { top1 += 1 }
            if names.contains(word) { top3 += 1 }

            let len = word.count
            var e = byLength[len] ?? (0, 0)
            e.0 += 1
            if names.first != word { e.1 += 1 }
            byLength[len] = e

            // Yanlış düzeltme ölçümü: neredeyse mükemmel yazımda bile bozuluyor mu?
            if let clean = cleanSim.touches(for: word) {
                cleanAttempts += 1
                if decoder.decode(touches: clean, topK: 1).first?.word != word { cleanTop1Errors += 1 }
            }
        }

        // Hiç kelime denenemediyse yüzdelikler tanımsız (`NaN`) ve JSON onları
        // taşıyamaz; sıfır basmak da "gecikme yok" diye okunurdu.
        guard attempted > 0 else { fail("hiçbir test kelimesi layout'ta yazılamadı") }

        latencies.sort()
        appendLatencies.sort()
        resultsLatencies.sort()

        let acc1 = Double(top1) / Double(max(attempted, 1)) * 100
        let acc3 = Double(top3) / Double(max(attempted, 1)) * 100
        let cleanErrRate = Double(cleanTop1Errors) / Double(max(cleanAttempts, 1)) * 100

        if opt.json {
            let obj: [String: Any] = [
                "words": attempted, "skipped": skipped,
                "top1": acc1, "top3": acc3,
                // Adı bilinçli: bu commit kararını ölçmüyor (bkz. yorum).
                "cleanTop1ErrorRate": cleanErrRate,
                "falseCorrectionRate": "unavailable — commit politikası ölçülmüyor",
                "latencyMs": ["p50": percentile(latencies, 0.50),
                              "p95": percentile(latencies, 0.95),
                              "p99": percentile(latencies, 0.99),
                              "max": latencies.last ?? 0],
                "appendMs": ["p50": percentile(appendLatencies, 0.50),
                             "p95": percentile(appendLatencies, 0.95),
                             "p99": percentile(appendLatencies, 0.99),
                             "max": appendLatencies.last ?? 0],
                "resultsMs": ["p50": percentile(resultsLatencies, 0.50),
                              "p99": percentile(resultsLatencies, 0.99)],
                "beam": opt.beamWidth, "morphology": opt.morphology, "seed": opt.seed,
                "roots": ctx.morphology?.roots.count ?? 0,
                "maxOmissions": opt.maxOmissions,
                "statesPerKeystroke": Double(statesTotal) / Double(max(touchTotal, 1)),
                "omissionShare": Double(omissionTotal) / Double(max(statesTotal, 1)),
                "subShare": Double(subTotal) / Double(max(statesTotal, 1)),
                "trShare": Double(trTotal) / Double(max(statesTotal, 1)),
            ]
            let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return 0
        }

        print("""

        ┌─ kbbench ─────────────────────────────────────────────
        │ paket      : \(opt.packPath)
        │ kelime     : \(attempted) denendi, \(skipped) atlandı (layout'ta yok)
        │ beam       : \(opt.beamWidth)   morfoloji: \(opt.morphology ? "açık" : "kapalı")
        │ gürültü    : σ=\(opt.sigma)  sapma=(\(opt.biasX), \(opt.biasY))  tohum=\(opt.seed)
        ├─ doğruluk ────────────────────────────────────────────
        │ top-1      : \(String(format: "%.1f%%", acc1))
        │ top-3      : \(String(format: "%.1f%%", acc3))
        │ temiz yazımda top-1 hatası : \(String(format: "%.2f%%", cleanErrRate))
        │   (bu YANLIŞ DÜZELTME DEĞİL — commit kararı ölçülmüyor)
        ├─ gecikme (kelime başına) ─────────────────────────────
        │ p50 \(String(format: "%7.2f", percentile(latencies, 0.50))) ms   \
        p95 \(String(format: "%7.2f", percentile(latencies, 0.95))) ms
        │ p99 \(String(format: "%7.2f", percentile(latencies, 0.99))) ms   \
        max \(String(format: "%7.2f", latencies.last ?? 0)) ms
        ├─ iş miktarı (darboğaz teşhisi) ───────────────────────
        │ tuş başına üretilen durum : \(String(format: "%.0f", Double(statesTotal) / Double(max(touchTotal, 1))))
        │ bunların omission payı    : \(String(format: "%.1f%%", Double(omissionTotal) / Double(max(statesTotal, 1)) * 100))
        ├─ gecikme (TUŞ başına, GERÇEK append — bütçe p99 < 8 ms) ─
        │ p50 \(String(format: "%7.3f", percentile(appendLatencies, 0.50))) ms   \
        p95 \(String(format: "%7.3f", percentile(appendLatencies, 0.95))) ms
        │ p99 \(String(format: "%7.3f", percentile(appendLatencies, 0.99))) ms   \
        max \(String(format: "%7.3f", appendLatencies.last ?? 0)) ms
        │ öneri okuma p99: \(String(format: "%.3f", percentile(resultsLatencies, 0.99))) ms
        └───────────────────────────────────────────────────────
        """)

        print("\n uzunluğa göre top-1 hata oranı (uzunluk yanlılığı görünür olsun):")
        for len in byLength.keys.sorted() {
            let (n, err) = byLength[len]!
            guard n >= 5 else { continue }
            let rate = Double(err) / Double(n) * 100
            let bar = String(repeating: "█", count: Int(rate / 3))
            print(String(format: "   %2d harf  %4d kelime  %5.1f%%  %@", len, n, rate, bar))
        }

        print("""

         UYARI: doğruluk sayıları SİMÜLE edilmiş dokunmalardan geliyor. Gaussian bir
         decoder'ı Gaussian gürültüyle sınamak model doğrulaması değildir (§9).
         Bu araç regresyon tespiti ve parametre taraması içindir; gerçek doğruluk
         kapısı gerçek dokunma verisiyle kurulacak.
        """)
        return 0
    }
}
