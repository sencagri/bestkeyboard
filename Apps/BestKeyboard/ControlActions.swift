import AppIntents
import Foundation

/// Kontrol Merkezi düğmeleri. Uygulama ve widget uzantısı ikisi de derliyor:
/// uzantı düğmeyi çiziyor, iş uygulamanın sürecinde yapılıyor
/// (`LiveActivityIntent` uygulamada çalışır). Uygulama `handler`'ı bağlıyor.
enum ControlAction: String, Sendable { case screenshotReminder, screenshotEvent, dictation }

enum ControlActions {
    @MainActor static var handler: ((ControlAction) async -> Void)?
}

struct ScreenshotToReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ekran görüntüsünden hatırlatıcı"
    static let description = IntentDescription("Son ekran görüntüsündeki yapılacakları Hatırlatıcılar'a ekler.")
    func perform() async throws -> some IntentResult {
        await ControlActions.handler?(.screenshotReminder)
        return .result()
    }
}

struct ScreenshotToEventIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ekran görüntüsünden takvime ekle"
    static let description = IntentDescription("Son ekran görüntüsündeki buluşma ya da randevuyu Takvim'e ekler.")
    func perform() async throws -> some IntentResult {
        await ControlActions.handler?(.screenshotEvent)
        return .result()
    }
}

/// Sesle yaz: uygulamayı dikte ekranında açar.
struct OpenDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Sesle yaz"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await ControlActions.handler?(.dictation)
        return .result()
    }
}
