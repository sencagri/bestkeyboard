import Foundation
import KBToolSupport

/// Beam genişliği taraması — §9: `surfaceId`'nin tuttuğu yuvalar aday
/// kaybettiriyor mu?
///
/// Doğrudan ölçülemeyen bir şeyi dolaylı ama kesin bir soruyla yerine koyuyor.
/// "surfaceId olmasaydı ne olurdu" sorusu koşulamaz (anahtardan çıkarmak
/// `reconstruct`'ı bozar, §4.2). Ama fragmentasyonun **zararlı** olması için
/// beam'in bağlıyor olması gerekir: yuvalar ancak dolu bir beam'de birbirinin
/// yerini alır. Beam genişletilince doğruluk artmıyorsa beam bağlamıyor,
/// dolayısıyla fragmentasyonun ölçülebilir bedeli yok.
///
/// Bu bir eşdeğerlik iddiası değil bir **eleme**: "beam bağlamıyor" ifadesi
/// "surfaceId bedava" demek değil, "bugünkü genişlikte bedeli görünmüyor" demek.
enum BeamSweep {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        var widths = Set(opt.beamSweepWidths)
        widths.insert(opt.beamWidth)          // üretim değeri her hâlde taransın
        var rows: [(Int, Double, Double, Double)] = []
        for w in widths.sorted() {
            let d = ctx.makeDecoder(beamWidth: w)
            // **Aynı dokunmalar.** Simülatör her genişlik için sıfırdan aynı
            // tohumla kuruluyor; paylaşılan bir simülatör tüketildiği için ikinci
            // genişlik başka bir dokunma seti görürdü ve fark "beam" diye okunurdu.
            var s = ctx.makeSimulator(seed: opt.seed)
            var hit1 = 0, hit3 = 0, n = 0
            var ms = 0.0
            for (word, _) in ctx.words {
                guard let t = s.touches(for: word) else { continue }
                n += 1
                let t0 = Stopwatch()
                let r = d.decode(touches: t, topK: 3).map(\.word)
                ms += t0.elapsedMs
                if r.first == word { hit1 += 1 }
                if r.contains(word) { hit3 += 1 }
            }
            let den = Double(max(n, 1))
            rows.append((w, Double(hit1) / den * 100, Double(hit3) / den * 100, ms / den))
        }

        let base = rows.first(where: { $0.0 == opt.beamWidth })?.1 ?? 0
        let best = rows.map(\.1).max() ?? 0
        print("""

        ┌─ beam genişliği taraması (§9) ─────────────────────────
        │ genişlik    top-1     top-3    kelime başına
        """)
        for (w, a1, a3, ms) in rows {
            let mark = w == opt.beamWidth ? " ←üretim" : ""
            // Çok satırlı literal kapanış girintisini kırpıyor; buradaki satır
            // kırpılmıyor. Dört boşluk eklemek kutuyu bozardı.
            print(String(format: "│ %7d   %6.2f%%  %6.2f%%   %7.3f ms%@",
                         w, a1, a3, ms, mark))
        }
        print("""
        │
        │ üretim genişliğinde top-1 : \(String(format: "%.2f%%", base))
        │ taramadaki en iyi top-1   : \(String(format: "%.2f%%", best))
        │ beam'in bıraktığı pay     : \(String(format: "%+.2f puan", best - base))
        └────────────────────────────────────────────────────────
        """)
        return 0
    }
}
