import Foundation

/// §5.4/4: aday budaması bir ARAMA sezgiseli; getirdiği yaklaşım payı
/// doğruluktan AYRI raporlanmalı. Oracle kapısında kapatılıyor olması,
/// üretimde açıkken ne kaybettirdiğini söylemez.
enum PruningGap {

    static func run(_ ctx: BenchContext) -> Int32 {
        let decoder = ctx.makeDecoder()
        let exact = ctx.makeDecoder(disableCandidatePruning: true)
        var targetLost = 0, top1Changed = 0, compared = 0
        var regretSum = 0.0, regretMax = 0.0
        var gapSim = ctx.makeSimulator(seed: ctx.options.seed)

        for (word, _) in ctx.words {
            guard let t = gapSim.touches(for: word) else { continue }
            let pruned = decoder.decode(touches: t, topK: 3)
            let full = exact.decode(touches: t, topK: 3)
            compared += 1
            if pruned.first?.word != full.first?.word { top1Changed += 1 }
            // Hedef kelime budamasız bulunuyorken budamalıda kayboluyor mu?
            let inFull = full.map(\.word).contains(word)
            let inPruned = pruned.map(\.word).contains(word)
            if inFull && !inPruned { targetLost += 1 }
            // Maliyet pişmanlığı: budamalı top-1 ne kadar daha pahalı?
            if let p = pruned.first, let f = full.first {
                let regret = p.cost - f.cost
                regretSum += max(0, regret)
                regretMax = max(regretMax, regret)
            }
        }
        print("""

        ┌─ aday budaması yaklaşım payı (§5.4/4) ────────────────
        │ karşılaştırılan     : \(compared) kelime
        │ top-1 değişti       : \(top1Changed) (\(String(format: "%.2f%%", Double(top1Changed) / Double(max(compared,1)) * 100)))
        │ hedef KAYBOLDU      : \(targetLost) (\(String(format: "%.2f%%", Double(targetLost) / Double(max(compared,1)) * 100)))
        │ ortalama pişmanlık  : \(String(format: "%.4f", regretSum / Double(max(compared,1)))) nat
        │ en kötü pişmanlık   : \(String(format: "%.4f", regretMax)) nat
        └───────────────────────────────────────────────────────
        """)
        return 0
    }
}
