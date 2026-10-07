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

/// Kullanıcının metin tuşları Siri'ye "varlık" olarak: liste dinamik, tuş
/// eklenip silindikçe `updateAppShortcutParameters()` ile Siri'ye bildiriliyor.
/// Böylece "BestKeyboard ile Kibarlaştır" ya da kullanıcının kendi eklediği
/// "Almancaya çevir" adıyla tanınıyor.
struct AIActionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Yapay zeka tuşu"
    static let defaultQuery = AIActionQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AIActionQuery: EntityStringQuery {
    private func all() -> [AIActionEntity] {
        KeyboardSettingsStore.load().aiActions.filter { $0.kind == .text }.map { AIActionEntity(id: $0.id, name: $0.name) }
    }
    func entities(for identifiers: [String]) async throws -> [AIActionEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [AIActionEntity] { all() }
    func entities(matching string: String) async throws -> [AIActionEntity] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr")) }
        return all().filter { fold($0.name).contains(fold(string)) }
    }
}

struct RunAIActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Yapay zeka tuşunu çalıştır"
    static let description = IntentDescription("Yapay zeka tuşlarından birini (Çevir, Kibarlaştır, kendi tuşların…) metne uygular. Servis bağlantısı gerekir.")

    @Parameter(title: "Tuş") var action: AIActionEntity
    @Parameter(title: "Metin", requestValueDialog: "Hangi metin?") var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) tuşunu \(\.$text) metnine uygula")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let actions = KeyboardSettingsStore.load().aiActions
        guard let a = actions.first(where: { $0.id == action.id }), a.kind == .text else {
            throw IntentError.message("“\(action.name)” adlı bir metin tuşu yok.")
        }
        let clip = await MainActor.run { UIPasteboard.general.string }
        let out = try await AILog.measure(origin: .shortcut, action: a.name, source: "Kestirme girdisi", text: text,
                                          summarize: { (t: String) in t }) {
            try await AIService.complete(a.render(text: text, clipboard: clip))
        }.value
        // Sonuç panoya da: Siri'den sonra yapıştırılabilsin.
        await MainActor.run { UIPasteboard.general.string = out }
        return .result(value: out, dialog: "\(out)")
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
        let plan = try await AILog.measure(origin: .shortcut, action: "Hatırlatıcı", source: "Kestirme girdisi", text: text,
                                           summarize: { (p: AIService.ReminderPlan) in "\(p.items.count) madde" }) {
            try await AIService.reminders(from: text, template: template)
        }.value
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
        let plan = try await AILog.measure(origin: .shortcut, action: "Takvim", source: "Kestirme girdisi", text: text,
                                           summarize: { (p: AIService.EventPlan) in p.items.map(\.title).joined(separator: "; ") }) {
            try await AIService.events(from: text, template: template)
        }.value
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
        let d = try await AILog.measure(origin: .shortcut, action: "Kişi", source: "Kestirme girdisi", text: text,
                                        summarize: { (d: AIService.ContactDraft) in d.displayName }) {
            try await AIService.contact(from: text, template: template)
        }.value
        let name = try await ContactMaker.add(d)
        return .result(value: name, dialog: "Kişilere eklendi · \(name)")
    }
}

/// Siri: "BestKeyboard ile son ekran görüntüsünden hatırlatıcı oluştur".
/// Kontrol Merkezi düğmesinin işi; sonucu Siri sesli söylüyor.
struct ScreenshotReminderSiriIntent: AppIntent {
    static let title: LocalizedStringResource = "Son ekran görüntüsünden hatırlatıcı"
    static let description = IntentDescription("Son 15 dakikadaki ekran görüntüsünün yazısını okuyup yapılacakları Hatırlatıcılar'a ekler.")
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let s = try await ControlRunner.perform(event: false, origin: .shortcut)
        return .result(value: s, dialog: "\(s)")
    }
}

struct ScreenshotEventSiriIntent: AppIntent {
    static let title: LocalizedStringResource = "Son ekran görüntüsünden etkinlik"
    static let description = IntentDescription("Son 15 dakikadaki ekran görüntüsündeki buluşma ya da randevuyu Takvim'e ekler.")
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let s = try await ControlRunner.perform(event: true, origin: .shortcut)
        return .result(value: s, dialog: "\(s)")
    }
}

enum ImageTarget: String, AppEnum {
    case event, reminder, contact
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nereye"
    static let caseDisplayRepresentations: [ImageTarget: DisplayRepresentation] = [
        .event: "Takvim", .reminder: "Hatırlatıcılar", .contact: "Kişiler",
    ]
}

/// Ekran görüntüsünden (ya da herhangi bir resimden) etkinlik / hatırlatıcı / kişi.
/// Arkaya Dokun → "Ekran Görüntüsü Al" + bu eylem: sohbetten çıkmadan eklenir.
struct AddFromImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Resimden ekle"
    static let description = IntentDescription("Ekran görüntüsündeki ya da resimdeki yazıyı okuyup Takvim'e, Hatırlatıcılar'a ya da Kişiler'e ekler. Yazı telefonda okunur; çıkarım için servis bağlantısı gerekir.")

    @Parameter(title: "Resim") var image: IntentFile
    @Parameter(title: "Nereye", default: .event) var target: ImageTarget

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$image) içindekini \(\.$target) uygulamasına ekle")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let img = UIImage(data: image.data) else { throw IntentError.message("Resim okunamadı.") }
        guard let text = await TextRecognizer.text(in: img), !text.isEmpty else {
            throw IntentError.message("Resimde okunabilen yazı yok.")
        }
        let actions = KeyboardSettingsStore.load().aiActions
        func template(_ k: AIAction.Kind) -> String { actions.first { $0.kind == k }?.prompt ?? "" }
        switch target {
        case .event:
            EventMaker.refreshCalendarNames()
            let plan = try await AILog.measure(origin: .shortcut, action: "Resimden · Takvim", source: "Resim yazısı", text: text,
                                               summarize: { (p: AIService.EventPlan) in p.items.map(\.title).joined(separator: "; ") }) {
                try await AIService.events(from: text, template: template(.event))
            }.value
            let cal = try await EventMaker.add(plan)
            let s = plan.items.map { $0.title + " · " + $0.start.formatted(date: .abbreviated, time: $0.allDay ? .omitted : .shortened) }
                .joined(separator: "\n")
            return .result(value: s, dialog: "Takvime eklendi · \(cal)\n\(s)")
        case .reminder:
            await ReminderMaker.refreshListNames()
            let plan = try await AILog.measure(origin: .shortcut, action: "Resimden · Hatırlatıcı", source: "Resim yazısı", text: text,
                                               summarize: { (p: AIService.ReminderPlan) in "\(p.items.count) madde" }) {
                try await AIService.reminders(from: text, template: template(.reminder))
            }.value
            let list = try await ReminderMaker.add(plan)
            let s = plan.items.map(\.title).joined(separator: "\n")
            return .result(value: s, dialog: "\(plan.items.count) madde eklendi · \(list)\n\(s)")
        case .contact:
            let d = try await AILog.measure(origin: .shortcut, action: "Resimden · Kişi", source: "Resim yazısı", text: text,
                                            summarize: { (d: AIService.ContactDraft) in d.displayName }) {
                try await AIService.contact(from: text, template: template(.contact))
            }.value
            let name = try await ContactMaker.add(d)
            return .result(value: name, dialog: "Kişilere eklendi · \(name)")
        }
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
        AppShortcut(intent: AddFromImageIntent(), phrases: [
            "\(.applicationName) ile ekran görüntüsünden ekle",
        ], shortTitle: "Resimden ekle", systemImageName: "text.viewfinder")
        AppShortcut(intent: ScreenshotReminderSiriIntent(), phrases: [
            "\(.applicationName) ile son ekran görüntüsünden hatırlatıcı oluştur",
            "\(.applicationName) ile ekran görüntüsünden hatırlatıcı",
        ], shortTitle: "Görüntüden hatırlatıcı", systemImageName: "checklist")
        AppShortcut(intent: ScreenshotEventSiriIntent(), phrases: [
            "\(.applicationName) ile ekran görüntüsünü takvime ekle",
            "\(.applicationName) ile son ekran görüntüsünden etkinlik oluştur",
        ], shortTitle: "Görüntüden takvime", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: RunAIActionIntent(), phrases: [
            "\(.applicationName) ile \(\.$action)",
            "\(.applicationName) \(\.$action) tuşunu çalıştır",
            "\(.applicationName) yapay zeka tuşu",
        ], shortTitle: "Yapay zeka tuşu", systemImageName: "sparkles")
        AppShortcut(intent: FancyTextIntent(), phrases: [
            "\(.applicationName) fontlu yazı",
        ], shortTitle: "Fontlu yazı", systemImageName: "textformat")
    }
}

#if DEBUG
private func XCTUnwrapLike<T>(_ v: T?) throws -> T {
    guard let v else { throw IntentError.message("bulunamadı") }
    return v
}

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
            "Selam, nasılsın?",
        ]
        Task {
            // `-siriProbe`: Siri'nin çağıracağı eylemler (son ekran görüntüsü + adıyla tuş).
            if args.contains("-siriProbe") {
                do {
                    let r = try await ScreenshotReminderSiriIntent().perform()
                    print("AIPROBE siri-reminder OK", String(describing: r.value ?? "-"))
                } catch { print("AIPROBE siri-reminder FAIL", error.localizedDescription) }
                do {
                    let ents = try await AIActionQuery().entities(matching: "kibar")
                    var intent = RunAIActionIntent()
                    intent.action = try XCTUnwrapLike(ents.first)
                    intent.text = "abi yarın gelemiyorum işler çok yoğun"
                    let r = try await intent.perform()
                    print("AIPROBE siri-key OK", ents.map(\.name), String(describing: r.value ?? "-"))
                } catch { print("AIPROBE siri-key FAIL", error.localizedDescription) }
                print("AIPROBE-DONE")
                return
            }
            // `-aiProbeImage <yol>`: Kestirmeler "Resimden ekle" eylemi bu resimle (Takvim).
            if let j = args.firstIndex(of: "-aiProbeImage"), j + 1 < args.count,
               let data = FileManager.default.contents(atPath: args[j + 1]) {
                var intent = AddFromImageIntent()
                intent.image = IntentFile(data: data, filename: "ekran.png")
                intent.target = .event
                do {
                    let r = try await intent.perform()
                    print("AIPROBE image OK", String(describing: r.value ?? "-"))
                } catch { print("AIPROBE image FAIL", error.localizedDescription) }
                print("AIPROBE-DONE")
                return
            }
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
