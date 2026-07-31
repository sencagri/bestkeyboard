import Foundation
import KBRuntime

/// Son kullanılan emoji'nin kalıcı deposu.
///
/// ## Neden `UserDefaults`, kalibrasyon gibi bir dosya değil
///
/// `CalibrationStore` ve `PersonalLexiconStore` kendi binary formatlarını
/// taşıyor çünkü içerikleri **kişisel veri** ve dosya koruma sınıfı,
/// yedeklenmeme, atomik yazma gibi gereklerin hepsi orada anlamlı. Son
/// kullanılan emoji bir UI kolaylığı: kaybolması kullanıcıya bir şey
/// kaybettirmiyor, ve `KeyboardSettings` zaten aynı sınıf veriyi (`UserDefaults`)
/// aynı sandbox'ta tutuyor. İkinci bir ikili format eklemek, bakım maliyetini
/// hiçbir karşılığı olmadan artırırdı.
///
/// Depo yine **uzantının kendi sandbox'ında**: App Group yok, tek yazar biziz.
enum EmojiRecentsStore {

    private static let key = "kb.emoji.recents"
    private static let defaults = UserDefaults.standard

    static func load() -> EmojiRecents {
        // `EmojiRecents.init` bozuk listeyi kendi temizliyor: tekrarları
        // düşürüyor ve sınırı uyguluyor. Burada ayrıca doğrulamak, aynı kuralı
        // iki yerde tutmak olurdu.
        EmojiRecents(items: defaults.stringArray(forKey: key) ?? [])
    }

    static func save(_ recents: EmojiRecents) {
        defaults.set(recents.items, forKey: key)
    }

    static func reset() {
        defaults.removeObject(forKey: key)
    }
}
