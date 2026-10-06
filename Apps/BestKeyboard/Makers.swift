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
    static func calendarChoices() -> [(title: String, color: Color)] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKEventStore().calendars(for: .event).filter(\.allowsContentModifications)
            .map { ($0.title, Color(cgColor: $0.cgColor)) }
    }

    static var defaultCalendarName: String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        return EKEventStore().defaultCalendarForNewEvents?.title
    }

    /// - Returns: eklendiği takvimin adı.
    @discardableResult
    static func add(_ plan: AIService.EventPlan, notify: Bool = true) async throws -> String {
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
        let wanted = plan.calendar.flatMap { name in
            writable.first { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        guard let cal = wanted ?? store.defaultCalendarForNewEvents ?? writable.first else {
            throw IntentError.message("Yazılabilir bir takvim yok.")
        }
        var saved: [EKEvent] = []
        for d in plan.items {
            let e = EKEvent(eventStore: store)
            e.title = d.title
            e.calendar = cal
            e.isAllDay = d.allDay
            e.startDate = d.start
            e.endDate = d.end ?? d.start.addingTimeInterval(3600)
            e.location = d.location
            e.notes = d.notes
            // Saatli etkinlikte 30 dk önce uyarı; tüm gün etkinliğinde sabah.
            e.addAlarm(EKAlarm(relativeOffset: d.allDay ? 9 * 3600 : -30 * 60))
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
    /// TickTick zinciri: her görevden sonra `bestkeyboard://ticktick-sonraki` ile dönülüp sıradaki gönderiliyor.
    @MainActor static var tickTickQueue: [AIService.ReminderDraft] = []
    @MainActor static var tickTickList: String?
    static let tickTickCallback = "bestkeyboard://ticktick-sonraki"

    /// - Returns: kullanıcıya gösterilecek "nereye" metni.
    @MainActor
    static func send(_ plan: AIService.ReminderPlan, to dest: TodoDestination) async throws -> String {
        switch dest {
        case .apple:
            return "Hatırlatıcılar › " + (try await ReminderMaker.add(plan))
        case .things:
            guard let url = TodoExport.thingsURL(plan), UIApplication.shared.canOpenURL(url) else {
                throw IntentError.message("Things açılamadı. Yüklü mü?")
            }
            await UIApplication.shared.open(url)
            return "Things" + (plan.list.map { " › " + $0 } ?? "")
        case .todoist:
            guard TodoExport.todoistToken != nil else {
                throw IntentError.message("Todoist bağlı değil: Yapay zeka tuşları › Bağlantılar › Todoist token.")
            }
            let where_ = try await TodoExport.addToTodoist(plan)
            await Notifier.shared.post(title: "\(plan.items.count) görev Todoist'e eklendi · \(where_)",
                                       body: plan.items.map(\.title).joined(separator: "\n"),
                                       url: URL(string: "todoist://"))
            return "Todoist › " + where_
        case .ticktick:
            tickTickQueue = plan.items
            tickTickList = plan.list
            guard nextTickTick() else { throw IntentError.message("TickTick açılamadı. Yüklü mü?") }
            return "TickTick" + (plan.list.map { " › " + $0 } ?? "")
        }
    }

    /// Kuyruktaki sıradaki görevi TickTick'e gönderir; kuyruk bittiyse `false`.
    @MainActor @discardableResult
    static func nextTickTick() -> Bool {
        guard !tickTickQueue.isEmpty else { return false }
        let d = tickTickQueue.removeFirst()
        guard let url = TodoExport.tickTickURL(d, list: tickTickList, callback: tickTickCallback),
              UIApplication.shared.canOpenURL(url) else { tickTickQueue = []; return false }
        UIApplication.shared.open(url)
        return true
    }
}

#if DEBUG
/// `-makerSelfTest`: örnek etkinlik + kişi ekler (UI testi Takvim/Kişiler'den doğruluyor).
enum MakerSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-makerSelfTest") else { return }
        Task { @MainActor in
            let cal = Calendar.current
            let sat = cal.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 7),
                                   matchingPolicy: .nextTime)!
            _ = try? await EventMaker.add(AIService.EventPlan(calendar: nil, items: [
                .init(title: "Annemi otogardan al", start: sat, end: sat.addingTimeInterval(3600),
                      allDay: false, location: "Kadıköy otogarı", notes: nil)]), notify: false)
            _ = try? await ContactMaker.add(AIService.ContactDraft(
                givenName: "Ahmet", familyName: "Deneme", phones: ["0532 000 00 00"], emails: ["ahmet@example.com"],
                organization: nil, note: nil), notify: false)
            print("MAKER-SELFTEST-DONE")
        }
    }
}
#endif
