import ActivityKit
import AppIntents
import Foundation

/// Sesle yazmanın Dinamik Ada / kilit ekranı görünümü — tasarım tuvali
/// "19 · Sesle yazma adası". Uygulama ve widget uzantısı ikisi de derliyor:
/// uzantı çiziyor, uygulama başlatıp güncelliyor.
struct DictationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Dinliyor mu (duraklatılmışsa `false`).
        var listening: Bool
        /// Sayaç: dinlerken `Text(timerInterval:)` buradan sayıyor.
        var runStart: Date
        /// Duraklatılmışken gösterilen sabit süre.
        var elapsed: TimeInterval
        /// Son birkaç kelime — adada tek iki satır yer var.
        var tail: String
        /// Metin klavyeye gönderildi.
        var done: Bool
    }
}

/// Adadaki düğmeler. `LiveActivityIntent` uygulamanın sürecinde çalışıyor;
/// uzantı yalnız düğmeyi çiziyor. İşi uygulama `handler` ile bağlıyor.
enum DictationIslandAction: Sendable { case toggle, finish }

enum DictationIsland {
    @MainActor static var handler: ((DictationIslandAction) async -> Void)?
}

struct ToggleDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sesle yazmayı duraklat / sürdür"
    func perform() async throws -> some IntentResult {
        await DictationIsland.handler?(.toggle)
        return .result()
    }
}

struct FinishDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sesle yazmayı bitir ve klavyeye yaz"
    func perform() async throws -> some IntentResult {
        await DictationIsland.handler?(.finish)
        return .result()
    }
}
