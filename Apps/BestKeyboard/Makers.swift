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

/// Kullanıcıya söylenen ekleme metinleri — bildirim, Siri cevabı ve sayfalar aynı cümleyi kullanıyor.
enum MakerText {
    static func reminderLine(_ d: AIService.ReminderDraft) -> String {
        d.title + (AIService.trWhen(d.due).map { " · " + $0 } ?? "")
    }
    static func eventLine(_ d: AIService.EventDraft) -> String {
        d.title + " · " + d.trWhen + (d.location.map { " · " + $0 } ?? "")
    }
    /// "3 madde eklendi · Alışveriş" / "Hatırlatıcı eklendi · Alışveriş".
    static func remindersTitle(count: Int, place: String) -> String {
        count > 1 ? "\(count) madde eklendi · \(place)" : "Hatırlatıcı eklendi · \(place)"
    }
    static func eventsTitle(count: Int, calendar: String) -> String {
        count > 1 ? "\(count) etkinlik eklendi · \(calendar)" : "Takvime eklendi · \(calendar)"
    }
    static func contactTitle(_ name: String) -> String { "Kişilere eklendi · \(name)" }
    /// Maddeler alt alta — bildirim gövdesi, kestirme çıktısı ve özet aynı yazım.
    static func reminderLines(_ items: [AIService.ReminderDraft]) -> String { items.map(reminderLine).joined(separator: "\n") }
    static func eventLines(_ items: [AIService.EventDraft]) -> String { items.map(eventLine).joined(separator: "\n") }

    static func reminders(_ p: AIService.ReminderPlan, place: String) -> String {
        remindersTitle(count: p.items.count, place: place) + "\n" + reminderLines(p.items)
    }
    static func events(_ p: AIService.EventPlan, calendar: String) -> String {
        eventsTitle(count: p.items.count, calendar: calendar) + "\n" + eventLines(p.items)
    }
}

/// Eklendikten sonra "…’de aç" adresleri.
enum AppLinks {
    /// Takvim o günü açar.
    static func calendar(at d: Date) -> URL? { URL(string: "calshow:\(d.timeIntervalSinceReferenceDate)") }
    /// Planın ilk etkinliğinin günü.
    static func calendar(for plan: AIService.EventPlan) -> URL? { calendar(at: plan.items.first?.start ?? Date()) }
    static let contacts = URL(string: "contacts://")
    /// Hatırlatıcılar; tek madde eklendiyse doğrudan ona gider.
    static func reminders(_ id: String? = nil) -> URL? {
        id.flatMap { URL(string: "x-apple-reminderkit://REMCDReminder/\($0)") } ?? TodoDestination.apple.openURL
    }
}

/// İzin: kapalıysa ne yapılacağını söyleyen hata, belirsizse sor.
enum Permission {
    /// "Ayarlar › BestKeyboard › Takvimler" — iznin açıldığı yer.
    static func settingsPath(_ item: String? = nil) -> String {
        "Ayarlar › BestKeyboard" + (item.map { " › " + $0 } ?? "")
    }

    static func require(denied: Bool, settingsHint: String, request: () async throws -> Bool) async throws {
        if denied { throw IntentError.message("\(settingsHint) izni kapalı: \(settingsPath(settingsHint)).") }
        guard try await request() else { throw IntentError.message("\(settingsHint) izni verilmedi: \(settingsPath(settingsHint)).") }
    }
    static func isDenied(_ s: EKAuthorizationStatus) -> Bool { s == .denied || s == .restricted }
    static func isDenied(_ s: CNAuthorizationStatus) -> Bool { s == .denied || s == .restricted }

    /// Takvim / Hatırlatıcılar tam erişimi: kapalıysa yol tarifi, belirsizse sor.
    static func require(_ type: EKEntityType, in store: EKEventStore) async throws {
        let isEvent = type == .event
        try await require(denied: isDenied(EKEventStore.authorizationStatus(for: type)),
                          settingsHint: isEvent ? "Takvimler" : "Hatırlatıcılar") {
            isEvent ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        }
    }

    static func requireContacts(in store: CNContactStore) async throws {
        try await require(denied: isDenied(CNContactStore.authorizationStatus(for: .contacts)),
                          settingsHint: "Kişiler") { try await store.requestAccess(for: .contacts) }
    }
}

extension EKEventStore {
    /// Yazılabilir takvimler / listeler.
    func writable(_ type: EKEntityType) -> [EKCalendar] { calendars(for: type).filter(\.allowsContentModifications) }

    /// Tam erişim varsa yeni bir depo; yoksa `nil` (izin istenmeden okunacaksa).
    static func ifAuthorized(_ type: EKEntityType) -> EKEventStore? {
        authorizationStatus(for: type) == .fullAccess ? EKEventStore() : nil
    }
}

/// Hatırlatıcılar'a yazma — izni **uygulama** istiyor; klavye eklentisine
/// iOS bu izni vermiyor.
enum ReminderMaker {
    /// İzin varsa Hatırlatıcılar listelerinin adlarını ortak depoya yazar —
    /// klavye bunları modele "uygun listeyi seç" diye veriyor. İzin yoksa `nil`.
    @discardableResult
    static func refreshListNames() async -> [String]? {
        guard let store = EKEventStore.ifAuthorized(.reminder) else { return nil }
        let names = store.writable(.reminder).map(\.title)
        AIService.reminderLists = names
        return names
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

    /// Maddelerin hepsini **ayrı** hatırlatıcı olarak ekler ve bildirimle onaylar
    /// (dokununca Hatırlatıcılar açılıyor).
    /// - Returns: eklendiği listenin adı (kullanıcı nerede bulacağını bilsin).
    @discardableResult
    static func add(_ plan: AIService.ReminderPlan, notify: Bool = true) async throws -> String {
        let store = EKEventStore()
        try await Permission.require(.reminder, in: store)
        let writable = store.writable(.reminder)
        AIService.reminderLists = writable.map(\.title)
        // İstenen liste (ad eşleşmesi) → yoksa o adla **yeni liste** → varsayılan → yazılabilir ilk liste.
        let wanted = try plan.list.flatMap { name in
            try writable.first { $0.title.trEquals(name) }
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
            await ResultNotice.post(title: MakerText.remindersTitle(count: saved.count, place: list.title),
                                       body: MakerText.reminderLines(plan.items),
                                       url: AppLinks.reminders(saved.count == 1 ? saved[0].calendarItemIdentifier : nil))
        }
        return list.title
    }
}

/// Resimdeki yazı (cihazda, Vision) — sohbet ekran görüntüsü, afiş, kartvizit.
enum TextRecognizer {
    /// Yazı yoksa kullanıcıya söylenecek hatayla. `what`: "Resimde", "Son ekran görüntüsünde".
    static func requireText(in img: UIImage, what: String) async throws -> String {
        guard let t = await text(in: img), !t.trimmed.isEmpty else {
            throw IntentError.message("\(what) okunabilen yazı yok.")
        }
        return t
    }

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
    /// Eklenen etkinliğin uyarısı — kuralı ve sayfadaki yazısı burada.
    enum Alarm {
        static let allDayHour = 9
        static let minutesBefore: Double = 30
        static func text(allDay: Bool) -> String {
            allDay ? String(format: "O gün %02d:00", allDayHour) : "\(Int(minutesBefore)) dk önce"
        }
    }

    /// İzin varsa takvim adlarını ortak depoya yazar (klavye "uygun takvim" için).
    @discardableResult
    static func refreshCalendarNames() -> [String]? {
        guard let store = EKEventStore.ifAuthorized(.event) else { return nil }
        let names = store.writable(.event).map(\.title)
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
        guard let store = EKEventStore.ifAuthorized(.event) else { return [] }
        return store.writable(.event)
            .map { Choice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(cgColor: $0.cgColor)) }
    }

    /// Modelin önerdiği ada (yoksa varsayılana) karşılık gelen takvimin kimliği.
    static func calendarID(named name: String?) -> String? {
        guard let store = EKEventStore.ifAuthorized(.event) else { return nil }
        return resolve(name, in: store.writable(.event), store: store)?
            .calendarIdentifier
    }

    /// Ad birden çok takvime uyuyorsa varsayılan takvimin hesabındaki seçiliyor.
    private static func resolve(_ name: String?, in writable: [EKCalendar], store: EKEventStore) -> EKCalendar? {
        let def = store.defaultCalendarForNewEvents
        guard let name else { return def ?? writable.first }
        let matches = writable.filter { $0.title.trEquals(name) }
        return matches.first { $0.source.sourceIdentifier == def?.source.sourceIdentifier } ?? matches.first ?? def ?? writable.first
    }

    /// - Returns: eklendiği takvimin adı.
    @discardableResult
    static func add(_ plan: AIService.EventPlan, calendarID: String? = nil, notify: Bool = true) async throws -> String {
        let store = EKEventStore()
        try await Permission.require(.event, in: store)
        let writable = store.writable(.event)
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
                e.addAlarm(EKAlarm(absoluteDate: cal.date(bySettingHour: Alarm.allDayHour, minute: 0, second: 0, of: day) ?? day))
            } else {
                e.startDate = d.start
                e.endDate = d.endOrDefault
                e.addAlarm(EKAlarm(relativeOffset: -Alarm.minutesBefore * 60))
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
            // Dokununca Takvim o günü açıyor.
            await ResultNotice.post(title: MakerText.eventsTitle(count: saved.count, calendar: cal.title),
                                       body: MakerText.eventLines(plan.items),
                                       url: AppLinks.calendar(at: first.start))
        }
        return cal.title
    }
}

/// Kişi kartı (Contacts).
enum ContactMaker {
    @discardableResult
    static func add(_ d: AIService.ContactDraft, notify: Bool = true) async throws -> String {
        let store = CNContactStore()
        try await Permission.requireContacts(in: store)
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
            await ResultNotice.post(title: MakerText.contactTitle(name),
                                       body: (d.phones + d.emails).joined(separator: " · "),
                                       url: AppLinks.contacts)
        }
        return name
    }
}

/// Başka uygulama açma. Uygulamada UIApplication; paylaşım eklentisinde
/// o yok — eklenti kendi yolunu koyuyor.
///
/// Açma **ana iş parçacığında** (tipin kendisi `@MainActor`): UIKit başka iş
/// parçacığından `open` çağrılınca uygulamayı durduruyor — bildirim
/// temsilcisinden çağrılınca böyle çökmüştü. Her hedef kendi yolunu bir kez
/// kuruyor (uygulama `UIApplication`, paylaşım eklentisi yanıtlayıcı zinciri).
@MainActor
enum URLOpener {
    static var open: (URL) async -> Bool = { _ in false }
    static var canOpen: (URL) -> Bool = { _ in false }

    /// Sonucu beklemeden açar (düğme eylemleri).
    static func launch(_ url: URL?) {
        guard let url else { return }
        Task { _ = await open(url) }
    }
}

/// Sonuç bildirimi ("3 madde eklendi"). Uygulama `Notifier`'ı bağlıyor;
/// paylaşım eklentisinde bağlanmıyor — sonuç kartın kendisinde gösteriliyor.
/// `URLOpener` ile aynı desen: önce eklentide aynı adlı boş bir `Notifier`
/// sınıfı vardı ve hangi hedefte hangisinin derlendiği dosyadan okunmuyordu.
@MainActor
enum ResultNotice {
    static var poster: ((_ title: String, _ body: String, _ url: URL?) async -> Void)?

    static func post(title: String, body: String, url: URL?) async {
        await poster?(title, body, url)
    }
}

extension TodoDestination {
    /// Uygulama açıkken yüklü yapılacaklar uygulamalarını yazar (klavye soramıyor).
    @MainActor @discardableResult
    static func refreshInstalled() -> Set<TodoDestination> {
        let set = Set(allCases.filter { d in
            d.scheme.flatMap { URL(string: "\($0)://") }.map(URLOpener.canOpen) ?? false
        })
        installed = set
        return set
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

    /// Paylaşım eklentisi koyuyor: planı uygulamaya devredip açar.
    @MainActor static var handOffToApp: ((AIService.ReminderPlan, TodoDestination) async -> Bool)?

    @MainActor
    static func send(_ plan: AIService.ReminderPlan, to dest: TodoDestination, notify: Bool = true) async throws -> Result {
        switch dest {
        case .apple:
            return Result(place: dest.place(try await ReminderMaker.add(plan, notify: notify)), confirmed: true)
        case .things:
            guard let url = TodoExport.thingsURL(plan), URLOpener.canOpen(url),
                  await URLOpener.open(url) else {
                throw IntentError.message(CommonText.notInstalled(TodoDestination.things.title))
            }
            return Result(place: dest.place(plan.list), confirmed: false)
        case .todoist:
            guard TodoExport.todoistToken != nil else {
                throw IntentError.message(TodoDestination.todoistNotConnected)
            }
            let where_ = try await TodoExport.addToTodoist(plan)
            if notify {
                await ResultNotice.post(title: MakerText.remindersTitle(count: plan.items.count, place: dest.place(where_)),
                                           body: MakerText.reminderLines(plan.items),
                                           url: TodoDestination.todoist.openURL)
            }
            return Result(place: dest.place(where_), confirmed: true)
        case .ticktick:
            // Paylaşım eklentisinde zincir yürümüyor (TickTick dönüşü uygulamaya geliyor):
            // plan uygulamaya devrediliyor, zinciri o yürütüyor.
            if let toApp = handOffToApp {
                guard await toApp(plan, .ticktick) else { throw IntentError.message("BestKeyboard açılamadı.") }
                return Result(place: dest.title + " (BestKeyboard üzerinden)", confirmed: false)
            }
            guard TickTickChain.shared.start(plan) else { throw IntentError.message(CommonText.notInstalled(TodoDestination.ticktick.title)) }
            return Result(place: dest.place(plan.list), confirmed: false)
        }
    }

    /// TickTick'ten dönüş (`bestkeyboard://ticktick-sonraki`).
    @MainActor
    static func tickTickReturned(_ url: URL) { TickTickChain.shared.returned(url) }
}

/// TickTick zinciri: her görevden sonra `bestkeyboard://ticktick-sonraki?z=<jeton>` ile
/// dönülüp sıradaki gönderiliyor. Jeton her adımda yeni ve tek kullanımlık:
/// dışarıdan açılan, eski ya da yinelenen dönüş zinciri ilerletmiyor.
///
/// Durum tek nesnede: önce `TodoRouter` üzerinde dört ayrı statik alandı ve
/// sıfırlama her yerde elle, eksik yapılabiliyordu.
@MainActor
final class TickTickChain {
    static let shared = TickTickChain()

    private var queue: [AIService.ReminderDraft] = []
    private var list: String?
    private var sent = 0
    private var token: String?

    /// Yeni gönderim yarım kalmış zinciri değiştirir (eski jetonlu dönüşler yok sayılır).
    /// - Returns: ilk görev açıldıysa `true`.
    func start(_ plan: AIService.ReminderPlan) -> Bool {
        queue = plan.items
        list = plan.list
        sent = 0
        token = nil
        return next()
    }

    /// Başarıysa sıradaki; `hata=1` (x-error / x-cancel) ise zincir durur ve bildirilir.
    func returned(_ url: URL) {
        guard let token, DeepLink.value(DeepLink.Param.token, in: url) == token else { return }
        self.token = nil
        if DeepLink.has(DeepLink.Param.error, in: url) {
            fail(why: "TickTick iptal etti ya da hata verdi")
            return
        }
        sent += 1
        next()
    }

    /// Bu adımdaki görev dahil kalanlar eklenemedi.
    private func fail(why: String) {
        let left = queue.count + 1, added = sent
        queue = []
        token = nil
        Task {
            await ResultNotice.post(title: "TickTick: \(left) görev eklenemedi",
                                    body: "\(why); \(added) görev eklendi.", url: nil)
        }
    }

    /// Kuyruktaki sıradaki görevi TickTick'e gönderir.
    /// - Returns: görev açıldıysa `true`; kuyruk bittiyse ya da açılamadıysa `false`
    ///   (ikisi de kullanıcıya ayrı bildiriliyor).
    @discardableResult
    private func next() -> Bool {
        guard !queue.isEmpty else {
            if sent > 0 {
                let n = sent
                Task { await ResultNotice.post(title: "\(n) görev TickTick'e eklendi", body: "", url: TodoDestination.ticktick.openURL) }
            }
            return false
        }
        let d = queue.removeFirst()
        let token = UUID().uuidString
        guard let url = TodoExport.tickTickURL(d, list: list, token: token),
              URLOpener.canOpen(url) else {
            // İlk görevde açılamadıysa `send` hata fırlatıyor; ayrıca bildirim yok.
            if sent == 0 { queue = []; return false }
            fail(why: "TickTick açılamadı")
            return false
        }
        self.token = token
        Task {
            if !(await URLOpener.open(url)) { self.fail(why: "TickTick açılamadı") }
        }
        return true
    }
}

/// Arka plandaki ekleme akışı — Kestirmeler, Siri ve Kontrol Merkezi **aynı**
/// yoldan geçiyor: istem (kullanıcının tuşu) → çıkarım + günlük → ekleme → sonuç.
/// (Klavye ve paylaşım eklentisi önizleme gösterdiği için yalnız çıkarımı paylaşıyor.)
enum StructuredFlow {
    /// Akışın sonucu: veri (Kestirme çıktısı) ile söylenecek metin ayrı.
    struct Outcome {
        /// Kestirmelere dönen değer: eklenen maddeler / etkinlikler satır satır, kişide ad.
        let value: String
        /// Siri cevabı ve özet: "3 madde eklendi · Alışveriş" + satırlar (+ varsa not).
        let summary: String
        /// Kullanıcının bilmesi gereken yönlendirme notu (ör. Things arka planda açılamadı).
        let note: String?
    }

    @MainActor
    /// - Parameter action: günlükteki ad; verilmezse türün adı ("Hatırlatıcı").
    static func run(_ kind: AIAction.Kind, text: String, origin: AILog.Origin,
                    action: String? = nil, source: String, notify: Bool) async throws -> Outcome {
        switch kind {
        case .event: EventMaker.refreshCalendarNames()
        case .reminder: await ReminderMaker.refreshListNames()
        default: break
        }
        let r = try await AIService.extract(kind, from: text,
                                            template: AIAction.template(kind, in: AIActionStore.loadShared()),
                                            origin: origin, action: action ?? kind.title, source: source)
        do {
            return try await add(r.value, notify: notify)
        } catch {
            // Çıkarım başarılıydı ama ekleme olmadı: aynı günlük kaydına işlensin.
            AILog.update(r.id, status: .error, detail: "Eklenemedi: " + error.localizedDescription)
            throw error
        }
    }

    @MainActor
    static func add(_ e: Extraction, notify: Bool) async throws -> Outcome {
        switch e {
        case let .events(p):
            let cal = try await EventMaker.add(p, notify: notify)
            return Outcome(value: MakerText.eventLines(p.items),
                           summary: MakerText.events(p, calendar: cal), note: nil)
        case let .contact(d):
            let name = try await ContactMaker.add(d, notify: notify)
            return Outcome(value: name, summary: MakerText.contactTitle(name), note: nil)
        case let .reminders(p):
            let (dest, note) = try backgroundDestination()
            let r: TodoRouter.Result
            do { r = try await TodoRouter.send(p, to: dest, notify: notify) }
            catch let partial as TodoExport.TodoistPartial {
                // Burada kalanları saklayıp devam edecek bir sayfa yok: tekrar çalıştırmak
                // eklenenleri çoğaltır. Doğrusunu söyle.
                let left = partial.remaining(p.items).map(\.title).joined(separator: ", ")
                throw IntentError.message(partial.localizedDescription
                    + (left.isEmpty ? "" : " Eklenemeyenler: \(left).") + " Tekrar çalıştırma (eklenenler çoğalır), kalanları elle ekle.")
            }
            let summary = MakerText.reminders(p, place: r.place) + (note.map { "\n" + $0 } ?? "")
            return Outcome(value: MakerText.reminderLines(p.items), summary: summary, note: note)
        }
    }

    /// Arka planda gidilebilecek yapılacaklar hedefi — politika tek yerde:
    /// Things / TickTick adres açarak çalışıyor, arka planda açılamıyor → Hatırlatıcılar
    /// (ve söyleniyor); Todoist token'sız → hata (sessizce başka yere yazılmıyor).
    static func backgroundDestination() throws -> (TodoDestination, note: String?) {
        let dest = TodoDestination.current
        switch dest {
        case .apple: return (.apple, nil)
        case .todoist:
            guard dest.isAvailable else {
                throw IntentError.message(TodoDestination.todoistNotConnected)
            }
            return (.todoist, nil)
        case .things, .ticktick:
            return (.apple, "\(dest.title) arka planda açılamıyor; \(TodoDestination.apple.title)'a eklendi.")
        }
    }
}
