import KBGeometry
import KBSpatial
import KBLearning

// MARK: - Kalibrasyon öğrenmesi

extension InputCoordinator {

    /// Öğrenilen sapmayı uzamsal modele işler ve decoder'ı yeniden kurar.
    ///
    /// **Token sınırında** çağrılmalı: uzamsal model değişmesi `modelVersion`
    /// değişmesidir (§5b) ve artımlı beam yalnız model sabitken doğrudur.
    ///
    /// Uygulanan model **hiyerarşik** (Faz 3, sözleşme §8.6): `b_c = g + r_row + d_c`.
    /// Faz 1'in global tahmini (`calibration.apply`) kaldırılmadı ama ürün
    /// yolunda değil — ölçüm kolu olarak `kbbench --calibration`'da duruyor.
    ///
    /// Hiyerarşinin global'e indiği durum ayrı bir dal gerektirmiyor: ampirik
    /// Bayes tuş/satır yapısı bulamazsa `τ² = 0` çıkarır, ince katmanlar
    /// sıfırlanır ve sonuç aynen Faz 1'dir.
    @discardableResult
    public mutating func applyCalibration() -> Bool {
        guard let old = engine else { return false }
        var model = SpatialModel(layout: layout)
        calibration.applyHierarchical(to: &model)

        // Dil durumu, bigram paketi ve bağlam **taşınıyor** (`with(spatial:)`).
        // Taşınmasaydı kalibrasyonun her uygulanışı `F_ctx`'i sessizce
        // kapatırdı: motor kurulumdan sonra yeniden kurulan her decoder,
        // paketi olmayan bir decoder olurdu.
        engine?.decoder = old.decoder.with(spatial: model)
        rebuildIncremental()
        return true
    }

    /// Commit edilen token'dan kalibrasyon örneği toplar.
    ///
    /// **Seçim düzenlemesi bu yoldan geçmez**: o token'ın dokunmaları ilk
    /// yazıldığında zaten öğrenildi, tekrar eklemek aynı kanıtı iki kez saymak
    /// olurdu.
    ///
    /// - Parameter synthetic: token'ın kanıtı türetilmişse **hiçbir örnek
    ///   toplanmıyor**. Bayrak çağırandan geliyor çünkü `learn` daima
    ///   `finishToken`'dan sonra çağrılıyor ve oturum o noktada temizlenmiş
    ///   oluyor — `session.evidenceIsSynthetic`'i burada okumak daima `false`
    ///   görürdü. `touches` ile aynı anda, aynı yerden alınmalı
    ///   (`PendingToken`).
    ///
    ///   Sebep §8.1.1'de zaten ölçülü: tam tuş merkezine konan dokunmalar
    ///   uzamsal sinyali silen şeyin ta kendisi. Sentetik dokunmaların sapması
    ///   tanım gereği sıfır; onları öğrenmek, kullanıcının gerçek parmak
    ///   sapmasını **sistematik olarak sıfıra çeken** bir örneklem eklemek olurdu
    ///   ve dosya diskte durduğu için kayıp "kalibrasyon bozuldu" diye de
    ///   görünmezdi (§8.6 devretme hatasıyla aynı sinsilik).
    mutating func learn(touches: [TouchSample], literal: String,
                        committed: String,
                        confidence: CalibrationLearner.Confidence,
                        synthetic: Bool = false) {
        guard !synthetic else { return }
        let added = calibration.observe(touches: touches, literal: literal,
                                        committed: committed, layout: layout,
                                        confidence: confidence)
        guard added > 0 else { return }
        samplesSinceSave += added
        guard samplesSinceSave >= saveEvery else { return }
        wantsCalibrationSave = true
    }

    /// Çağıran kalibrasyonu diske yazdıktan sonra bunu çağırır.
    public mutating func calibrationSaved() {
        wantsCalibrationSave = false
        samplesSinceSave = 0
        applyCalibration()      // yeni tahmini yürürlüğe al
    }

    /// Profil değişiminde yeni learner yüklenir.
    public mutating func replaceCalibration(_ c: CalibrationLearner) {
        calibration = c
        samplesSinceSave = 0
        wantsCalibrationSave = false
        applyCalibration()
    }
}
