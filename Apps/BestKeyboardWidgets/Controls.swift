import AppIntents
import SwiftUI
import WidgetKit

// Kontrol Merkezi / kilit ekranı düğmeleri (iOS 18). Görünümü sistem çiziyor:
// simge + başlık. Eklemek: Kontrol Merkezi › + › Denetim ekle › BestKeyboard.

@available(iOS 18.0, *)
struct ScreenshotReminderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.sencagri.bestkeyboard.control.reminder") {
            ControlWidgetButton(action: ScreenshotToReminderIntent()) {
                Label("Görüntüden hatırlatıcı", systemImage: "checklist")
            }
        }
        .displayName("Ekran görüntüsünden hatırlatıcı")
        .description("Son ekran görüntüsündeki yapılacakları Hatırlatıcılar'a ekler.")
    }
}

@available(iOS 18.0, *)
struct ScreenshotEventControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.sencagri.bestkeyboard.control.event") {
            ControlWidgetButton(action: ScreenshotToEventIntent()) {
                Label("Görüntüden takvime", systemImage: "calendar.badge.plus")
            }
        }
        .displayName("Ekran görüntüsünden takvime ekle")
        .description("Son ekran görüntüsündeki buluşmayı Takvim'e ekler.")
    }
}

@available(iOS 18.0, *)
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.sencagri.bestkeyboard.control.dictation") {
            ControlWidgetButton(action: OpenDictationIntent()) {
                Label("Sesle yaz", systemImage: "mic.fill")
            }
        }
        .displayName("Sesle yaz")
        .description("BestKeyboard'u dikte ekranında açar.")
    }
}
