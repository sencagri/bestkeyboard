import AppIntents
import Foundation

/// Kontrol Merkezi düğmeleri. Uygulama ve widget uzantısı ikisi de derliyor:
/// uzantı düğmeyi çiziyor, iş uygulamanın sürecinde yapılıyor
/// (`LiveActivityIntent` uygulamada çalışır). Uygulama `handler`'ı bağlıyor.
enum ControlAction: String, Sendable { case screenshotReminder, screenshotEvent, dictation }

enum ControlActions {
    @MainActor static var handler: ((ControlAction) async -> Void)?


    /// Eklentide kalan basış: hangi düğme, ne zaman. **Tek iş** politikası: yeni
    /// basış eskisinin yerine geçer (kullanıcının son niyeti).
    struct Pending: Codable {
        let action: String
        let at: TimeInterval
        var date: Date { Date(timeIntervalSince1970: at) }
        var isFresh: Bool { Date().timeIntervalSince1970 - at < AppGroup.handoffTTL }
    }

    /// Uygulamada çalışıyorsak işi yap; değilse (iOS eylemi widget eklentisinde
    /// çalıştırdıysa) basışı ortak depoya bırak — uygulama açılınca tamamlıyor.
    @MainActor static func run(_ action: ControlAction) async {
        if let handler { await handler(action); return }
        let p = Pending(action: action.rawValue, at: Date().timeIntervalSince1970)
        guard let url = AppGroup.file(AppGroup.File.controlPending),
              let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Bekleyen basışı sahiplenir (bir kez; `AppGroup.claim`).
    static func claimPending() -> Pending? {
        AppGroup.claim(AppGroup.File.controlPending).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
    }
}

struct ScreenshotToReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ekran görüntüsünden hatırlatıcı"
    static let description = IntentDescription("Son ekran görüntüsündeki yapılacakları Hatırlatıcılar'a ekler.")
    func perform() async throws -> some IntentResult {
        await ControlActions.run(.screenshotReminder)
        return .result()
    }
}

struct ScreenshotToEventIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ekran görüntüsünden takvime ekle"
    static let description = IntentDescription("Son ekran görüntüsündeki buluşma ya da randevuyu Takvim'e ekler.")
    func perform() async throws -> some IntentResult {
        await ControlActions.run(.screenshotEvent)
        return .result()
    }
}

/// Sesle yaz: uygulamayı dikte ekranında açar.
struct OpenDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Sesle yaz"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await ControlActions.run(.dictation)
        return .result()
    }
}
