import UIKit
import KBLearning
import KBSessions

/// Kalibrasyonun kalıcılığı: hangi profil (ölçü, yönelim, yerleşim), diske
/// yazma ve profiller arası geçiş.
///
/// Depo **daima uzantı sandbox'ında**: Tam Erişim açılıp kapanabildiği için
/// iki yazılabilir depo split-brain üretir (plan §7). Tek yazar biziz.
@MainActor
final class CalibrationPersistence {
    typealias ProfileKey = CalibrationStore.ProfileKey

    private static var directory: URL? { LocalStore.url(LocalStore.Name.calibration, isDirectory: true) }

    private(set) var profile: ProfileKey?
    /// Aktif token sürerken profil değişirse beklemeye alınır — eski geometride
    /// toplanan dokunmalar yeni profile yazılmamalı.
    private var pendingProfile: ProfileKey?
    /// Motor kurulmadan seçilen profilin öğrenicisi.
    private var pendingLearner: CalibrationLearner?

    /// Canlı motorun rezervuarının **son bilinen kopyası**.
    ///
    /// Devretme (`rollOver`) koordinatörü sıfırdan kuruyor ve `configure`
    /// çağrıldığında `input` çoktan yeni motoru gösteriyor: eskisinin
    /// öğrendiğini o an okumak imkânsız. Bu kopya her eylemden sonra
    /// tazeleniyor, dolayısıyla en fazla bir eylem bayat.
    var live: CalibrationLearner?

    /// Klavyenin şu anki ölçüsünün profili; ölçü henüz yoksa `nil`.
    static func profileKey(layoutID: String, size: CGSize, isPad: Bool,
                           screenWidth: CGFloat?, scale: CGFloat) -> ProfileKey? {
        guard size.width > 0, size.height > 0 else { return nil }
        return ProfileKey(
            // Ölçüler `layout.id`'de: shift genişleyince 3. satırın bütün
            // merkezleri kayıyor, o geometride öğrenilen sapma burada yanlış.
            layoutID: layoutID,
            idiom: isPad ? "pad" : "phone",
            isLandscape: size.width > size.height,
            height: Double(size.height),
            width: Double(size.width),
            placement: placement(keyboardWidth: size.width, screenWidth: screenWidth, isPad: isPad),
            oneHanded: "off",     // iOS uzantıya tek el modunu bildirmiyor
            scale: Int(scale.rounded()))
    }

    /// Yerleşim tespiti.
    ///
    /// iOS klavye uzantısına floating/split durumunu **bildirmiyor**. Ölçüden
    /// çıkarım güvenilir değil; yalnız emin olduğumuz durumda karar veriyoruz,
    /// gerisi `.unknown` ve kendi kovasında kalıyor.
    private static func placement(keyboardWidth: CGFloat, screenWidth: CGFloat?,
                                  isPad: Bool) -> ProfileKey.Placement {
        guard isPad else { return .docked }        // iPhone'da tek yerleşim
        guard let sw = screenWidth, sw > 0 else { return .unknown }
        let ratio = keyboardWidth / sw
        if ratio > 0.95 { return .docked }
        if ratio < 0.55 { return .floating }
        return .unknown                             // split olabilir, emin değiliz
    }

    /// Ölçü değişti. Token sürerken geçiş bekletiliyor (`applyPending`).
    /// - Returns: geçiş **şimdi** yapıldı mı (motor değiştiyse deneme devredilmeli).
    func request(_ key: ProfileKey, composing: Bool, engine: RecordingEngine?) -> Bool {
        guard key != profile else { return false }
        guard !composing else {
            pendingProfile = key
            return false
        }
        switchTo(key, engine: engine)
        return true
    }

    /// Token sınırı: bekleyen geçiş varsa şimdi. - Returns: geçiş yapıldı mı.
    func applyPending(engine: RecordingEngine?) -> Bool {
        guard let p = pendingProfile else { return false }
        switchTo(p, engine: engine)
        return true
    }

    private func switchTo(_ key: ProfileKey, engine: RecordingEngine?) {
        save(engine)                      // ÖNCEKİ profilin verisi önce diske
        profile = key
        pendingProfile = nil
        guard let dir = Self.directory else { return }
        let learner = CalibrationStore.loadOrEmpty(from: dir, profile: key)
        // Canlı kopya da **yeni profile** geçiyor. Geçmeseydi bir sonraki
        // devretme, eski geometride öğrenilmiş sapmayı yeni profile
        // taşırdı — profil ayrımının varlık sebebi tam olarak bunu
        // engellemek.
        live = learner
        if let engine {
            engine.replaceCalibration(learner)
            engine.applyCalibration()
        } else {
            // Motor henüz kurulmadı: öğrenici **saklanıyor**. Eskiden
            // düşüyordu ve paket gelince boş öğrenici uygulanıyor, yani
            // kaydedilmiş kalibrasyon profili sessizce kayboluyordu.
            pendingLearner = learner
        }
    }

    /// Motor kuruldu: profil ondan önce seçildiyse öğrenicisi şimdi uygulanıyor.
    /// Bekleyen **önce**: yoksa boş öğrenici kaydedilmiş kalibrasyonun üstüne yazardı.
    func engineDidLoad(_ engine: RecordingEngine) {
        if let pendingLearner {
            engine.replaceCalibration(pendingLearner)
            self.pendingLearner = nil
        }
        engine.applyCalibration()
    }

    /// Yeni kurulan (devredilen) motorun öğrenicisi: canlı kopya, yoksa
    /// aktif profilin diskteki rezervuarı.
    func learnerForNewEngine() -> CalibrationLearner? {
        if let live { return live }
        guard let dir = Self.directory, let profile else { return pendingLearner }
        return CalibrationStore.loadOrEmpty(from: dir, profile: profile)
    }

    func save(_ engine: RecordingEngine?) {
        guard let dir = Self.directory, let profile,
              let engine, engine.calibration.sampleCount > 0 else { return }
        try? CalibrationStore.save(engine.calibration, to: dir, profile: profile)
    }

    /// Harf geometrisi değişti: eski profilde öğrenilen sapma bu geometride
    /// **yanlış**. Canlı kopya da düşüyor, yoksa yeni profil kurulana kadar
    /// araya giren bir devretme onu geri getirirdi. Yeni profil bir sonraki
    /// yerleşimde (ölçü belli olunca) kuruluyor.
    func reset() {
        profile = nil
        pendingProfile = nil
        live = nil
    }
}
