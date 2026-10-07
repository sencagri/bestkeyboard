import Contacts
import Vision
import EventKit
import SwiftUI
import UIKit

// Klavyeden gelen planları Apple uygulamalarına (Takvim, Kişiler) ve
// yapılacaklar uygulamalarına (Things, Todoist, TickTick) yazan katman.
// İzinleri uygulama istiyor; klavye eklentisine iOS bu izinleri vermiyor.

enum IntentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

/// Hatırlatıcılar'a yazma — izni **uygulama** istiyor; klavye eklentisine
/// iOS bu izni vermiyor.
enum ReminderMaker {
    /// İzin varsa Hatırlatıcılar listelerinin adlarını ortak depoya yazar —
    /// klavye bunları modele "uygun listeyi seç" diye veriyor. İzin yoksa `nil`.
    @discardableResult
    static func refreshListNames() async -> [String]? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return nil }
        let names = EKEventStore().calendars(for: .reminder)
            .filter(\.allowsContentModifications).map(\.title)
        AIService.reminderLists = names
        return names
    }

    /// Tek madde (Kestirmeler eylemi).
    @discardableResult
    static func add(_ d: AIService.ReminderDraft) async throws -> String {
        try await add(AIService.ReminderPlan(list: nil, items: [d]))
    }

    /// Hatırlatıcılar'da yeni liste — varsayılan listenin hesabında (iCloud'daysa
    /// iCloud'da, diğer cihazlarda da görünsün).
    private static func createList(named name: String, in store: EKEventStore) throws -> EKCalendar? {
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else { return nil }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// Hatırlatıcılar'ı açan adres; tek madde eklendiyse doğrudan ona gidiyor.
    static func openURL(_ id: String?) -> URL? {
        URL(string: id.map { "x-apple-reminderkit://REMCDReminder/\($0)" } ?? "x-apple-reminderkit://")
    }

    /// Maddelerin hepsini **ayrı** hatırlatıcı olarak ekler ve bildirimle onaylar
    /// (dokununca Hatırlatıcılar açılıyor).
    /// - Returns: eklendiği listenin adı (kullanıcı nerede bulacağını bilsin).
    @discardableResult
    static func add(_ plan: AIService.ReminderPlan, notify: Bool = true) async throws -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted {
            throw IntentError.message("Hatırlatıcılar izni kapalı: Ayarlar › BestKeyboard › Hatırlatıcılar › Tam Erişim.")
        }
        guard try await store.requestFullAccessToReminders() else {
            throw IntentError.message("Hatırlatıcılar izni verilmedi: Ayarlar › BestKeyboard › Hatırlatıcılar.")
        }
        let writable = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        AIService.reminderLists = writable.map(\.title)
        // İstenen liste (ad eşleşmesi) → yoksa o adla **yeni liste** → varsayılan → yazılabilir ilk liste.
        let wanted = try plan.list.flatMap { name in
            try writable.first { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? createList(named: name, in: store)
        }
        guard let list = wanted ?? store.defaultCalendarForNewReminders() ?? writable.first else {
            throw IntentError.message("Yazılabilir bir hatırlatıcı listesi yok. Hatırlatıcılar uygulamasında bir liste oluştur.")
        }
        var saved: [EKReminder] = []
        for d in plan.items {
            let r = EKReminder(eventStore: store)
            r.title = d.title
            r.notes = d.notes
            r.calendar = list
            if let due = d.due {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                r.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(r, commit: false)
            saved.append(r)
        }
        try store.commit()
        // Gerçekten yazıldı mı — sessiz bir başarısızlık "eklendi" dememeli.
        guard saved.allSatisfy({ store.calendarItem(withIdentifier: $0.calendarItemIdentifier) != nil }) else {
            throw IntentError.message("Hatırlatıcılar kaydedilemedi (\(list.title) listesi).")
        }
        if notify {
            let title = saved.count > 1 ? "\(saved.count) madde eklendi · \(list.title)" : "Hatırlatıcı eklendi · \(list.title)"
            let body = plan.items.map { d in
                d.title + (d.due.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
            }.joined(separator: "\n")
            await Notifier.shared.post(title: title, body: body,
                                       url: openURL(saved.count == 1 ? saved[0].calendarItemIdentifier : nil))
        }
        return list.title
    }
}

/// Resimdeki yazı (cihazda, Vision) — sohbet ekran görüntüsü, afiş, kartvizit.
enum TextRecognizer {
    static func text(in img: UIImage) async -> String? {
        guard let cg = img.cgImage else { return nil }
        return await withCheckedContinuation { c in
            let req = VNRecognizeTextRequest { r, _ in
                let lines = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }
                c.resume(returning: lines?.joined(separator: "\n"))
            }
            req.recognitionLevel = .accurate
            req.automaticallyDetectsLanguage = true
            req.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { c.resume(returning: nil) }
            }
        }
    }
}

/// Takvim etkinlikleri (EventKit).
enum EventMaker {
    /// İzin varsa takvim adlarını ortak depoya yazar (klavye "uygun takvim" için).
    @discardableResult
    static func refreshCalendarNames() -> [String]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let names = EKEventStore().calendars(for: .event).filter(\.allowsContentModifications).map(\.title)
        AIService.eventCalendars = names
        return names
    }

    /// Düzenleme sayfasındaki seçim için takvimler ve renkleri (izin varsa).
    /// Aynı adlı iki takvim (ör. iki hesapta "İş") kimlikle ayrılıyor; adın
    /// yanında hesap adı da gösteriliyor.
    struct Choice: Identifiable {
        let id: String
        let title: String
        let account: String
        let color: Color
    }

    static func calendarChoices() -> [Choice] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKEventStore().calendars(for: .event).filter(\.allowsContentModifications)
            .map { Choice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(cgColor: $0.cgColor)) }
    }

    /// Modelin önerdiği ada (yoksa varsayılana) karşılık gelen takvimin kimliği.
    static func calendarID(named name: String?) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        return resolve(name, in: store.calendars(for: .event).filter(\.allowsContentModifications), store: store)?
            .calendarIdentifier
    }

    /// Ad birden çok takvime uyuyorsa varsayılan takvimin hesabındaki seçiliyor.
    private static func resolve(_ name: String?, in writable: [EKCalendar], store: EKEventStore) -> EKCalendar? {
        let def = store.defaultCalendarForNewEvents
        guard let name else { return def ?? writable.first }
        let matches = writable.filter { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return matches.first { $0.source.sourceIdentifier == def?.source.sourceIdentifier } ?? matches.first ?? def ?? writable.first
    }

    /// - Returns: eklendiği takvimin adı.
    @discardableResult
    static func add(_ plan: AIService.EventPlan, calendarID: String? = nil, notify: Bool = true) async throws -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            throw IntentError.message("Takvim izni kapalı: Ayarlar › BestKeyboard › Takvimler › Tam Erişim.")
        }
        guard try await store.requestFullAccessToEvents() else {
            throw IntentError.message("Takvim izni verilmedi: Ayarlar › BestKeyboard › Takvimler.")
        }
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        AIService.eventCalendars = writable.map(\.title)
        let picked = calendarID.flatMap { id in writable.first { $0.calendarIdentifier == id } }
        guard let cal = picked ?? resolve(plan.calendar, in: writable, store: store) else {
            throw IntentError.message("Yazılabilir bir takvim yok.")
        }
        var saved: [EKEvent] = []
        for d in plan.items {
            let e = EKEvent(eventStore: store)
            e.title = d.title
            e.calendar = cal
            e.isAllDay = d.allDay
            let cal = Calendar.current
            if d.allDay {
                // Gün sınırlarına oturt; uyarı o günün 09:00'u (DST gününde "+9 saat" 09:00 olmayabilir).
                let day = cal.startOfDay(for: d.start)
                e.startDate = day
                e.endDate = max(cal.startOfDay(for: d.end ?? day), day)
                e.addAlarm(EKAlarm(absoluteDate: cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day))
            } else {
                e.startDate = d.start
                e.endDate = d.end.flatMap { $0 > d.start ? $0 : nil } ?? d.start.addingTimeInterval(3600)
                e.addAlarm(EKAlarm(relativeOffset: -30 * 60))
            }
            e.location = d.location
            e.notes = d.notes
            try store.save(e, span: .thisEvent, commit: false)
            saved.append(e)
        }
        try store.commit()
        guard saved.allSatisfy({ $0.eventIdentifier != nil && store.event(withIdentifier: $0.eventIdentifier) != nil }) else {
            throw IntentError.message("Etkinlik kaydedilemedi (\(cal.title)).")
        }
        if notify, let first = plan.items.first {
            let title = saved.count > 1 ? "\(saved.count) etkinlik eklendi · \(cal.title)" : "Takvime eklendi · \(cal.title)"
            let body = plan.items.map { d in
                d.title + " · " + d.start.formatted(date: .abbreviated, time: d.allDay ? .omitted : .shortened)
                    + (d.location.map { " · " + $0 } ?? "")
            }.joined(separator: "\n")
            // Dokununca Takvim o günü açıyor.
            let url = URL(string: "calshow:\(first.start.timeIntervalSinceReferenceDate)")
            await Notifier.shared.post(title: title, body: body, url: url)
        }
        return cal.title
    }
}

/// Kişi kartı (Contacts).
enum ContactMaker {
    @discardableResult
    static func add(_ d: AIService.ContactDraft, notify: Bool = true) async throws -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .denied || status == .restricted {
            throw IntentError.message("Kişiler izni kapalı: Ayarlar › BestKeyboard › Kişiler.")
        }
        guard try await store.requestAccess(for: .contacts) else {
            throw IntentError.message("Kişiler izni verilmedi.")
        }
        let c = CNMutableContact()
        c.givenName = d.givenName
        c.familyName = d.familyName
        c.organizationName = d.organization ?? ""
        c.phoneNumbers = d.phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        c.emailAddresses = d.emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        // Not alanını yazmak ayrı bir Apple izni istiyor (contacts.notes); not
        // yazılmıyor, kartın kendisi oluşuyor.
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        try store.execute(req)
        let name = d.displayName.isEmpty ? (d.phones.first ?? d.emails.first ?? "Kişi") : d.displayName
        if notify {
            await Notifier.shared.post(title: "Kişilere eklendi · \(name)",
                                       body: (d.phones + d.emails).joined(separator: " · "),
                                       url: URL(string: "contacts://"))
        }
        return name
    }
}

/// Başka uygulama açma. Uygulamada UIApplication; paylaşım eklentisinde
/// o yok — eklenti kendi yolunu koyuyor.
@MainActor
enum URLOpener {
    static var open: (URL) async -> Bool = { _ in false }
    static var canOpen: (URL) -> Bool = { _ in false }
}

/// Yapılacaklar planını seçilen uygulamaya yönlendirir.
enum TodoRouter {
    struct Result: Equatable {
        /// "Hatırlatıcılar › Alışveriş", "Things › Alışveriş"…
        let place: String
        /// Eklendiği doğrulandı mı. Things / TickTick'te uygulama yalnız açılıyor;
        /// ekleme onu kullanıcı orada görünce kesinleşiyor (ilk kullanımda izin de soruyor).
        let confirmed: Bool
    }

    /// TickTick zinciri: her görevden sonra `bestkeyboard://ticktick-sonraki?z=<jeton>` ile
    /// dönülüp sıradaki gönderiliyor. Jeton her adımda yeni ve tek kullanımlık:
    /// dışarıdan açılan, eski ya da yinelenen dönüş zinciri ilerletmiyor.
    @MainActor private static var tickTickQueue: [AIService.ReminderDraft] = []
    @MainActor private static var tickTickList: String?
    @MainActor private static var tickTickSent = 0
    @MainActor private static var tickTickToken: String?
    static let tickTickCallback = "bestkeyboard://ticktick-sonraki"
    /// Paylaşım eklentisi koyuyor: planı uygulamaya devredip açar.
    @MainActor static var handOffToApp: ((AIService.ReminderPlan, TodoDestination) async -> Bool)?

    @MainActor
    static func send(_ plan: AIService.ReminderPlan, to dest: TodoDestination) async throws -> Result {
        switch dest {
        case .apple:
            return Result(place: "Hatırlatıcılar › " + (try await ReminderMaker.add(plan)), confirmed: true)
        case .things:
            guard let url = TodoExport.thingsURL(plan), URLOpener.canOpen(url),
                  await URLOpener.open(url) else {
                throw IntentError.message("Things açılamadı. Yüklü mü?")
            }
            return Result(place: "Things" + (plan.list.map { " › " + $0 } ?? ""), confirmed: false)
        case .todoist:
            guard TodoExport.todoistToken != nil else {
                throw IntentError.message("Todoist bağlı değil: Yapay zeka tuşları › Bağlantılar › Todoist token.")
            }
            let where_ = try await TodoExport.addToTodoist(plan)
            await Notifier.shared.post(title: "\(plan.items.count) görev Todoist'e eklendi · \(where_)",
                                       body: plan.items.map(\.title).joined(separator: "\n"),
                                       url: URL(string: "todoist://"))
            return Result(place: "Todoist › " + where_, confirmed: true)
        case .ticktick:
            // Paylaşım eklentisinde zincir yürümüyor (TickTick dönüşü uygulamaya geliyor):
            // plan uygulamaya devrediliyor, zinciri o yürütüyor.
            if let toApp = handOffToApp {
                guard await toApp(plan, .ticktick) else { throw IntentError.message("BestKeyboard açılamadı.") }
                return Result(place: "TickTick (BestKeyboard üzerinden)", confirmed: false)
            }
            // Yeni gönderim yarım kalmış zinciri değiştirir (eski jetonlu dönüşler yok sayılır).
            tickTickQueue = plan.items
            tickTickList = plan.list
            tickTickSent = 0
            tickTickToken = nil
            guard nextTickTick() else { throw IntentError.message("TickTick açılamadı. Yüklü mü?") }
            return Result(place: "TickTick" + (plan.list.map { " › " + $0 } ?? ""), confirmed: false)
        }
    }

    /// TickTick'ten dönüş: başarıysa sıradaki; `hata=1` (x-error / x-cancel) ise zincir durur ve bildirilir.
    @MainActor
    static func tickTickReturned(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = tickTickToken, items.first(where: { $0.name == "z" })?.value == token else { return }
        tickTickToken = nil
        if items.contains(where: { $0.name == "hata" }) {
            tickTickFailed(left: tickTickQueue.count + 1, why: "TickTick iptal etti ya da hata verdi")
            return
        }
        tickTickSent += 1
        nextTickTick()
    }

    private static func tickTickFailed(left: Int, why: String) {
        Task { @MainActor in
            tickTickQueue = []
            tickTickToken = nil
            await Notifier.shared.post(title: "TickTick: \(left) görev eklenemedi",
                                       body: "\(why); \(tickTickSent) görev eklendi.", url: nil)
        }
    }

    /// Kuyruktaki sıradaki görevi TickTick'e gönderir.
    /// - Returns: görev açıldıysa `true`; kuyruk bittiyse ya da açılamadıysa `false`
    ///   (ikisi de kullanıcıya ayrı bildiriliyor).
    @MainActor @discardableResult
    static func nextTickTick() -> Bool {
        guard !tickTickQueue.isEmpty else {
            if tickTickSent > 0 {
                let n = tickTickSent
                Task { await Notifier.shared.post(title: "\(n) görev TickTick'e eklendi", body: "", url: URL(string: "ticktick://")) }
            }
            return false
        }
        let d = tickTickQueue.removeFirst()
        let token = UUID().uuidString
        guard let url = TodoExport.tickTickURL(d, list: tickTickList, callback: tickTickCallback + "?z=" + token),
              URLOpener.canOpen(url) else {
            // İlk görevde açılamadıysa `send` hata fırlatıyor; ayrıca bildirim yok.
            if tickTickSent == 0 { tickTickQueue = []; return false }
            tickTickFailed(left: tickTickQueue.count + 1, why: "TickTick açılamadı")
            return false
        }
        tickTickToken = token
        Task { @MainActor in
            if !(await URLOpener.open(url)) { tickTickFailed(left: tickTickQueue.count + 1, why: "TickTick açılamadı") }
        }
        return true
    }
}

#if DEBUG
/// `-handoffSelfTest`: klavyenin yaptığı gibi planı App Group'a koyup kimlikli adresi açar.
enum HandoffSelfTest {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-handoffSelfTest") else { return }
        let start = Date().addingTimeInterval(2 * 86_400)
        let plan = AIService.EventPlan(calendar: nil, items: [
            .init(title: "Aktarım testi", start: start, end: start.addingTimeInterval(3600), allDay: false, location: nil, notes: nil)])
        guard let json = try? JSONEncoder().encode(plan), let id = Handoff.put(json),
              let url = URL(string: "bestkeyboard://etkinlik?id=\(id)") else { return }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); _ = await URLOpener.open(url) }
    }
}

/// `-makerSelfTest <etiket>`: örnek etkinlik + kişi ekler; başlık ve soyadında
/// etiket var — UI testi yalnız bu çalıştırmanın kayıtlarını doğrulayıp siliyor.
enum MakerSelfTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-makerSelfTest") else { return }
        let tag = i + 1 < args.count ? args[i + 1] : "x"
        Task { @MainActor in
            let cal = Calendar.current
            let sat = cal.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 7),
                                   matchingPolicy: .nextTime)!
            do {
                try await EventMaker.add(AIService.EventPlan(calendar: nil, items: [
                    .init(title: "Annemi otogardan al \(tag)", start: sat, end: sat.addingTimeInterval(3600),
                          allDay: false, location: "Kadıköy otogarı", notes: nil)]), notify: false)
                try await ContactMaker.add(AIService.ContactDraft(
                    givenName: "Ahmet", familyName: "Deneme\(tag)", phones: ["0532 000 00 00"], emails: ["ahmet@example.com"],
                    organization: nil, note: nil), notify: false)
                print("MAKER-SELFTEST-DONE")
            } catch {
                print("MAKER-SELFTEST-FAILED", error)
            }
        }
    }
}
#endif
