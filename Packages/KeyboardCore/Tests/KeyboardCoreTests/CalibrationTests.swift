import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLearning

/// Kalibrasyon öğrenimi — plan §3 ve §Doğrulama.
final class CalibrationTests: XCTestCase {

    private let layout = TurkishQ.layout()

    /// Tekrarlanabilir gürültü — `Math.random` yerine sabit tohumlu LCG.
    private struct PRNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Box–Muller.
        mutating func gaussian() -> Double {
            let u1 = max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// Bilinen sapma ve yayılımla sentetik dokunma üretir.
    private func synthesise(biasX: Double, biasY: Double,
                            sigma: Double, count: Int, seed: UInt64 = 42)
        -> CalibrationLearner {
        var rng = PRNG(state: seed)
        var learner = CalibrationLearner()
        for i in 0..<count {
            let k = i % layout.keys.count
            let c = layout.keys[k].center
            let p = Point(x: c.x + biasX + sigma * rng.gaussian(),
                          y: c.y + biasY + sigma * rng.gaussian())
            learner.append(.init(point: p, keyIndex: k, confidence: .strong))
        }
        return learner
    }

    // MARK: - Sentetik geri kazanım (§Doğrulama, zorunlu kapı)

    /// Bilinen `(bias, σ)` ile üretilmiş veriden aynı sapma geri bulunmalı.
    ///
    /// Shrinkage yüzünden tahmin gerçek değerin **altında** kalır; oran
    /// `n/(n+κ)` ile tam olarak tahmin edilebilir olmalı. Test bunu doğruluyor:
    /// tahmin ne tesadüfen doğru, ne de sapmanın yönünü kaçırıyor.
    func testRecoversAKnownBiasUpToTheShrinkageFactor() {
        let trueBias = 0.02          // tuş genişliğinin ~%25'i kadar sağa
        let n = 600
        let learner = synthesise(biasX: trueBias, biasY: -0.015, sigma: 0.01, count: n)

        let e = learner.estimate(layout: layout)
        XCTAssertTrue(e.isApplicable)

        let shrink = Double(n) / (Double(n) + CalibrationLearner.kappa)
        XCTAssertEqual(e.globalBiasX, shrink * trueBias, accuracy: 0.002)
        XCTAssertEqual(e.globalBiasY, shrink * -0.015, accuracy: 0.002)
    }

    /// Sıfır sapmalı kullanıcıya **zarar verilmemeli** (plan §9 metrik 6).
    func testZeroBiasUserStaysNearZero() {
        let learner = synthesise(biasX: 0, biasY: 0, sigma: 0.012, count: 600)
        let e = learner.estimate(layout: layout)
        XCTAssertLessThan(abs(e.globalBiasX), 0.003)
        XCTAssertLessThan(abs(e.globalBiasY), 0.003)
    }

    /// Gürültü büyüdükçe tahmin bozulmamalı, yalnız yavaşlamalı.
    func testEstimateIsStableUnderHighNoise() {
        let trueBias = 0.02
        let quiet = synthesise(biasX: trueBias, biasY: 0, sigma: 0.005, count: 800)
        let noisy = synthesise(biasX: trueBias, biasY: 0, sigma: 0.030, count: 800, seed: 7)
        let a = quiet.estimate(layout: layout).globalBiasX
        let b = noisy.estimate(layout: layout).globalBiasX
        XCTAssertEqual(a, b, accuracy: 0.006, "yüksek gürültü tahmini kaydırmamalı")
    }

    // MARK: - Eşik ve kırpma

    func testBelowThresholdNothingIsApplicable() {
        let learner = synthesise(biasX: 0.03, biasY: 0, sigma: 0.01,
                                 count: CalibrationLearner.minStrongSamples - 1)
        XCTAssertFalse(learner.estimate(layout: layout).isApplicable)
    }

    func testAtThresholdItBecomesApplicable() {
        let learner = synthesise(biasX: 0.03, biasY: 0, sigma: 0.01,
                                 count: CalibrationLearner.minStrongSamples)
        XCTAssertTrue(learner.estimate(layout: layout).isApplicable)
    }

    /// Bozuk veri sapmayı uçuramaz. Kırpma olmasa tek bir kötü oturum
    /// kullanıcının klavyesini kullanılamaz hale getirirdi.
    ///
    /// Kırpma **vektör normu** üzerinde: eksen bazlı kırpma diyagonal sapmanın
    /// √2 katına çıkmasına izin veriyordu, yani "toplam sapma ≤ 0.6 tuş"
    /// sınırı fiilen uygulanmıyordu.
    func testDiagonalExtremeIsClampedByVectorNorm() {
        var learner = CalibrationLearner()
        for i in 0..<300 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x + 0.5, y: c.y + 0.5),
                                 keyIndex: i % layout.keys.count, confidence: .strong))
        }
        let e = learner.estimate(layout: layout)
        // Sınır **tuş biriminde**: √((bx/w)² + (by/h)²) ≤ 0.6.
        let w = layout.keys.map(\.width).min()!
        let h = layout.keys.map(\.height).min()!
        let norm = ((e.globalBiasX / w) * (e.globalBiasX / w)
                    + (e.globalBiasY / h) * (e.globalBiasY / h)).squareRoot()
        XCTAssertLessThanOrEqual(norm, CalibrationLearner.maxBiasInKeyWidths + 1e-9,
                                 "diyagonal sapma norm sınırını aşmamalı")
    }

    /// Tek eksende de aynı sınır geçerli.
    func testSingleAxisExtremeIsClamped() {
        var learner = CalibrationLearner()
        for i in 0..<300 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x + 0.5, y: c.y),
                                 keyIndex: i % layout.keys.count, confidence: .strong))
        }
        let e = learner.estimate(layout: layout)
        let w = layout.keys.map(\.width).min()!
        XCTAssertLessThanOrEqual(abs(e.globalBiasX) / w,
                                 CalibrationLearner.maxBiasInKeyWidths + 1e-9)
    }

    // MARK: - Etiket güveni

    /// Zayıf etiketler (otomatik commit, değiştirilmedi) tahmine **girmez**.
    /// Plan §3: pseudo-label havuzunda iyi görünmek kanıt sayılmaz.
    func testWeakLabelsAreQuarantinedFromTheEstimate() {
        var learner = CalibrationLearner()
        for i in 0..<400 {
            let c = layout.keys[i % layout.keys.count].center
            // Zayıf örnekler ÇOK sapmalı; tahmine girselerse hemen belli olur.
            learner.append(.init(point: Point(x: c.x + 0.2, y: c.y),
                                 keyIndex: i % layout.keys.count, confidence: .weak))
        }
        XCTAssertEqual(learner.sampleCount, 400)
        XCTAssertEqual(learner.strongCount, 0)
        let e = learner.estimate(layout: layout)
        XCTAssertEqual(e.globalBiasX, 0, "zayıf etiket tahmini kaydırmamalı")
        XCTAssertFalse(e.isApplicable)
    }

    // MARK: - Hizalama kuralı (döngüsellik koruması)

    private func touches(_ word: String) -> [TouchSample] {
        word.compactMap { ch in
            layout.keyIndex(for: ch).map {
                TouchSample(down: layout.keys[$0].center, timestamp: 0)
            }
        }
    }

    /// **Asıl döngüsellik koruması.** Commit edilen metin literal'den farklıysa
    /// literal hedef değildir; onu hedef saymak yazım hatasını modele
    /// öğretirdi. `kalen` yazıp `kalem` seçen kullanıcıdan öğrenmek, son
    /// dokunmanın `n` demek olduğunu öğretmek olurdu.
    func testNothingIsLearnedWhenTheCommittedTextDiffersFromTheLiteral() {
        var learner = CalibrationLearner()
        XCTAssertEqual(learner.observe(touches: touches("kalen"), literal: "kalen",
                                       committed: "kalem", layout: layout,
                                       confidence: .strong), 0)
        XCTAssertEqual(learner.sampleCount, 0)
    }

    /// Uzunluk eşitliği hizalamayı kanıtlamaz (TR uzunluğu korur, dengeli
    /// OM+INS de korur) — bu yüzden kural uzunluk değil **eşitlik**.
    func testEqualLengthButDifferentTextIsStillRejected() {
        var learner = CalibrationLearner()
        // Transpozisyon: aynı uzunluk, farklı metin.
        XCTAssertEqual(learner.observe(touches: touches("kaelm"), literal: "kaelm",
                                       committed: "kalem", layout: layout,
                                       confidence: .strong), 0)
        XCTAssertEqual(learner.sampleCount, 0)
    }

    func testMismatchedTouchCountYieldsNoSamples() {
        var learner = CalibrationLearner()
        XCTAssertEqual(learner.observe(touches: Array(touches("kale")),
                                       literal: "kalem", committed: "kalem",
                                       layout: layout, confidence: .strong), 0)
    }

    /// Literal commit edildiğinde hizalama **kayıttır**: dokunma `i` → literal
    /// karakter `i`, çünkü uzantı her dokunmada o karakteri yazdı.
    func testCommittedLiteralAlignsPositionally() {
        var learner = CalibrationLearner()
        let word = "kalem"
        XCTAssertEqual(learner.observe(touches: touches(word), literal: word,
                                       committed: word, layout: layout,
                                       confidence: .strong), 5)
        for (i, ch) in word.enumerated() {
            XCTAssertEqual(learner.reservoir[i].keyIndex, layout.keyIndex(for: ch))
        }
    }

    /// Tek bir karakter eşlenemiyorsa **token'ın tamamı** reddedilir; kısmi
    /// kabul, casing ya da Unicode yüzünden kayan bir token'ı içeri alırdı.
    func testTokenWithAnyUnmappableCharacterIsRejectedEntirely() {
        var learner = CalibrationLearner()
        let word = "ka1em"        // `1` harf tuşu değil
        let ts = word.map { _ in TouchSample(down: layout.keys[0].center, timestamp: 0) }
        XCTAssertEqual(learner.observe(touches: ts, literal: word, committed: word,
                                       layout: layout, confidence: .strong), 0)
        XCTAssertEqual(learner.sampleCount, 0, "kısmi kabul olmamalı")
    }

    func testEmptyTargetIsIgnored() {
        var learner = CalibrationLearner()
        XCTAssertEqual(learner.observe(touches: [], literal: "", committed: "",
                                       layout: layout, confidence: .strong), 0)
    }

    // MARK: - Rezervuar

    func testReservoirIsBoundedAndKeepsTheNewest() {
        var learner = CalibrationLearner()
        let cap = CalibrationLearner.reservoirCapacity
        for i in 0..<(cap + 500) {
            learner.append(.init(point: Point(x: Double(i) / 10000, y: 0),
                                 keyIndex: 0, confidence: .strong))
        }
        XCTAssertEqual(learner.sampleCount, cap)
        // En yenisi korunmalı: eskisini atmak, yeni tutuş alışkanlığını
        // öğrenmenin tek yolu.
        XCTAssertEqual(learner.reservoir.last?.point.x ?? 0,
                       Double(cap + 499) / 10000, accuracy: 1e-9)
    }

    // MARK: - Uzamsal modele uygulama

    func testApplyingShiftsEveryKeyMean() {
        let learner = synthesise(biasX: 0.02, biasY: -0.01, sigma: 0.01, count: 600)
        var model = SpatialModel(layout: layout)
        XCTAssertEqual(model.calib[0].biasX, 0)

        learner.apply(to: &model)
        XCTAssertGreaterThan(model.calib[0].biasX, 0.01)
        XCTAssertLessThan(model.calib[0].biasY, -0.005)
        // Global sapma: her tuş aynı değeri alır.
        for c in model.calib {
            XCTAssertEqual(c.biasX, model.calib[0].biasX, accuracy: 1e-12)
        }
    }

    func testApplyingIsANoOpBelowThreshold() {
        let learner = synthesise(biasX: 0.05, biasY: 0, sigma: 0.01, count: 10)
        var model = SpatialModel(layout: layout)
        learner.apply(to: &model)
        for c in model.calib { XCTAssertEqual(c.biasX, 0, "eşik altında dokunulmamalı") }
    }

    /// Kalibrasyon gerçekten işe yaramalı: sapmalı bir kullanıcının dokunmaları
    /// kalibrasyondan sonra doğru tuşa **daha ucuz** gelmeli.
    func testCalibrationImprovesLikelihoodForABiasedUser() {
        let bias = 0.02
        let learner = synthesise(biasX: bias, biasY: 0, sigma: 0.008, count: 600)

        var calibrated = SpatialModel(layout: layout)
        learner.apply(to: &calibrated)
        let plain = SpatialModel(layout: layout)

        // Kullanıcının tipik dokunuşu: hedefin sağına kaymış.
        let k = layout.keyIndex(for: "a")!
        let t = TouchSample(down: Point(x: layout.keys[k].center.x + bias,
                                        y: layout.keys[k].center.y), timestamp: 0)
        XCTAssertLessThan(calibrated.negLogP(t, keyIndex: k),
                          plain.negLogP(t, keyIndex: k),
                          "kalibrasyon sapmalı kullanıcıya yardım etmeli")
    }

    func testResetClearsEverything() {
        var learner = synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 300)
        XCTAssertTrue(learner.estimate(layout: layout).isApplicable)
        learner.reset()
        XCTAssertEqual(learner.sampleCount, 0)
        XCTAssertFalse(learner.estimate(layout: layout).isApplicable)
    }

    // MARK: - Kalıcılık

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var profile: CalibrationStore.ProfileKey {
        .init(layoutID: "tr-Q", idiom: "phone", isLandscape: false,
              height: 216, width: 393)
    }

    func testRoundTripPreservesEveryStrongSample() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var learner = synthesise(biasX: 0.02, biasY: -0.01, sigma: 0.01, count: 300)
        learner.append(.init(point: Point(x: 0.3, y: 0.7), keyIndex: 5, confidence: .weak))

        try CalibrationStore.save(learner, to: dir, profile: profile)
        let back = try CalibrationStore.load(from: dir, profile: profile)

        // Zayıf örnekler **kalıcılaştırılmaz**: tahmine hiç girmiyorlar,
        // dolayısıyla ham koordinatlarını saklamanın faydası yok (veri
        // minimizasyonu).
        XCTAssertEqual(back.sampleCount, learner.strongCount)
        XCTAssertEqual(back.strongCount, learner.strongCount)
        for (a, b) in zip(back.reservoir, learner.reservoir.filter { $0.confidence == .strong }) {
            XCTAssertEqual(a.point.x, b.point.x, accuracy: 1e-6)
            XCTAssertEqual(a.point.y, b.point.y, accuracy: 1e-6)
            XCTAssertEqual(a.keyIndex, b.keyIndex)
            XCTAssertEqual(a.confidence, b.confidence)
        }
        // Tahmin de aynı kalmalı — asıl önemli olan bu.
        XCTAssertEqual(back.estimate(layout: layout).globalBiasX,
                       learner.estimate(layout: layout).globalBiasX, accuracy: 1e-6)
    }

    func testCorruptedFileFallsBackToEmptyInsteadOfBadCalibration() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let learner = synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 300)
        try CalibrationStore.save(learner, to: dir, profile: profile)

        let url = dir.appendingPathComponent(profile.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[CalibrationStore.headerSize + 3] ^= 0xFF
        try Data(bytes).write(to: url)

        XCTAssertThrowsError(try CalibrationStore.load(from: dir, profile: profile))
        // Bozuk kalibrasyonla çalışmaktansa kalibrasyonsuz çalışmak yeğdir.
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: dir, profile: profile).sampleCount, 0)
    }

    func testMissingFileYieldsEmptyLearner() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: dir, profile: profile).sampleCount, 0)
    }

    func testTruncatedFileIsRejected() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let learner = synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 300)
        try CalibrationStore.save(learner, to: dir, profile: profile)

        let url = dir.appendingPathComponent(profile.fileName)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 2).write(to: url)
        XCTAssertThrowsError(try CalibrationStore.load(from: dir, profile: profile))
    }

    func testSavingTwiceOverwritesCleanly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try CalibrationStore.save(synthesise(biasX: 0.01, biasY: 0, sigma: 0.01, count: 100),
                                  to: dir, profile: profile)
        try CalibrationStore.save(synthesise(biasX: 0.03, biasY: 0, sigma: 0.01, count: 200),
                                  to: dir, profile: profile)
        XCTAssertEqual(try CalibrationStore.load(from: dir, profile: profile).sampleCount, 200)
    }

    // MARK: - Profil ayrımı

    /// Yatay ve dikey tutuşta sapma aynı değildir; bir moddan öğrenileni
    /// diğerine uygulamak zarar verir.
    func testOrientationsGetSeparateProfiles() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let portrait = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                                   isLandscape: false, height: 216, width: 393)
        let landscape = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                                    isLandscape: true, height: 162, width: 852)
        XCTAssertNotEqual(portrait.fileName, landscape.fileName)

        try CalibrationStore.save(synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 300),
                                  to: dir, profile: portrait)
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: dir, profile: landscape).sampleCount, 0,
                       "yatay profil dikeyin verisini görmemeli")
    }

    /// Birkaç piksellik fark profilleri bölmemeli — kovalama bunun için var.
    func testTinySizeDifferencesShareAProfile() {
        let a = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        let b = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 218, width: 395)
        XCTAssertEqual(a, b)
    }

    /// Split/floating klavye kullanılabilir alanı değiştirir → ayrı profil.
    func testSubstantiallyDifferentWidthSplitsTheProfile() {
        let full = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "pad",
                                               isLandscape: false, height: 216, width: 820)
        let floating = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "pad",
                                                   isLandscape: false, height: 216, width: 320)
        XCTAssertNotEqual(full, floating)
    }
}

// MARK: - Codex turunda açılan boşluklar

extension CalibrationTests {

    private var dir2: URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Aynı boyutta ama farklı yerleşimdeki klavyeler **ayrı** profil almalı.
    /// İlk sürümde yerleşim yalnız genişlik kovasından "tesadüfen" ayrışıyordu.
    func testSameBoundsDifferentPlacementSplitsTheProfile() {
        let docked = CalibrationStore.ProfileKey(
            layoutID: "tr-Q", idiom: "pad", isLandscape: false,
            height: 216, width: 400, placement: .docked)
        let floating = CalibrationStore.ProfileKey(
            layoutID: "tr-Q", idiom: "pad", isLandscape: false,
            height: 216, width: 400, placement: .floating)
        XCTAssertNotEqual(docked, floating)
        XCTAssertNotEqual(docked.fileName, floating.fileName)
    }

    func testOneHandedModeSplitsTheProfile() {
        let off = CalibrationStore.ProfileKey(
            layoutID: "tr-Q", idiom: "phone", isLandscape: false,
            height: 216, width: 393, oneHanded: "off")
        let left = CalibrationStore.ProfileKey(
            layoutID: "tr-Q", idiom: "phone", isLandscape: false,
            height: 216, width: 393, oneHanded: "left")
        XCTAssertNotEqual(off, left)
    }

    func testScaleSplitsTheProfile() {
        let x2 = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                             isLandscape: false, height: 216,
                                             width: 393, scale: 2)
        let x3 = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                             isLandscape: false, height: 216,
                                             width: 393, scale: 3)
        XCTAssertNotEqual(x2, x3)
    }

    /// İmza sürümlü: alan eklendiğinde eski dosyalar sessizce yeniden
    /// kullanılmamalı — yanlış profilden öğrenilen sapmayı uygulamak zarar verir.
    func testSignatureIsVersioned() {
        let k = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        XCTAssertTrue(k.description.hasPrefix("v2-"), "imza sürüm taşımalı")
    }

    // MARK: Yükleme doğrulaması

    func testTrailingBytesAreRejected() throws {
        let d = dir2; defer { try? FileManager.default.removeItem(at: d) }
        let p = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        try CalibrationStore.save(synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 100),
                                  to: d, profile: p)
        let url = d.appendingPathComponent(p.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes.append(contentsOf: [0, 0, 0, 0])
        // Checksum'ı da güncelle ki test gerçekten BOYUT kontrolünü sınasın.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in CalibrationStore.headerSize..<bytes.count {
            h ^= UInt64(bytes[i]); h = h &* 0x0000_0100_0000_01B3
        }
        for i in 0..<8 { bytes[16 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        try Data(bytes).write(to: url)

        XCTAssertThrowsError(try CalibrationStore.load(from: d, profile: p),
                             "fazladan bayt aynı sürümün ikinci temsilini üretirdi")
    }

    func testNaNCoordinateIsRejected() throws {
        let d = dir2; defer { try? FileManager.default.removeItem(at: d) }
        let p = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        try CalibrationStore.save(synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 100),
                                  to: d, profile: p)
        let url = d.appendingPathComponent(p.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        let nan = Float.nan.bitPattern
        let o = CalibrationStore.headerSize
        for i in 0..<4 { bytes[o + i] = UInt8(truncatingIfNeeded: nan >> (8 * UInt32(i))) }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in CalibrationStore.headerSize..<bytes.count {
            h ^= UInt64(bytes[i]); h = h &* 0x0000_0100_0000_01B3
        }
        for i in 0..<8 { bytes[16 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        try Data(bytes).write(to: url)

        // NaN bir koordinat tahmini sessizce NaN yapar; kalibrasyon uygulanmış
        // görünüp klavyeyi bozardı.
        XCTAssertThrowsError(try CalibrationStore.load(from: d, profile: p))
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: d, profile: p).sampleCount, 0)
    }

    // MARK: Silme

    func testDeleteRemovesTheFileNotJustTheReservoir() throws {
        let d = dir2; defer { try? FileManager.default.removeItem(at: d) }
        let p = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        try CalibrationStore.save(synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 100),
                                  to: d, profile: p)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: d.appendingPathComponent(p.fileName).path))

        try CalibrationStore.delete(from: d, profile: p)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: d.appendingPathComponent(p.fileName).path))
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: d, profile: p).sampleCount, 0)
    }

    func testDeleteAllClearsEveryProfile() throws {
        let d = dir2; defer { try? FileManager.default.removeItem(at: d) }
        let a = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        let b = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: true, height: 162, width: 852)
        let l = synthesise(biasX: 0.02, biasY: 0, sigma: 0.01, count: 100)
        try CalibrationStore.save(l, to: d, profile: a)
        try CalibrationStore.save(l, to: d, profile: b)

        try CalibrationStore.deleteAll(from: d)
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: d, profile: a).sampleCount, 0)
        XCTAssertEqual(CalibrationStore.loadOrEmpty(from: d, profile: b).sampleCount, 0)
    }

    func testDeleteOnMissingFileIsHarmless() throws {
        let d = dir2; defer { try? FileManager.default.removeItem(at: d) }
        let p = CalibrationStore.ProfileKey(layoutID: "tr-Q", idiom: "phone",
                                            isLandscape: false, height: 216, width: 393)
        XCTAssertNoThrow(try CalibrationStore.delete(from: d, profile: p))
    }
}

// MARK: - Rezervuar ayrımı ve kırpma normalizasyonu

extension CalibrationTests {

    /// **Ciddi regresyon koruması.** Tek ortak rezervuarda her boşluk commit'i
    /// zayıf örnek üretip güçlü örnekleri FIFO ile dışarı atıyordu: kullanıcı
    /// yazdıkça geçerli kalibrasyon azalıyor, eşiğin altına düşebiliyordu.
    func testWeakSamplesCannotEvictStrongOnes() {
        var learner = CalibrationLearner()
        // Önce yeterli güçlü örnek.
        for i in 0..<200 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x + 0.02, y: c.y),
                                 keyIndex: i % layout.keys.count, confidence: .strong))
        }
        let before = learner.estimate(layout: layout)
        XCTAssertTrue(before.isApplicable)

        // Sonra bol miktarda zayıf trafik — gerçek kullanımdaki gibi.
        for i in 0..<5000 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x - 0.2, y: c.y),
                                 keyIndex: i % layout.keys.count, confidence: .weak))
        }
        let after = learner.estimate(layout: layout)
        XCTAssertEqual(after.strongSamples, before.strongSamples,
                       "zayıf trafik güçlü örnekleri atmamalı")
        XCTAssertEqual(after.globalBiasX, before.globalBiasX, accuracy: 1e-12)
        XCTAssertTrue(after.isApplicable)
    }

    func testWeakReservoirIsBoundedSeparately() {
        var learner = CalibrationLearner()
        for _ in 0..<(CalibrationLearner.weakReservoirCapacity + 1000) {
            learner.append(.init(point: Point(x: 0.5, y: 0.5), keyIndex: 0, confidence: .weak))
        }
        XCTAssertEqual(learner.sampleCount, CalibrationLearner.weakReservoirCapacity)
    }

    func testStrongReservoirIsBoundedSeparately() {
        var learner = CalibrationLearner()
        for _ in 0..<(CalibrationLearner.reservoirCapacity + 500) {
            learner.append(.init(point: Point(x: 0.5, y: 0.5), keyIndex: 0, confidence: .strong))
        }
        XCTAssertEqual(learner.strongCount, CalibrationLearner.reservoirCapacity)
    }

    /// Kırpma eksenleri **ayrı** normalize etmeli: normalize koordinatta `x` ve
    /// `y` aynı fiziksel ölçeği temsil etmiyor (tuşlar geniş ve alçak).
    /// Ortak `min(w,h)` ölçeği dikey sapmayı gereğinden fazla bastırırdı.
    func testVerticalBiasIsNotOverSuppressed() {
        var learner = CalibrationLearner()
        // Yalnız dikeyde, tuş yüksekliğinin %50'si kadar sapma — sınır 0.6.
        let h = layout.keys.map(\.height).min()!
        for i in 0..<400 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x, y: c.y + 0.5 * h),
                                 keyIndex: i % layout.keys.count, confidence: .strong))
        }
        let e = learner.estimate(layout: layout)
        // Shrinkage sonrası ~0.87 × 0.5h ≈ 0.43h; kırpma DEVREYE GİRMEMELİ.
        XCTAssertGreaterThan(e.globalBiasY, 0.35 * h,
                             "dikey sapma gereğinden fazla bastırılmamalı")
    }

    /// Tuş birimindeki norm sınırı gerçekten uygulanmalı.
    func testClampUsesPerAxisKeyUnits() {
        var learner = CalibrationLearner()
        let w = layout.keys.map(\.width).min()!
        let h = layout.keys.map(\.height).min()!
        for i in 0..<600 {
            let c = layout.keys[i % layout.keys.count].center
            learner.append(.init(point: Point(x: c.x + 3 * w, y: c.y + 3 * h),
                                 keyIndex: i % layout.keys.count, confidence: .strong))
        }
        let e = learner.estimate(layout: layout)
        let norm = ((e.globalBiasX / w) * (e.globalBiasX / w)
                    + (e.globalBiasY / h) * (e.globalBiasY / h)).squareRoot()
        XCTAssertLessThanOrEqual(norm, CalibrationLearner.maxBiasInKeyWidths + 1e-9)
    }
}
