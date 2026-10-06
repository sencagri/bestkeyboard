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
    static let description = IntentDescription("Bir mesajdaki yapılacakları ayrı maddeler olarak Hatırlatıcılar'a ekler; uygun listeyi seçer, yoksa açar. Servis bağlantısı gerekir.")

    @Parameter(title: "Mesaj") var text: String

    /// Klavyedeki ✦ Hatırlatıcı ile aynı yol: her iş ayrı madde, uygun (ya da yeni) liste.
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        await ReminderMaker.refreshListNames()
        // Kullanıcının Hatırlatıcı tuşundaki istemi burada da geçerli.
        let template = KeyboardSettingsStore.load().aiActions.first { $0.kind == .reminder }?.prompt ?? ""
        let plan = try await AIService.reminders(from: text, template: template)
        let list = try await ReminderMaker.add(plan)
        let summary = plan.items.map { d in
            d.title + (d.due.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
        }.joined(separator: "\n")
        let head = plan.items.count > 1 ? "\(plan.items.count) madde eklendi · \(list)" : "Eklendi · \(list)"
        return .result(value: summary, dialog: "\(head)\n\(summary)")
    }
}

struct EventFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Mesajdan takvim etkinliği yap"
    static let description = IntentDescription("Mesajdaki buluşma ve randevuları Takvim'e ekler. Servis bağlantısı gerekir.")

    @Parameter(title: "Mesaj") var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        EventMaker.refreshCalendarNames()
        let template = KeyboardSettingsStore.load().aiActions.first { $0.kind == .event }?.prompt ?? ""
        let plan = try await AIService.events(from: text, template: template)
        let cal = try await EventMaker.add(plan)
        let summary = plan.items.map { d in
            d.title + " · " + d.start.formatted(date: .abbreviated, time: d.allDay ? .omitted : .shortened)
        }.joined(separator: "\n")
        return .result(value: summary, dialog: "Takvime eklendi · \(cal)\n\(summary)")
    }
}

struct ContactFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Mesajdan kişi kartı yap"
    static let description = IntentDescription("Mesajdaki ad, telefon ve e-postayı Kişiler'e ekler. Servis bağlantısı gerekir.")

    @Parameter(title: "Mesaj") var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let template = KeyboardSettingsStore.load().aiActions.first { $0.kind == .contact }?.prompt ?? ""
        let d = try await AIService.contact(from: text, template: template)
        let name = try await ContactMaker.add(d)
        return .result(value: name, dialog: "Kişilere eklendi · \(name)")
    }
}

struct BestKeyboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReminderFromTextIntent(), phrases: [
            "\(.applicationName) ile hatırlatıcı yap",
            "\(.applicationName) mesajdan hatırlatıcı",
        ], shortTitle: "Mesajdan hatırlatıcı", systemImageName: "checklist")
        AppShortcut(intent: EventFromTextIntent(), phrases: [
            "\(.applicationName) ile takvime ekle",
        ], shortTitle: "Mesajdan etkinlik", systemImageName: "calendar")
        AppShortcut(intent: ContactFromTextIntent(), phrases: [
            "\(.applicationName) ile kişi ekle",
        ], shortTitle: "Mesajdan kişi", systemImageName: "person.crop.circle")
        AppShortcut(intent: RunAIActionIntent(), phrases: [
            "\(.applicationName) yapay zeka tuşu",
        ], shortTitle: "Yapay zeka tuşu", systemImageName: "sparkles")
        AppShortcut(intent: FancyTextIntent(), phrases: [
            "\(.applicationName) fontlu yazı",
        ], shortTitle: "Fontlu yazı", systemImageName: "textformat")
    }
}
