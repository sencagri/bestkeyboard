import Foundation
import KBGeometry

/// Kaydın **kendi** geometrisini kurar.
///
/// ## Neden gerekli
///
/// Kayıt ekranı kullanıcının günlük kullandığı ölçülerde yazdırıyor: tuş
/// genişlikleri, üst sayı sırası ve alt satır yüksekliği kişiye özel. `layoutID`
/// bu ölçüleri kayıpsız kodluyor (`tr-Q-n1-s150-b150-r144`) ve `layoutFingerprint`
/// sonucu doğruluyor.
///
/// Replay ve analiz tarafı ise **varsayılan** geometriyi kuruyordu. Sonuç: klavye
/// ölçüsünü bir kademe değiştiren kullanıcının bütün kayıtları doğrulanamaz hâle
/// geliyordu. 28 gerçek kayıtta ölçüldü — hepsi "layout parmak izi farklı",
/// 1096 fark ve **0 yorumlanabilir** karşılaştırma.
///
/// Bu sessiz bir kayıp değildi (ortam uyuşmazlığı raporlanıyordu) ama etkisi
/// toplam: golden doğrulama o kullanıcı için hiçbir zaman çalışamazdı.
public enum RecordedLayout {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `layoutID` tanınmıyor — başka bir düzen ya da başka bir sürüm.
        case unknownLayoutID(String)
        /// Ölçüler çözüldü ama parmak izi tutmuyor.
        ///
        /// Kimlik aynı, içerik farklı: tuş sırası ya da `asciiBase` değişmiş
        /// olabilir. Kurulan geometriyi yine de kullanmak, farklı bir klavyeyi
        /// aynı sanmak olurdu.
        case fingerprintMismatch(recorded: String, rebuilt: String)
    }

    /// Kaydın layout'unu kurar ve parmak iziyle **doğrular**.
    ///
    /// - Returns: doğrulanmış layout.
    /// - Throws: kimlik tanınmıyorsa ya da parmak izi tutmuyorsa. Sessizce
    ///   varsayılana düşmek, başka bir geometriyle koşan bir replay'in farkını
    ///   "kod değişti" diye okumak olurdu.
    public static func resolve(_ session: CanonicalSession) throws -> KeyLayout {
        let id = session.geometry.layoutID
        guard let metrics = TurkishQ.metrics(fromLayoutID: id) else {
            throw Failure.unknownLayoutID(id)
        }

        let layout = TurkishQ.layout(metrics: metrics)
        // Parmak izi **tek kanıt**: `layoutID` ölçüleri kodluyor ama tuş sırası
        // ve `asciiBase` gibi olguları kodlamıyor.
        switch session.geometry.layoutFingerprint {
        case let .known(recorded) where recorded != layout.fingerprint:
            throw Failure.fingerprintMismatch(recorded: recorded,
                                              rebuilt: layout.fingerprint)
        case .known, .unknown, .notApplicable:
            // v2 kayıtlarında parmak izi yok; kimlik doğru çözüldüyse elde
            // olan en iyi şey bu ve `ReplayEngineFactory` `.unknown`'ı zaten
            // ortam olgusu olarak raporluyor.
            return layout
        }
    }

    /// Çözülemezse `nil` — çağıran varsayılana düşmek yerine **atlamak**
    /// isteyebilir.
    static func resolveOrNil(_ session: CanonicalSession) -> KeyLayout? {
        try? resolve(session)
    }
}

extension RecordedLayout.Failure {
    public var description: String {
        switch self {
        case let .unknownLayoutID(id):
            return "tanınmayan layout kimliği: \(id)"
        case let .fingerprintMismatch(recorded, rebuilt):
            return "layout parmak izi tutmuyor: kayıt \(recorded), kurulan \(rebuilt)"
        }
    }
}
