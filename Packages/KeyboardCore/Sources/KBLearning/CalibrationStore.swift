import Foundation
import KBGeometry

/// Klavyenin öğrendiğinin kalıcı deposu — plan §7.
///
/// ## Tek yetkili store
///
/// *"Klavyenin öğrendiği her şey **daima uzantı sandbox'ında** yazılır (Tam
/// Erişim'den bağımsız, tek yazar)."* Tam Erişim açılıp kapanabildiği için iki
/// yazılabilir depo split-brain üretir; bu yüzden yazma yolu tektir.
///
/// ## Geometri imzası profil anahtarıdır
///
/// Yatay ve dikey tutuşta parmak sapması aynı değildir; iPad'de floating ve
/// split klavye kullanılabilir alanı tamamen değiştirir. Tek bir profil
/// tutmak, bir moddan öğrenileni diğerine uygulamak demekti.
///
/// ## Dosya formatı
///
/// ```
/// Başlık (24 bayt)
///   0  magic     u32   "BKL1"
///   4  version   u16
///   6  flags     u16
///   8  count     u32   örnek sayısı
///  12  reserved  u32
///  16  checksum  u64   FNV-1a, yük üzerinden
///
/// Yük  count × 10 bayt
///   x         f32   normalize koordinat
///   y         f32
///   keyIndex  u16   yüksek bit: güven (1 = zayıf)
/// ```
///
/// Yazma **geçici dosya + atomik rename**: yazma ortasında çökme eski sürümü
/// bozmaz. Okuma checksum doğrular; bozuksa dosya yok sayılır ve öğrenme
/// sıfırdan başlar — bozuk bir kalibrasyonla çalışmaktansa kalibrasyonsuz
/// çalışmak yeğdir.
public enum CalibrationStore {

    public static let container = BinaryContainer(
        magic: 0x314C_4B42,   // "BKL1"
        version: 1, headerSize: 24)

    /// Örnek başına bayt: `x f32 · y f32 · keyIndex u16`.
    static let sampleSize = 10

    /// Profil anahtarı — plan §1 geometri imzası.
    ///
    /// Ölçüler kovalanır: aynı cihazda aynı yönelimde birkaç piksellik fark
    /// profilleri gereksiz yere bölerdi.
    ///
    /// **Mod alanları ölçüden ÇIKARSANMAZ.** İlk sürümde yalnız genişlik
    /// kovası vardı ve floating/split'i "tesadüfen" ayırıyordu — aynı boyuta
    /// denk gelen iki farklı geometri çakışırdı. Şimdi mod açık bir alan;
    /// çağıran ne olduğunu bilmiyorsa `.unknown` verir ve o da kendi
    /// kovasında kalır.
    public struct ProfileKey: Hashable, Sendable, CustomStringConvertible {
        public enum Placement: String, Sendable {
            case docked, floating, split, unknown
        }

        public var layoutID: String
        public var idiom: String
        public var isLandscape: Bool
        public var placement: Placement
        /// Tek el modu: sol / sağ / kapalı. Tutuş sapması burada tamamen değişir.
        public var oneHanded: String
        /// Klavye yüksekliği, 8 pt'lik kovalarda.
        public var heightBucket: Int
        /// Klavye genişliği, 32 pt'lik kovalarda.
        public var widthBucket: Int
        /// Ekran ölçeği (@2x/@3x) — aynı nokta ölçüsü farklı piksel yoğunluğunda
        /// farklı dokunma davranışı üretebilir.
        public var scale: Int

        public init(layoutID: String, idiom: String, isLandscape: Bool,
                    height: Double, width: Double,
                    placement: Placement = .docked,
                    oneHanded: String = "off",
                    scale: Int = 2) {
            self.layoutID = layoutID
            self.idiom = idiom
            self.isLandscape = isLandscape
            self.placement = placement
            self.oneHanded = oneHanded
            self.heightBucket = Int((height / 8).rounded())
            self.widthBucket = Int((width / 32).rounded())
            self.scale = scale
        }

        /// **Sürümlü ve kanonik** imza. Alan eklenirse `v` artar ve eski
        /// profiller sessizce yeniden kullanılmaz — yanlış profilden öğrenilen
        /// sapmayı uygulamak zarar verir.
        public var description: String {
            "v2-\(layoutID)-\(idiom)-\(isLandscape ? "L" : "P")-\(placement.rawValue)"
            + "-oh\(oneHanded)-h\(heightBucket)-w\(widthBucket)-s\(scale)"
        }

        /// Dosya adı — profil başına ayrı dosya, kısmi bozulma diğerlerini
        /// etkilemesin diye.
        public var fileName: String { "calib-\(description).bkl" }
    }

    // MARK: - Yazma

    public static func save(_ learner: CalibrationLearner,
                            to directory: URL,
                            profile: ProfileKey) throws {
        let samples = learner.encodedSamples()
        let format = container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(samples.count))
            w.u32(0)                                  // reserved
        }
        w.reserveCapacity(format.headerSize + samples.count * sampleSize)
        for s in samples {
            w.f32(Float(s.point.x))
            w.f32(Float(s.point.y))
            // Güven bayrağı en yüksek bitte: ayrı bir bayt eklemek örnek başına
            // %10 yer israfı olurdu ve tuş indeksi 15 bite fazlasıyla sığıyor.
            let flagged = UInt16(truncatingIfNeeded: s.keyIndex) & 0x7FFF
                | (s.confidence == .weak ? 0x8000 : 0)
            w.u16(flagged)
        }

        let target = directory.appendingPathComponent(profile.fileName)
        try AtomicFile.publish(Data(format.seal(w)), to: target)
        // Dokunma koordinatları kişisel veridir: yedeğe gitmemeli ve cihaz
        // kilitliyken de okunabilir olmalı (klavye kilit ekranında da açılır).
        try AtomicFile.protectPersonalData(target)
    }

    /// Bir profilin verisini siler (kullanıcı ayarlardan "kalibrasyonu sıfırla"
    /// dediğinde). Dosya **gerçekten kaldırılır**; bellekteki rezervuarı
    /// temizlemek yetmez.
    public static func delete(from directory: URL, profile: ProfileKey) throws {
        try AtomicFile.removeIfExists(directory.appendingPathComponent(profile.fileName))
    }

    /// **Tüm** profillerin verisini siler.
    public static func deleteAll(from directory: URL) throws {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent.hasPrefix("calib-") {
            try FileManager.default.removeItem(at: u)
        }
    }

    // MARK: - Okuma

    /// Depoya özgü durumlar. Ortak durumlar (magic, sürüm, checksum, kesiklik,
    /// boyut) `BinaryFormatError`.
    public enum LoadError: Error, CustomStringConvertible {
        case missing
        case badSample(index: Int)

        public var description: String {
            switch self {
            case .missing:           return "kalibrasyon dosyası yok"
            case let .badSample(i):  return "geçersiz örnek: [\(i)]"
            }
        }
    }

    public static func load(from directory: URL,
                            profile: ProfileKey) throws -> CalibrationLearner {
        let url = directory.appendingPathComponent(profile.fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LoadError.missing
        }
        let r = try container.open(data)
        let count = Int(try r.u32(8))

        // **Tam** boyut eşitliği: fazlalık bayta izin vermek aynı sürümün
        // birden çok kanonik temsilini doğururdu ve checksum onları kapsadığı
        // için fark sessizce geçerdi.
        let expected = container.headerSize + count * sampleSize
        guard r.count == expected else {
            throw BinaryFormatError.sizeMismatch(expected: expected, have: r.count)
        }

        var samples: [CalibrationLearner.Sample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let o = container.headerSize + i * sampleSize
            let x = Double(Float(bitPattern: r.unchecked(UInt32.self, o)))
            let y = Double(Float(bitPattern: r.unchecked(UInt32.self, o + 4)))
            let flagged = r.unchecked(UInt16.self, o + 8)
            // Değer doğrulaması: NaN bir koordinat tahmini sessizce NaN yapar
            // ve kalibrasyon uygulanmış gibi görünüp klavyeyi bozardı.
            guard x.isFinite, y.isFinite, x >= -1, x <= 2, y >= -1, y <= 2 else {
                throw LoadError.badSample(index: i)
            }
            samples.append(.init(point: Point(x: x, y: y),
                                 keyIndex: Int(flagged & 0x7FFF),
                                 confidence: (flagged & 0x8000) != 0 ? .weak : .strong))
        }
        return CalibrationLearner(samples: samples)
    }

    /// Yükler; dosya yoksa ya da bozuksa **boş** bir öğrenici döndürür.
    ///
    /// Bozuk bir kalibrasyonla çalışmaktansa kalibrasyonsuz çalışmak yeğdir:
    /// birincisi kullanıcıya aktif zarar verir, ikincisi yalnız faydayı erteler.
    public static func loadOrEmpty(from directory: URL,
                                   profile: ProfileKey) -> CalibrationLearner {
        (try? load(from: directory, profile: profile)) ?? CalibrationLearner()
    }
}
