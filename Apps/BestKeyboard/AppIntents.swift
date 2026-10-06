import AppIntents
import EventKit
import KBRuntime
import UIKit

// Kestirmeler (Shortcuts) eylemleri — klavyenin işlerini Siri'ye ve
// otomasyonlara açıyor. Ekranları sistemin; bizim çizdiğimiz yüzey yok.

enum FancyStyleOption: String, AppEnum {
    case bold, italic, boldItalic, script, boldScript, fraktur, doubleStruck, sans, sansBold, mono, circled

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Yazı stili"
    static let caseDisplayRepresentations: [FancyStyleOption: DisplayRepresentation] = [
        .bold: "𝐊𝐚𝐥ı𝐧", .italic: "𝐼𝑡𝑎𝑙𝑖𝑘", .boldItalic: "𝑲𝒂𝒍ı𝒏 𝒊𝒕𝒂𝒍𝒊𝒌",
        .script: "𝐸𝓁 𝓎𝒶𝓏ı𝓈ı", .boldScript: "𝓚𝓪𝓵ı𝓷 𝓮𝓵 𝔂𝓪𝔃ı𝓼ı", .fraktur: "𝔊𝔬𝔱𝔦𝔨",
        .doubleStruck: "ℂ𝕚𝕗𝕥 𝕔𝕚𝕫𝕘𝕚", .sans: "𝖲𝖺𝖽𝖾", .sansBold: "𝗦𝗮𝗱𝗲 𝗸𝗮𝗹ı𝗻",
        .mono: "𝙳𝚊𝚔𝚝𝚒𝚕𝚘", .circled: "Ⓨⓤⓥⓐⓡⓛⓐⓚ",
    ]
    var style: FancyText.Style { FancyText.Style(rawValue: rawValue) ?? .bold }
}

struct FancyTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Fontlu yazıya çevir"
    static let description = IntentDescription("Metni her uygulamada görünen stilli harflere çevirir.")

    @Parameter(title: "Metin") var text: String
    @Parameter(title: "Stil", default: .bold) var style: FancyStyleOption

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: FancyText.apply(style.style, to: text))
    }
}

struct RunAIActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Yapay zeka tuşunu çalıştır"
    static let description = IntentDescription("Yapay zeka tuşlarından birini (Çevir, Düzelt…) metne uygular. Servis bağlantısı gerekir.")

    @Parameter(title: "Tuş adı", default: "Çevir") var actionName: String
    @Parameter(title: "Metin") var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let actions = KeyboardSettingsStore.load().aiActions
        let fold = { (s: String) in s.lowercased(with: Locale(identifier: "tr")) }
        guard let a = actions.first(where: { fold($0.name) == fold(actionName) }), a.kind == .text else {
            throw IntentError.message("“\(actionName)” adlı bir metin tuşu yok.")
        }
        let clip = await MainActor.run { UIPasteboard.general.string }
        return .result(value: try await AIService.complete(a.render(text: text, clipboard: clip)))
    }
}

struct ReminderFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Mesajdan hatırlatıcı yap"
    static let description = IntentDescription("Bir mesajdan başlığı ve zamanı çıkarıp Hatırlatıcılar'a ekler. Servis bağlantısı gerekir.")

    @Parameter(title: "Mesaj") var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let draft = try await AIService.reminder(from: text)
        try await ReminderMaker.add(draft)
        let when = draft.due.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        let summary = draft.title + when
        return .result(value: summary, dialog: "Eklendi: \(summary)")
    }
}

enum IntentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

/// Hatırlatıcılar'a yazma — izni **uygulama** istiyor; klavye eklentisine
/// iOS bu izni vermiyor.
enum ReminderMaker {
    /// - Returns: eklendiği listenin adı (kullanıcı nerede bulacağını bilsin).
    @discardableResult
    static func add(_ d: AIService.ReminderDraft) async throws -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted {
            throw IntentError.message("Hatırlatıcılar izni kapalı: Ayarlar › BestKeyboard › Hatırlatıcılar › Tam Erişim.")
        }
        guard try await store.requestFullAccessToReminders() else {
            throw IntentError.message("Hatırlatıcılar izni verilmedi: Ayarlar › BestKeyboard › Hatırlatıcılar.")
        }
        // Varsayılan liste bazı hesaplarda yok (iCloud Hatırlatıcılar kapalı,
        // yalnız Exchange…); o zaman yazılabilir ilk liste.
        guard let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else {
            throw IntentError.message("Yazılabilir bir hatırlatıcı listesi yok. Hatırlatıcılar uygulamasında bir liste oluştur.")
        }
        let r = EKReminder(eventStore: store)
        r.title = d.title
        r.notes = d.notes
        r.calendar = list
        if let due = d.due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        // Gerçekten yazıldı mı — sessiz bir başarısızlık "eklendi" dememeli.
        guard store.calendarItem(withIdentifier: r.calendarItemIdentifier) != nil else {
            throw IntentError.message("Hatırlatıcı kaydedilemedi (\(list.title) listesi).")
        }
        return list.title
    }
}

struct BestKeyboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReminderFromTextIntent(), phrases: [
            "\(.applicationName) ile hatırlatıcı yap",
            "\(.applicationName) mesajdan hatırlatıcı",
        ], shortTitle: "Mesajdan hatırlatıcı", systemImageName: "checklist")
        AppShortcut(intent: RunAIActionIntent(), phrases: [
            "\(.applicationName) yapay zeka tuşu",
        ], shortTitle: "Yapay zeka tuşu", systemImageName: "sparkles")
        AppShortcut(intent: FancyTextIntent(), phrases: [
            "\(.applicationName) fontlu yazı",
        ], shortTitle: "Fontlu yazı", systemImageName: "textformat")
    }
}
