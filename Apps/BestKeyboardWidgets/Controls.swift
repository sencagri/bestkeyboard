import AppIntents
import SwiftUI
import WidgetKit

// Kontrol Merkezi / kilit ekranı düğmeleri (iOS 18). Görünümü sistem çiziyor:
// simge + başlık. Eklemek: Kontrol Merkezi › + › Denetim ekle › BestKeyboard.
// Ad, açıklama, simge ve tür kimliği `ControlAction`'da.

@available(iOS 18.0, *)
private func control<I: AppIntent>(_ a: ControlAction, _ intent: I) -> some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: a.kind) {
        ControlWidgetButton(action: intent) { Label(a.label, systemImage: a.symbol) }
    }
    .displayName("\(a.displayName)")
    .description("\(a.summary)")
}

@available(iOS 18.0, *)
struct ScreenshotReminderControl: ControlWidget {
    var body: some ControlWidgetConfiguration { control(.screenshotReminder, ScreenshotToReminderIntent()) }
}

@available(iOS 18.0, *)
struct ScreenshotEventControl: ControlWidget {
    var body: some ControlWidgetConfiguration { control(.screenshotEvent, ScreenshotToEventIntent()) }
}

@available(iOS 18.0, *)
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration { control(.dictation, OpenDictationIntent()) }
}
