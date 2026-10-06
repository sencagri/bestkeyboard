import Contacts
import EventKit
import SwiftUI
import UIKit

// Klavyeden gelen planları Apple uygulamalarına (Takvim, Kişiler) ve
// yapılacaklar uygulamalarına (Things, Todoist, TickTick) yazan katman.
// İzinleri uygulama istiyor; klavye eklentisine iOS bu izinleri vermiyor.

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

    @MainActor
    static func send(_ plan: AIService.ReminderPlan, to dest: TodoDestination) async throws -> Result {
        switch dest {
        case .apple:
            return Result(place: "Hatırlatıcılar › " + (try await ReminderMaker.add(plan)), confirmed: true)
        case .things:
            guard let url = TodoExport.thingsURL(plan), UIApplication.shared.canOpenURL(url),
                  await UIApplication.shared.open(url) else {
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
              UIApplication.shared.canOpenURL(url) else {
            // İlk görevde açılamadıysa `send` hata fırlatıyor; ayrıca bildirim yok.
            if tickTickSent == 0 { tickTickQueue = []; return false }
            tickTickFailed(left: tickTickQueue.count + 1, why: "TickTick açılamadı")
            return false
        }
        tickTickToken = token
        UIApplication.shared.open(url) { ok in
            if !ok { Task { @MainActor in tickTickFailed(left: tickTickQueue.count + 1, why: "TickTick açılamadı") } }
        }
        return true
    }
}

#if DEBUG
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
