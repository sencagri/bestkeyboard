import AppIntents
import Foundation

/// Kontrol Merkezi düğmeleri. Uygulama ve widget uzantısı ikisi de derliyor:
/// uzantı düğmeyi çiziyor, iş uygulamanın sürecinde yapılıyor
/// (`LiveActivityIntent` uygulamada çalışır). Uygulama `handler`'ı bağlıyor.
enum ControlAction: String, Sendable {
    case screenshotReminder, screenshotEvent, dictation

    /// Kontrol Merkezi'ndeki tür kimliği.
    var kind: String {
        switch self {
        case .screenshotReminder: return AppIdentity.id("control.reminder")
        case .screenshotEvent: return AppIdentity.id("control.event")
        case .dictation: return AppIdentity.id("control.dictation")
        }
    }
    /// Düğmenin altındaki kısa ad.
    var label: String {
        switch self {
        case .screenshotReminder: return "Görüntüden hatırlatıcı"
        case .screenshotEvent: return "Görüntüden takvime"
        case .dictation: return "Sesle yaz"
        }
    }
    /// Denetim ekle listesindeki ad ve açıklama.
    var displayName: String {
        switch self {
        case .screenshotReminder: return "Ekran görüntüsünden hatırlatıcı"
        case .screenshotEvent: return "Ekran görüntüsünden takvime ekle"
        case .dictation: return label
        }
    }
    var summary: String {
        switch self {
        case .screenshotReminder: return "Son ekran görüntüsündeki yapılacakları Hatırlatıcılar'a ekler."
        case .screenshotEvent: return "Son ekran görüntüsündeki buluşmayı Takvim'e ekler."
        case .dictation: return "BestKeyboard'u dikte ekranında açar."
        }
    }
    var symbol: String {
        switch self {
        case .screenshotReminder: return "checklist"
        case .screenshotEvent: return "calendar.badge.plus"
        case .dictation: return "mic.fill"
        }
    }
}

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
        JSONFile.write(Pending(action: action.rawValue, at: Date().timeIntervalSince1970),
                       to: AppGroup.file(AppGroup.File.controlPending))
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
