import SwiftUI
import KBGeometry
import KBSessions

/// Kayıt kimliği — katılımcı ve oturum sırası. Kayıt listesi ve hızlı kayıt
/// **aynı** sayacı kullanıyor: önce biri "kullan sonra artır", öbürü "artır
/// sonra kullan" yapıyordu ve art arda kullanılınca aynı sıra iki oturuma
/// veriliyordu (oturum-ayrık split bozulur, §12.8).
enum RecordingIdentity {
    private static let participantKey = "participantID"
    private static let ordinalKey = "sessionOrdinal"
    private static var store: UserDefaults { .standard }

    /// Kararlı ve anonim katılımcı kimliği; cihaz başına bir kez üretilir.
    static var participantID: String {
        if let id = store.string(forKey: participantKey), !id.isEmpty { return id }
        let id = UUID.short
        store.set(id, forKey: participantKey)
        return id
    }

    /// Yeni oturumun sırası — **monoton**: silinen bir kayıt yüzünden yeniden
    /// kullanılmıyor.
    static func nextOrdinal() -> Int {
        let n = store.integer(forKey: ordinalKey)
        store.set(n + 1, forKey: ordinalKey)
        return n
    }
}
