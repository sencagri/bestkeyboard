import SwiftUI
import KBRuntime

/// Uygulamaya gelen adresin ne istediği — bütün `bestkeyboard://` (ve paylaşılan
/// dosya) ayrıştırması burada; ekran yalnız sonucu gösteriyor.
enum AppRoute {
    case sharedFile(URL)
    case dictation
    case reminder(ReminderHandoff)
    case event(EventHandoff)
    case contact(ContactHandoff)
    case tickTickReturned(URL)
    case shortcutResult(ShortcutResultPayload)

    init?(_ url: URL) {
        if url.isFileURL { self = .sharedFile(url) }
        else if DeepLink.matches(url, .dictation) { self = .dictation }
        else if let r = ReminderHandoff(url: url) { self = .reminder(r) }
        else if let e = EventHandoff(url: url) { self = .event(e) }
        else if let c = ContactHandoff(url: url) { self = .contact(c) }
        else if DeepLink.matches(url, .tickTickNext) { self = .tickTickReturned(url) }
        else if DeepLink.matches(url, .shortcutResult) {
            let message = DeepLink.value(DeepLink.Param.shortcutError, in: url)
            self = .shortcutResult(ShortcutResultPayload(
                result: DeepLink.value(DeepLink.Param.shortcutResult, in: url),
                failed: DeepLink.has(DeepLink.Param.error, in: url) || message != nil,
                errorMessage: message))
        } else { return nil }
    }
}
