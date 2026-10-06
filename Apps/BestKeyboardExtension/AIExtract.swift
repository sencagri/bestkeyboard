import Foundation

// Mesajdan Takvim etkinliği ve kişi kartı çıkarma — hatırlatıcıdaki yolun
// (AIService.reminders) eşi. Yorum tamamen modelde (her dil); istemler
// tuşta düzenlenebilir şablon, yer tutucular kodla dolduruluyor.
extension AIService {

    // MARK: - Takvim etkinliği

    struct EventDraft: Sendable, Codable, Hashable {
        var title: String
        var start: Date
        var end: Date?
        var allDay: Bool
        var location: String?
        var notes: String?
    }

    struct EventPlan: Sendable, Codable, Hashable {
        /// Takvim adı (`nil` = varsayılan takvim).
        var calendar: String?
        var items: [EventDraft]
    }

    /// Kullanıcının takvimleri — klavye EventKit'e erişemiyor; uygulama izinle yazıyor.
    static var eventCalendars: [String] {
        get { UserDefaults(suiteName: KeyboardSettingsStore.appGroup)?.stringArray(forKey: "kb.event.calendars") ?? [] }
        set { UserDefaults(suiteName: KeyboardSettingsStore.appGroup)?.set(newValue, forKey: "kb.event.calendars") }
    }

    /// Yer tutucular: `{şimdi}`, `{takvim}`, `{takvimler}`, `{metin}`.
    static let eventTemplateDefault = """
    Şu mesajdaki randevu, buluşma ya da etkinlikleri Apple Takvim etkinliklerine çevir.
    Şu an: {şimdi}.
    Önümüzdeki günler (tarih ve haftanın günü): {takvim}.
    Mesaj hangi dilde olursa olsun gün adlarını ve göreli ifadeleri bu takvimden tarihe çevir; tahmin etme, takvime bak.
    Her etkinlik ayrı madde. title: kısa, mesajın dilinde. start: "YYYY-MM-DDTHH:mm". end: biliniyorsa aynı biçimde, yoksa "".
    Saat yoksa: sabah 09:00, öğle 12:00, öğleden sonra 15:00, akşam 19:00, gece 21:00. Gün var ama saat hiç
    belirtilmemişse allDay true. location: yer geçiyorsa (ör. "Kadıköy otogarı"), yoksa "". notes: gerekirse kısa not, yoksa "".
    Kullanıcının takvimleri: {takvimler}. calendar: uygun bir takvim varsa adını AYNEN yaz, yoksa "".

    Mesaj:
    {metin}
    """

    static func eventPrompt(text: String, calendars: [String] = eventCalendars, template: String = "",
                            now: Date = Date()) -> String {
        let tpl = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? eventTemplateDefault : template
        let p = fill(tpl, now: now)
            .replacingOccurrences(of: "{takvimler}", with: calendars.isEmpty ? "bilinmiyor" : calendars.map { "\"\($0)\"" }.joined(separator: ", "))
        return withMessage(p, text)
    }

    static func events(from text: String, template: String = "", now: Date = Date()) async throws -> EventPlan {
        let item: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "start": ["type": "string"], "end": ["type": "string"],
                           "allDay": ["type": "boolean"], "location": ["type": "string"], "notes": ["type": "string"]],
            "required": ["title", "start", "end", "allDay", "location", "notes"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["calendar": ["type": "string"], "items": ["type": "array", "items": item]],
            "required": ["calendar", "items"],
            "additionalProperties": false,
        ]
        let obj = try jsonObject(try await complete(eventPrompt(text: text, template: template, now: now), schema: schema))
        let items: [EventDraft] = ((obj["items"] as? [[String: Any]]) ?? []).prefix(20).compactMap { o in
            guard let t = nonEmpty(o["title"]), let start = parseDate(o["start"]) else { return nil }
            let allDay = (o["allDay"] as? Bool) ?? false
            // Bitiş yoksa 1 saat; tüm gün etkinliğinde gün sonu EventKit'e bırakılıyor.
            let end = parseDate(o["end"]).flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
            return EventDraft(title: t, start: start, end: end, allDay: allDay,
                              location: nonEmpty(o["location"]), notes: nonEmpty(o["notes"]))
        }
        guard !items.isEmpty else { throw Failure.empty }
        let cal = nonEmpty(obj["calendar"]).flatMap { name in
            eventCalendars.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        return EventPlan(calendar: cal, items: items)
    }

    // MARK: - Kişi

    struct ContactDraft: Sendable, Codable, Hashable {
        var givenName: String
        var familyName: String
        var phones: [String]
        var emails: [String]
        var organization: String?
        var note: String?

        var displayName: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// Yer tutucu: `{metin}`.
    static let contactTemplateDefault = """
    Şu mesajdaki kişi bilgilerini Apple Kişiler kartına çevir. Mesaj hangi dilde olursa olsun.
    givenName / familyName: ad ve soyad (soyad yoksa ""). phones: telefon numaraları, mesajdaki gibi.
    emails: e-posta adresleri. organization: şirket geçiyorsa, yoksa "". note: kart için kısa not (ör. "Tolga'nın kuzeni"), yoksa "".
    Mesajda olmayan bilgi uydurma.

    Mesaj:
    {metin}
    """

    static func contactPrompt(text: String, template: String = "") -> String {
        let tpl = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? contactTemplateDefault : template
        return withMessage(tpl, text)
    }

    static func contact(from text: String, template: String = "") async throws -> ContactDraft {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["givenName": ["type": "string"], "familyName": ["type": "string"],
                           "phones": ["type": "array", "items": ["type": "string"]],
                           "emails": ["type": "array", "items": ["type": "string"]],
                           "organization": ["type": "string"], "note": ["type": "string"]],
            "required": ["givenName", "familyName", "phones", "emails", "organization", "note"],
            "additionalProperties": false,
        ]
        let o = try jsonObject(try await complete(contactPrompt(text: text, template: template), schema: schema))
        let d = ContactDraft(givenName: nonEmpty(o["givenName"]) ?? "", familyName: nonEmpty(o["familyName"]) ?? "",
                             phones: (o["phones"] as? [String] ?? []).filter { !$0.isEmpty },
                             emails: (o["emails"] as? [String] ?? []).filter { !$0.isEmpty },
                             organization: nonEmpty(o["organization"]), note: nonEmpty(o["note"]))
        guard !d.displayName.isEmpty || !d.phones.isEmpty || !d.emails.isEmpty else { throw Failure.empty }
        return d
    }

    // MARK: - Ortak yardımcılar

    /// `{şimdi}` ve `{takvim}`.
    static func fill(_ tpl: String, now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return tpl
            .replacingOccurrences(of: "{şimdi}", with: "\(f.string(from: now)) (saat dilimi \(TimeZone.current.identifier))")
            .replacingOccurrences(of: "{takvim}", with: calendarLines(now: now))
    }

    /// `{metin}` yoksa mesaj sona ekleniyor.
    static func withMessage(_ p: String, _ text: String) -> String {
        p.contains("{metin}") ? p.replacingOccurrences(of: "{metin}", with: text) : p + "\n\nMesaj:\n" + text
    }

    /// Şema desteklenmeyip düz metin döndüyse de ilk {…} bloğu.
    static func jsonObject(_ raw: String) throws -> [String: Any] {
        let s = String(raw.drop { $0 != "{" }.reversed().drop { $0 != "}" }.reversed())
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw Failure.empty
        }
        return o
    }

    static func nonEmpty(_ v: Any?) -> String? {
        let s = ((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func parseDate(_ v: Any?) -> Date? {
        guard let s = nonEmpty(v) else { return nil }
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = .current
        p.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let d = p.date(from: String(s.prefix(16))) { return d }
        p.dateFormat = "yyyy-MM-dd"
        return p.date(from: String(s.prefix(10)))
    }
}

// MARK: - Yapılacaklar uygulamaları (Things · Todoist · TickTick)

/// Hatırlatıcı planının gidebileceği yerler. Apple Hatırlatıcılar varsayılan.
enum TodoDestination: String, CaseIterable, Codable, Sendable {
    case apple, things, todoist, ticktick
    var title: String {
        switch self {
        case .apple: return "Hatırlatıcılar"
        case .things: return "Things"
        case .todoist: return "Todoist"
        case .ticktick: return "TickTick"
        }
    }
    /// Uygulama kurulu mu diye bakılacak adres şeması.
    var scheme: String? {
        switch self {
        case .apple: return nil
        case .things: return "things"
        case .todoist: return "todoist"
        case .ticktick: return "ticktick"
        }
    }
    /// Kartın ana düğmesi (tasarım 30).
    var addTitle: String {
        switch self {
        case .apple: return "Hatırlatıcılar’a ekle"
        case .things: return "Things’e gönder"
        case .todoist: return "Todoist’e ekle"
        case .ticktick: return "TickTick’e gönder"
        }
    }

    private static var store: UserDefaults? { UserDefaults(suiteName: KeyboardSettingsStore.appGroup) }

    /// Son seçilen hedef — kartta çipe dokununca değişiyor, sonraki sefere hatırlanıyor.
    static var current: TodoDestination {
        get { store?.string(forKey: "kb.todo.dest").flatMap(TodoDestination.init(rawValue:)) ?? .apple }
        set { store?.set(newValue.rawValue, forKey: "kb.todo.dest") }
    }

    /// Yüklü uygulamalar. Klavye `canOpenURL` soramıyor; uygulama açılınca yazıyor.
    static var installed: Set<TodoDestination> {
        get { Set((store?.stringArray(forKey: "kb.todo.installed") ?? []).compactMap(TodoDestination.init(rawValue:))) }
        set { store?.set(newValue.map(\.rawValue).sorted(), forKey: "kb.todo.installed") }
    }

    /// Seçilince çalışır mı: Hatırlatıcılar her zaman; Todoist token'la (API);
    /// Things ve TickTick yüklüyse.
    var isAvailable: Bool {
        switch self {
        case .apple: return true
        case .todoist: return TodoExport.todoistToken != nil
        case .things, .ticktick: return Self.installed.contains(self)
        }
    }

    /// Seçili ama kullanılamıyorsa kartta gösterilen kısa açıklama.
    var unavailableNote: String? {
        guard !isAvailable else { return nil }
        return self == .todoist ? "Todoist bağlı değil: uygulamada Yapay zeka › Bağlantılar’dan token ekle."
                                : "\(title) bu telefonda yüklü değil (uygulamayı bir kez açınca yenilenir)."
    }
}

enum TodoExport {
    /// Things: maddelerin hepsi tek `things:///json` adresiyle; liste adı Things'te
    /// proje/alan adı, saat `yyyy-MM-dd@HH:mm` (Things hatırlatması).
    /// culturedcode.com/things/support/articles/2803573
    static func thingsURL(_ plan: AIService.ReminderPlan) -> URL? {
        let todos: [[String: Any]] = plan.items.map { d in
            var a: [String: Any] = ["title": d.title]
            if let n = d.notes { a["notes"] = n }
            if let due = d.due { a["when"] = thingsWhen(due) }
            if let l = plan.list { a["list"] = l }
            return ["type": "to-do", "attributes": a]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: todos),
              let json = String(data: data, encoding: .utf8),
              var c = URLComponents(string: "things:///json") else { return nil }
        c.queryItems = [URLQueryItem(name: "data", value: json), URLQueryItem(name: "reveal", value: "true")]
        return c.url
    }

    private static func thingsWhen(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd@HH:mm"
        return f.string(from: d)
    }

    /// TickTick: tek görev alıyor; `x-success` ile uygulamaya dönülüp sıradaki
    /// gönderiliyor (`bestkeyboard://ticktick-sonraki`). blog.ticktick.com/2018/07/16
    static func tickTickURL(_ d: AIService.ReminderDraft, list: String?, callback: String) -> URL? {
        var c = URLComponents(string: "ticktick://x-callback-url/v1/add_task")
        var q = [URLQueryItem(name: "title", value: d.title)]
        if let n = d.notes { q.append(URLQueryItem(name: "content", value: n)) }
        if let due = d.due {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            q.append(URLQueryItem(name: "startDate", value: f.string(from: due)))
            q.append(URLQueryItem(name: "allDay", value: "false"))
        }
        if let list { q.append(URLQueryItem(name: "list", value: list)) }
        q.append(URLQueryItem(name: "x-success", value: callback))
        c?.queryItems = q
        return c?.url
    }

    // MARK: Todoist (API — birden çok görev ve proje için)

    /// Kişisel API token'ı anahtar zincirinde (Todoist › Ayarlar › Entegrasyonlar › Geliştirici).
    static var todoistToken: String? { AIService.secret("todoist") }
    @discardableResult static func setTodoistToken(_ t: String?) -> Bool { AIService.setSecret(t, account: "todoist") }

    /// Maddeleri Todoist'e ekler; liste adı bir projeyle eşleşirse oraya, yoksa Gelen Kutusu.
    /// developer.todoist.com/api/v1 — POST /tasks, GET /projects.
    static func addToTodoist(_ plan: AIService.ReminderPlan) async throws -> String {
        guard let token = todoistToken else { throw AIService.Failure.noKey }
        var projectID: String?
        var projectName = "Gelen Kutusu"
        if let list = plan.list {
            var req = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/projects")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try? JSONSerialization.jsonObject(with: data)
            let projects = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["results"] as? [[String: Any]]) ?? []
            if let p = projects.first(where: { ($0["name"] as? String)?.compare(list, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                projectID = p["id"] as? String ?? (p["id"] as? Int).map(String.init)
                projectName = list
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        for d in plan.items {
            var body: [String: Any] = ["content": d.title]
            if let n = d.notes { body["description"] = n }
            if let due = d.due { body["due_datetime"] = iso.string(from: due) }
            if let projectID { body["project_id"] = projectID }
            var req = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/tasks")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw AIService.Failure.http(code, code == 401 || code == 403 ? "Todoist token geçersiz" : "Todoist")
            }
        }
        return projectName
    }
}
