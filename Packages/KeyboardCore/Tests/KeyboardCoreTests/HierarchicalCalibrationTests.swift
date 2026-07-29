import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLearning

/// Hiyerarşik kalibrasyon — sözleşme §8.6, plan §3 Faz 3.
///
/// Testlerin varlık sebebi doğrudan bir bulgu: ilk uygulamada merkezleme
/// invariantları **yorumda yazılıydı ama kodda tutmuyordu**, ve satır katmanı
/// üretim layout'unda tamamen kapalıydı. İkisi de tek bir test olmadığı için
/// sessiz kalmıştı. Belgelenmiş bir kısıt test edilmiyorsa yoktur.
final class HierarchicalCalibrationTests: XCTestCase {

    private let layout = TurkishQ.layout()

    private struct PRNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u1 = max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// Katmanlı sapmayla sentetik örnek üretir; her tuşa `perKey` örnek.
    ///
    /// - Parameters:
    ///   - global: her tuşa uygulanan sabit kayma (normalize koordinat).
    ///   - row: satır başına ek kayma; kısa dizide eksikler 0.
    ///   - key: tuş başına ek kayma.
    ///   - sigma: gürültü, **tuş ölçüsü oranında** — `SpatialModel` yayılımı
    ///     böyle kurduğu için tahmincinin heteroskedastik varsayımı da bu.
    private func samples(global: (x: Double, y: Double) = (0, 0),
                         row: [(x: Double, y: Double)] = [],
                         key: [(x: Double, y: Double)] = [],
                         sigma: Double = 0.25,
                         perKey: Int = 60,
                         keys: [Int]? = nil,
                         seed: UInt64 = 7)
        -> [CalibrationLearner.Sample] {
        var rng = PRNG(state: seed)
        var out: [CalibrationLearner.Sample] = []
        for k in keys ?? Array(layout.keys.indices) {
            let c = layout.keys[k], q = layout.rowOfKey[k]
            let rx = q < row.count ? row[q].x : 0
            let ry = q < row.count ? row[q].y : 0
            let kx = k < key.count ? key[k].x : 0
            let ky = k < key.count ? key[k].y : 0
            for _ in 0..<perKey {
                let p = Point(x: c.center.x + global.x + rx + kx + sigma * c.width * rng.gaussian(),
                              y: c.center.y + global.y + ry + ky + sigma * c.height * rng.gaussian())
                out.append(.init(point: p, keyIndex: k, confidence: .strong))
            }
        }
        return out
    }

    /// Gerçekçi biçimde **dengesiz** örnek dağılımı: bazı tuşlar çok yazılır,
    /// bazıları kapının hemen üstünde kalır. Kapı altına da düşen tuşlar var.
    private func unbalancedSamples(global: (x: Double, y: Double),
                                   seed: UInt64) -> [CalibrationLearner.Sample] {
        var rng = PRNG(state: seed &+ 31)
        var out: [CalibrationLearner.Sample] = []
        for k in layout.keys.indices {
            let c = layout.keys[k]
            // 5 (kapı altı) ile 300 arası; Zipf'e benzer biçimde birkaç tuş baskın.
            let count = [5, 12, 21, 25, 40, 90, 300][k % 7]
            for _ in 0..<count {
                out.append(.init(point: Point(x: c.center.x + global.x + 0.25 * c.width * rng.gaussian(),
                                              y: c.center.y + global.y + 0.25 * c.height * rng.gaussian()),
                                 keyIndex: k, confidence: .strong))
            }
        }
        return out
    }

    private func estimate(_ s: [CalibrationLearner.Sample]) -> HierarchicalCalibration.Estimate {
        HierarchicalCalibration.estimate(samples: s, layout: layout)
    }

    // MARK: - Satır türetme

    func testTurkishQDerivesThreeLetterRows() {
        XCTAssertEqual(layout.rowCount, 3)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "q")!], 0)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "ü")!], 0)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "a")!], 1)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "i")!], 1)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "z")!], 2)
        XCTAssertEqual(layout.rowOfKey[layout.keyIndex(for: "ç")!], 2)
    }

    /// Satır kümelemesi tuş yüksekliğinin yarısını eşik alıyor; aynı satırın
    /// tuşları birkaç noktalık farkla yerleşse de bölünmemeli.
    func testSmallVerticalJitterDoesNotSplitARow() {
        let keys = (0..<6).map { i in
            Key(char: Character(UnicodeScalar(97 + i)!),
                center: Point(x: (Double(i) + 0.5) / 6, y: 0.5 + Double(i) * 0.01),
                width: 1.0 / 6, height: 0.25)
        }
        let l = KeyLayout(id: "t", keys: keys, asciiBase: [:])
        XCTAssertEqual(l.rowCount, 1)
    }

    func testSingleKeyLayoutHasOneRow() {
        let l = KeyLayout(id: "t",
                          keys: [Key(char: "a", center: Point(x: 0.5, y: 0.5),
                                     width: 1, height: 1)],
                          asciiBase: [:])
        XCTAssertEqual(l.rowCount, 1)
        XCTAssertEqual(l.rowOfKey, [0])
    }

    // MARK: - Geri kazanım

    /// Saf global sapmada global katman öğrenilmeli.
    func testPureGlobalBiasIsRecoveredByTheGlobalLayer() {
        let e = estimate(samples(global: (0.010, 0.008)))
        XCTAssertTrue(e.isApplicable)
        XCTAssertGreaterThan(e.globalX, 0.004)
        XCTAssertGreaterThan(e.globalY, 0.003)
    }

    /// **Null testi:** gerçekten ince yapı yokken ince katmanlar zarar
    /// verecek büyüklükte açılmamalı.
    ///
    /// Bu test doğrudan bir bulgunun karşılığı. Önceki sürüm `τ̂² = max(0, S²−v̄)`
    /// kullanıyordu ve tek tohumlu bir test sıfır verdiği için "yapı yoksa
    /// katman kapanır" diye yazılmıştı. Oysa null altında `S²−v̄` yaklaşık yarı
    /// yarıya pozitif çıkar: garanti yoktu, tohum şanslıydı.
    ///
    /// **Metrik ikili bayrak DEĞİL, büyüklük.** İlk yazılışı "katman açıldı mı"
    /// sayıyordu ve 40 denemenin 14'ünde açık buluyordu — ama ölçünce katsayıların
    /// tuşun **%1'i** mertebesinde olduğu görüldü, yani bayrak zararı değil
    /// duyarlılığı ölçüyordu. Klavyeyi etkileyen şey katsayının büyüklüğü.
    ///
    /// Alt güven sınırının işi tam olarak bu: açılmayı imkânsız kılmak değil,
    /// açıldığında `τ̂²`'yi küçük tutmak. Ölçülen sonuç: 40 denemede kayda değer
    /// (> tuşun %2'si) sahte sapma satırda 1, tuşta 0 kez; en büyüğü %2.
    func testFineLayersStayNegligibleUnderTheNull() {
        let w = layout.keys.map(\.width).min()!
        let h = layout.keys.map(\.height).min()!
        /// Altında hiçbir etkisi olamayacak eşik: tipik bir tuş ~30 pt, %2'si
        /// yarım punto.
        let negligible = 0.02

        var materialRow = 0, materialKey = 0, worst = 0.0
        let trials = 40
        for seed in 0..<trials {
            // Yarı yarıya dengeli ve **dengesiz** örnek dağılımı. Dengesizlik
            // asıl zor durum: `v_u` birimden birime değişince tek ölçekli χ²
            // varsayımı en çok orada zorlanıyor, ve gerçek kullanımda tuş
            // frekansları Zipf'e yakın — dengeli dağılım gerçekçi değil.
            let s = seed % 2 == 0
                ? samples(global: (0.010, 0.008), seed: UInt64(seed))
                : unbalancedSamples(global: (0.010, 0.008), seed: UInt64(seed))
            let e = estimate(s)
            let rowMax = max(e.rowX.map { abs($0) / w }.max() ?? 0,
                             e.rowY.map { abs($0) / h }.max() ?? 0)
            let keyMax = max(e.keyX.map { abs($0) / w }.max() ?? 0,
                             e.keyY.map { abs($0) / h }.max() ?? 0)
            if rowMax > negligible { materialRow += 1 }
            if keyMax > negligible { materialKey += 1 }
            worst = max(worst, max(rowMax, keyMax))
        }
        XCTAssertLessThanOrEqual(Double(materialRow) / Double(trials), 0.10,
                                 "satır katmanı \(materialRow)/\(trials) kez kayda değer açıldı")
        XCTAssertLessThanOrEqual(Double(materialKey) / Double(trials), 0.10,
                                 "tuş katmanı \(materialKey)/\(trials) kez kayda değer açıldı")
        // Kuyruk da sınırlı olmalı: nadir ama büyük bir sahte sapma, sık ama
        // küçük olandan daha zararlıdır.
        XCTAssertLessThan(worst, 0.05, "en büyük sahte sapma \(worst) tuş")
    }

    /// Saf satır etkisi satır katmanında görünmeli — üretim layout'unda **üç**
    /// satır var, `minRowsForVarianceEstimate` bu yüzden 3.
    ///
    /// Ortak eşik 4 iken bu test kırmızıydı: satır katmanı hiç öğrenilmiyordu
    /// ve etki tuş katmanına sızıyordu.
    func testPureRowEffectIsCapturedByTheRowLayer() {
        let rows: [(x: Double, y: Double)] = [(-0.012, 0), (0, 0), (0.012, 0)]
        for seed in [7, 101, 2027, 55_555] as [UInt64] {
            let e = estimate(samples(row: rows, sigma: 0.20, seed: seed))
            XCTAssertGreaterThan(e.rowsWithOwnLayer, 0, "seed \(seed)")
            // Yön korunmalı: üst satır sola, alt satır sağa.
            XCTAssertLessThan(e.rowX[0], 0, "seed \(seed)")
            XCTAssertGreaterThan(e.rowX[2], 0, "seed \(seed)")

            // Büyüklük: shrinkage yüzünden eksik kalır ama etkinin kayda değer
            // bir kısmı yakalanmalı. Yalnız yön kontrol etmek, etkinin %95'i
            // kaybolsa bile geçerdi.
            XCTAssertGreaterThan(e.rowX[2] - e.rowX[0], 0.5 * 0.024, "seed \(seed)")

            // Tuş katmanı bu etkiyi ÜSTLENMEMELİ: satır etkisi tuşa yazılırsa
            // ayrışma anlamını yitirir. Enerji oranıyla ölçülüyor, tek tuşun
            // maksimumuyla değil.
            let rowEnergy = e.rowX.reduce(0) { $0 + $1 * $1 } / Double(e.rowX.count)
            let keyEnergy = e.keyX.reduce(0) { $0 + $1 * $1 } / Double(e.keyX.count)
            XCTAssertLessThan(keyEnergy, 0.25 * rowEnergy, "seed \(seed)")
        }
    }

    func testPureKeyEffectIsCapturedByTheKeyLayer() {
        var key = [(x: Double, y: Double)](repeating: (0, 0), count: layout.keys.count)
        var rng = PRNG(state: 99)
        for i in key.indices { key[i] = (0.012 * rng.gaussian(), 0) }
        let e = estimate(samples(key: key, sigma: 0.18, perKey: 90))
        XCTAssertGreaterThan(e.keysWithOwnLayer, layout.keys.count / 2)
        // İşaret uyumu: gerçekten büyük sapmalı tuşlarda yön doğru olmalı.
        var agree = 0, total = 0
        for i in key.indices where abs(key[i].x) > 0.010 {
            total += 1
            if key[i].x * e.keyX[i] > 0 { agree += 1 }
        }
        XCTAssertGreaterThan(total, 4)
        XCTAssertGreaterThan(Double(agree) / Double(total), 0.8)
    }

    // MARK: - Merkezleme invariantları

    /// `Σ n_q·r_q = 0` ve her açık satırda `Σ n_c·d_c = 0`.
    ///
    /// İlk uygulamada bu **tutmuyordu**: tuş kütlesi satıra itiliyor, satır bir
    /// daha merkezlenmiyordu. Codex turunda yakalandı.
    func testCenteringInvariantsHold() {
        var key = [(x: Double, y: Double)](repeating: (0, 0), count: layout.keys.count)
        var rng = PRNG(state: 5)
        for i in key.indices { key[i] = (0.010 * rng.gaussian(), 0.008 * rng.gaussian()) }
        let s = samples(global: (0.008, 0.006),
                        row: [(0.004, 0), (0, 0), (-0.004, 0.003)],
                        key: key, perKey: 70)
        let inv = HierarchicalCalibration.invariants(estimate(s), layout: layout, samples: s)
        XCTAssertEqual(inv.rowResidualX, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.rowResidualY, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.keyResidualX, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.keyResidualY, 0, accuracy: 1e-8)
    }

    /// Kapalı satır varken de tutmalı — merkezlemenin paydası **açık**
    /// satırların örnek sayısı olmalı, tümünün değil.
    func testInvariantsHoldWhenARowIsClosed() {
        // Üçüncü satırdan yalnız bir tuş ve az örnek: satır kapısı kapanır.
        var indices = layout.keys.indices.filter { layout.rowOfKey[$0] < 2 }
        indices.append(layout.keys.indices.first { layout.rowOfKey[$0] == 2 }!)
        let s = samples(global: (0.008, 0), perKey: 25, keys: indices)
        let e = estimate(s)
        let inv = HierarchicalCalibration.invariants(e, layout: layout, samples: s)
        XCTAssertEqual(inv.rowResidualX, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.keyResidualX, 0, accuracy: 1e-8)
    }

    // MARK: - Yakınsama

    /// Durma ölçütü gerçekten sağlanıyor mu — üst sınıra dayanmamalı.
    func testBackfittingConvergesBeforeTheCap() {
        var key = [(x: Double, y: Double)](repeating: (0, 0), count: layout.keys.count)
        var rng = PRNG(state: 11)
        for i in key.indices { key[i] = (0.010 * rng.gaussian(), 0.008 * rng.gaussian()) }
        let e = estimate(samples(global: (0.01, 0.01),
                                 row: [(0.005, 0), (0, 0), (-0.005, 0)],
                                 key: key))
        XCTAssertTrue(e.converged)
        XCTAssertLessThan(e.maxDelta, HierarchicalCalibration.tolerance)
    }

    /// Dengesiz örnek dağılımında da yakınsamalı — bazı tuşlar çok, bazıları az.
    func testConvergesWithHighlyUnbalancedSampleCounts() {
        var out: [CalibrationLearner.Sample] = []
        var rng = PRNG(state: 3)
        for k in layout.keys.indices {
            let c = layout.keys[k]
            let count = k % 5 == 0 ? 200 : 22
            for _ in 0..<count {
                out.append(.init(point: Point(x: c.center.x + 0.01 + 0.25 * c.width * rng.gaussian(),
                                              y: c.center.y + 0.25 * c.height * rng.gaussian()),
                                 keyIndex: k, confidence: .strong))
            }
        }
        let e = estimate(out)
        XCTAssertTrue(e.converged)
        let inv = HierarchicalCalibration.invariants(e, layout: layout, samples: out)
        XCTAssertEqual(inv.rowResidualX, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.keyResidualX, 0, accuracy: 1e-8)
    }

    // MARK: - Kapılar ve kenar durumlar

    func testBelowGlobalThresholdNothingIsApplicable() {
        let e = estimate(samples(global: (0.02, 0), perKey: 1,
                                 keys: Array(0..<10)))
        XCTAssertFalse(e.isApplicable)
    }

    func testEmptySamplesYieldZeroEstimate() {
        let e = estimate([])
        XCTAssertFalse(e.isApplicable)
        XCTAssertEqual(e.globalX, 0)
        XCTAssertEqual(e.strongSamples, 0)
    }

    /// Tüm örnekler tek tuşta: tuşlar arası yayılım diye bir şey yok, ince
    /// katman kapalı olmalı ve sapma tamamen `g`'ye gitmeli.
    func testAllSamplesOnOneKeyKeepEverythingGlobal() {
        let e = estimate(samples(global: (0.015, 0), perKey: 120, keys: [3]))
        XCTAssertTrue(e.isApplicable)
        XCTAssertGreaterThan(e.globalX, 0.005)
        XCTAssertEqual(e.keysWithOwnLayer, 0)
        XCTAssertEqual(e.rowsWithOwnLayer, 0)
    }

    /// Zayıf etiketler karantinada — tahmine hiç girmemeli.
    func testWeakSamplesAreExcluded() {
        var s = samples(global: (0.015, 0))
        s = s.map { .init(point: $0.point, keyIndex: $0.keyIndex, confidence: .weak) }
        let e = estimate(s)
        XCTAssertEqual(e.strongSamples, 0)
        XCTAssertFalse(e.isApplicable)
    }

    /// Geçersiz örnek tahmini zehirlememeli. NaN kırpma karşılaştırmasını da
    /// atlar (`NaN > x` daima false), yani sessizce `SpatialModel`e sızardı.
    func testInvalidSamplesAreRejectedNotPropagated() {
        let clean = samples(global: (0.012, 0))
        var dirty = clean
        dirty.append(.init(point: Point(x: .nan, y: 0.5), keyIndex: 0, confidence: .strong))
        dirty.append(.init(point: Point(x: 0.5, y: .infinity), keyIndex: 0, confidence: .strong))
        dirty.append(.init(point: Point(x: 0.5, y: 0.5), keyIndex: -1, confidence: .strong))
        dirty.append(.init(point: Point(x: 0.5, y: 0.5), keyIndex: 9999, confidence: .strong))

        let a = estimate(clean), b = estimate(dirty)
        // Reddedilme "sonuç finite" ile kanıtlanmaz — geçersiz örnek sessizce
        // sıfır sayılsa da finite kalırdı. Kanıt: tahmin TAMAMEN aynı.
        XCTAssertEqual(b.strongSamples, a.strongSamples)
        XCTAssertEqual(b.globalX, a.globalX, accuracy: 1e-15)
        XCTAssertEqual(b.globalY, a.globalY, accuracy: 1e-15)
        for i in layout.keys.indices {
            XCTAssertEqual(b.biasX[i], a.biasX[i], accuracy: 1e-15)
            XCTAssertEqual(b.biasY[i], a.biasY[i], accuracy: 1e-15)
        }
        // Invariant yardımcısı da aynı kümeyi saymalı; saymazsa geçersiz örnek
        // sahte bir ihlal üretir.
        let inv = HierarchicalCalibration.invariants(b, layout: layout, samples: dirty)
        XCTAssertEqual(inv.rowResidualX, 0, accuracy: 1e-8)
        XCTAssertEqual(inv.keyResidualX, 0, accuracy: 1e-8)
    }

    /// Kırpma tuşun **kendi** ölçüsünde; aşırı sapma sınırda durmalı.
    func testExtremeBiasIsClampedPerKey() {
        let e = estimate(samples(global: (0.5, 0.5), sigma: 0.05))
        XCTAssertGreaterThan(e.clampedKeys, 0)
        for c in layout.keys.indices {
            let w = layout.keys[c].width, h = layout.keys[c].height
            let norm = ((e.biasX[c] / w) * (e.biasX[c] / w)
                        + (e.biasY[c] / h) * (e.biasY[c] / h)).squareRoot()
            XCTAssertLessThanOrEqual(norm, CalibrationLearner.maxBiasInKeyWidths + 1e-9)
        }
    }

    // MARK: - Uzamsal modele uygulama

    func testApplyingGivesDifferentKeysDifferentBias() {
        var key = [(x: Double, y: Double)](repeating: (0, 0), count: layout.keys.count)
        var rng = PRNG(state: 21)
        for i in key.indices { key[i] = (0.014 * rng.gaussian(), 0) }
        var learner = CalibrationLearner()
        for s in samples(key: key, sigma: 0.18, perKey: 90) { learner.append(s) }

        var model = SpatialModel(layout: layout)
        learner.applyHierarchical(to: &model)
        let distinct = Set(model.calib.map { ($0.biasX * 1e9).rounded() })
        XCTAssertGreaterThan(distinct.count, 5, "tuşlar aynı sapmayı almamalı")
    }

    /// Eşik altında model **hiç** değişmemeli.
    func testApplyingIsANoOpBelowThreshold() {
        var learner = CalibrationLearner()
        for s in samples(global: (0.03, 0.03), perKey: 1, keys: Array(0..<10)) {
            learner.append(s)
        }
        var model = SpatialModel(layout: layout)
        learner.applyHierarchical(to: &model)
        for c in model.calib {
            XCTAssertEqual(c.biasX, 0)
            XCTAssertEqual(c.biasY, 0)
        }
    }

    /// Saf global sapmada hiyerarşik ve global kollar **aynı** modeli üretmeli:
    /// ince katman kapanınca Faz 3, Faz 1'e iner. Ürün yolunun tek dal
    /// kullanabilmesinin gerekçesi bu.
    func testHierarchicalDegradesToGlobalWhenThereIsNoFineStructure() {
        // Ölçek eksene göre: `x` tuş genişliği, `y` tuş yüksekliği. İkisini
        // aynı ölçüyle sınamak Y'de ~3 kat sıkı, X'te gevşek bir kapı kurar.
        let w = layout.keys.map(\.width).min()!
        let h = layout.keys.map(\.height).min()!
        var matched = 0
        let seeds: [UInt64] = [3, 17, 91, 404, 5150]
        for seed in seeds {
            var learner = CalibrationLearner()
            for s in samples(global: (0.012, 0.009), seed: seed) { learner.append(s) }
            let e = learner.hierarchicalEstimate(layout: layout)

            // Önce **sebep**: ince katmanlar kapalı (ya da ihmal edilebilir).
            // Yalnız iki kolun sonucunu karşılaştırmak, ikisinin de aynı yanlışı
            // yapması hâlinde de geçerdi. Her iki eksen de sınanmalı — ilk
            // yazılışı yalnız X'e bakıyordu ve Y'de açık kalan katmanı
            // "kapalı" sayıyordu.
            let fine = max((e.keyX + e.rowX).map { abs($0) / w }.max() ?? 0,
                           (e.keyY + e.rowY).map { abs($0) / h }.max() ?? 0)
            guard fine < 0.02 else { continue }
            matched += 1

            var a = SpatialModel(layout: layout); learner.apply(to: &a)
            var b = SpatialModel(layout: layout); learner.applyHierarchical(to: &b)
            for i in layout.keys.indices {
                XCTAssertEqual(a.calib[i].biasX, b.calib[i].biasX, accuracy: 0.03 * w,
                               "seed \(seed)")
                XCTAssertEqual(a.calib[i].biasY, b.calib[i].biasY, accuracy: 0.03 * h,
                               "seed \(seed)")
            }
        }
        XCTAssertGreaterThanOrEqual(matched, seeds.count - 1,
                                    "ince katman tohumların çoğunda kapalı olmalıydı")
    }
}
