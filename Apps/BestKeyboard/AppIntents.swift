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

#if DEBUG
/// `-aiProbe <anahtar>`: Cerebras anahtarını (yalnız bu cihazın anahtar zincirine)
/// koyup örnek mesajlarla çıkarımları dener; sonuçlar stdout'ta `AIPROBE` satırları.
enum AIProbe {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-aiProbe"), i + 1 < args.count else { return }
        AIService.setKey(args[i + 1], for: .cerebras)
        AIService.provider = .cerebras
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "EEE d MMM HH:mm"
        let d = { (x: Date?) in x.map(f.string(from:)) ?? "-" }
        let events = [
            "Cumartesi akşam 7'de Kadıköy'de buluşalım, 2 saat kadar otururuz",
            "Can we meet next Tuesday at 3pm at Starbucks Nişantaşı? Should take an hour.",
            "Pazartesi annemin doğum günü, unutma!",
            "Yarın sabah 9:30 diş hekimi, öğleden sonra da 15:00'te toplantı var",
        ]
        Task {
            print("AIPROBE now", d(Date()))
            for m in events {
                do {
                    let p = try await AIService.events(from: m)
                    print("AIPROBE event «\(m)» cal=\(p.calendar ?? "-")")
                    for e in p.items {
                        print("AIPROBE   · \(e.title) | \(d(e.start)) → \(d(e.end)) allDay=\(e.allDay) loc=\(e.location ?? "-")")
                    }
                } catch { print("AIPROBE event FAIL «\(m)»", error.localizedDescription) }
            }
            do {
                let c = try await AIService.contact(from: "Tesisatçının numarası: Murat Kaya 0532 418 77 90, mail murat@kayatesisat.com, Kaya Tesisat'tan")
                print("AIPROBE contact \(c.displayName) | \(c.phones) | \(c.emails) | org=\(c.organization ?? "-")")
            } catch { print("AIPROBE contact FAIL", error.localizedDescription) }
            for m in ["Eve gelirken ekmek, süt ve deterjan al. Yarın da faturayı yatır",
                      "Cumartesi annen gelecek, akşam otogardan alacaksın. 8 yumurta, 5 kedi maması al.",
                      "Pick up the dry cleaning tomorrow and call mom on Friday evening"] {
                do {
                    let r = try await AIService.reminders(from: m)
                    print("AIPROBE reminders «\(m)» list=\(r.list ?? "-")")
                    for x in r.items { print("AIPROBE   · \(x.title) | \(d(x.due))") }
                } catch { print("AIPROBE reminders FAIL", error.localizedDescription) }
            }
            do {
                let a = AIAction.defaults.first { $0.id == "cevir" }!
                print("AIPROBE cevir", try await AIService.complete(a.render(text: "Cumartesi akşam görüşürüz", clipboard: nil)))
            } catch { print("AIPROBE cevir FAIL", error.localizedDescription) }
            print("AIPROBE-DONE")
        }
    }
}
#endif
