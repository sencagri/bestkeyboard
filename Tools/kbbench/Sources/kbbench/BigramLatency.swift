import Foundation
import KBDecoder
import KBLexicon
import KBToolSupport

/// Bigram gecikmesi (§2 öznitelik 13)
///
/// **Doğruluk değil, gecikme.** `F_ctx`'in doğruluk kapısı gerçek bigram verisi
/// olmadan kurulamaz; ama gecikme veriye değil **tablo boyutuna** bağlı, ve
/// sözleşme tuş başına p99 < 8 ms istiyor. Sentetik bir paket bu soruyu dürüstçe
/// yanıtlıyor: deltaların gerçek olup olmaması arama maliyetini değiştirmiyor.
///
/// Terim **terminal** (§3.2): beam genişletmesine girmiyor, yalnız `results()`
/// aday materyalize ederken sorgulanıyor. Beklenti bu yüzden "ölçülemeyecek
/// kadar küçük" — ölçüm o beklentiyi sınıyor.
enum BigramLatency {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        let words = ctx.words
        print("\n=== bigram gecikmesi (§2 öznitelik 13) ===")

        // Sentetik paket: gerçek yüzeyler (paketten), uydurma sayımlar. Yüzeyleri
        // uydurmak tablo boyutunu doğru verir ama arama **bulamaz** ve dallanma
        // ölçümü kolaylaşırdı; gerçek yüzeylerle sorgular gerçekten isabet ediyor.
        let vocab = words.map(\.0)
        var unigrams: [String: Double] = [:]
        for (w, c) in words { unigrams[w] = max(c, 1) }
        var pairs: [BigramCount] = []
        pairs.reserveCapacity(opt.bigramPairs)
        // Xorshift — `SplitMix64` ile değiştirilmedi: çiftler bu diziden çekiliyor
        // ve üretecin değişmesi sentetik paketin boyutunu (raporlanan yüzey/çift
        // sayısı) değiştirirdi.
        var seed: UInt64 = opt.seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        while pairs.count < opt.bigramPairs && vocab.count > 1 {
            let a = vocab[Int(next() % UInt64(vocab.count))]
            let b = vocab[Int(next() % UInt64(vocab.count))]
            pairs.append(BigramCount(context: a, word: b, count: Double(2 + next() % 50)))
        }
        guard let built = try? BigramPackBuilder().build(unigrams: unigrams, bigrams: pairs),
              let pack = try? BigramPack(packData: Data(built.bytes)) else {
            fail("sentetik bigram paketi kurulamadı")
        }
        print("""
          sentetik paket: \(built.report.surfaces) yüzey · \(built.report.pairs) çift · \
        \(String(format: "%.1f", Double(built.bytes.count) / 1024 / 1024)) MB
        """)

        func perKey(_ decoder: Decoder) -> (p50: Double, p99: Double) {
            var sim = ctx.makeSimulator(seed: opt.seed, withBias: false)
            var samples: [Double] = []
            for (w, _) in words.prefix(600) {
                guard let t = sim.touches(for: w) else { continue }
                var inc = IncrementalDecoder(decoder: decoder)
                for touch in t {
                    let t0 = Stopwatch()
                    inc.append(touch)
                    // Öneri okuma **ölçüme dahil**: `F_ctx` tam da orada
                    // uygulanıyor ve yalnız `append`'i ölçmek terimi ölçüm dışında
                    // bırakırdı.
                    _ = inc.results(topK: 3)
                    samples.append(t0.elapsedMs)
                }
            }
            samples.sort()
            return (percentile(samples, 0.50), percentile(samples, 0.99))
        }

        let decoder = ctx.makeDecoder()
        let without = perKey(decoder)
        var withPack = decoder
        withPack.bigrams = pack
        // Bağlam **isabet eden** bir yüzey: `nil` bırakmak aramayı hiç yapmamak
        // olurdu ve ölçüm terimi atlardı.
        withPack.contextWord = vocab.first
        let with = perKey(withPack)

        print(String(format: "  tuş başına p50: %.3f ms → %.3f ms  (%+.3f)",
                     without.p50, with.p50, with.p50 - without.p50))
        print(String(format: "  tuş başına p99: %.3f ms → %.3f ms  (%+.3f)",
                     without.p99, with.p99, with.p99 - without.p99))
        print("  sözleşme kapısı: p99 < 8 ms — "
              + (with.p99 < 8 ? "geçti" : "KALDI"))
        return 0
    }
}
