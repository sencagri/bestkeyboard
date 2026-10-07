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
        get { AppGroup.store.stringArray(forKey: AppGroup.Key.eventCalendars) ?? [] }
        set { AppGroup.store.set(newValue, forKey: AppGroup.Key.eventCalendars) }
    }

    /// Yer tutucular: `{şimdi}`, `{takvim}`, `{takvimler}`, `{metin}`.
    static let eventTemplateDefault = """
    Şu mesajdaki randevu, buluşma ya da etkinlikleri Apple Takvim etkinliklerine çevir.
    Şu an: {şimdi}.
    Önümüzdeki günler (tarih ve haftanın günü): {takvim}.
    Mesaj hangi dilde olursa olsun gün adlarını ve göreli ifadeleri bu takvimden tarihe çevir; tahmin etme, takvime bak.
    Her etkinlik ayrı madde. title: 2-5 kelimelik etkinlik adı, mesajın dilinde (ör. "Kadıköy'de buluşma",
    "Coffee at Starbucks", "Diş hekimi"); mesajı ya da soruyu olduğu gibi kopyalama.
    start: "YYYY-MM-DDTHH:mm". end: süre ya da bitiş biliniyorsa aynı biçimde, yoksa "".
    Saat yoksa: sabah 09:00, öğle 12:00, öğleden sonra 15:00, akşam 19:00, gece 21:00. Gün var ama saat hiç
    belirtilmemişse (doğum günü, tatil gibi) allDay true. location: yer geçiyorsa (ör. "Kadıköy otogarı"), yoksa "".
    notes: gerekirse kısa not, yoksa "".
    Kullanıcının takvimleri: {takvimler}. calendar: uygun bir takvim varsa adını AYNEN yaz, yoksa "".

    Mesaj:
    {metin}
    """

    static func eventPrompt(text: String, calendars: [String] = eventCalendars, template: String = "",
                            now: Date = Date()) -> String {
        prompt(template: template, default: eventTemplateDefault, text: text, now: now,
               names: ("{takvimler}", calendars, "bilinmiyor"))
    }

    static func events(from text: String, template: String = "", now: Date = Date()) async throws -> EventPlan {
        let item = objectSchema(["title": stringField, "start": stringField, "end": stringField,
                                 "allDay": ["type": "boolean"], "location": stringField, "notes": stringField])
        let schema = objectSchema(["calendar": stringField, "items": arrayField(item)])
        let obj = try jsonObject(try await complete(eventPrompt(text: text, template: template, now: now), schema: schema))
        let items: [EventDraft] = ((obj["items"] as? [[String: Any]]) ?? []).prefix(20).compactMap { o in
            guard let t = nonEmpty(o["title"]), let start = parseDate(o["start"]) else { return nil }
            let allDay = (o["allDay"] as? Bool) ?? false
            // Bitiş yoksa 1 saat (`endOrDefault`); tüm gün etkinliğinde gün sınırını EventMaker koyuyor.
            let d = EventDraft(title: t, start: start, end: parseDate(o["end"]), allDay: allDay,
                               location: nonEmpty(o["location"]), notes: nonEmpty(o["notes"]))
            return EventDraft(title: d.title, start: start, end: d.endOrDefault, allDay: allDay,
                              location: d.location, notes: d.notes)
        }
        guard !items.isEmpty else { throw Failure.nothingFound(what: "etkinlik", source: text) }
        let cal = nonEmpty(obj["calendar"]).flatMap { name in
            eventCalendars.first { $0.trEquals(name) }
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
        /// Avatar harfleri: ilk ve son sözcüğün baş harfi ("Ali Can Kaya" → "AK"),
        /// Türkçe büyük harfle; ad yoksa "?".
        var initials: String { Self.initials(of: displayName) }
        static func initials(of name: String) -> String {
            let words = name.split(separator: " ")
            return [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
                .map(String.init).joined().trUppercased.nilIfEmpty ?? "?"
        }
        /// Ad yoksa gösterilen.
        static let unnamed = "Adsız kişi"
    }

    /// Yer tutucu: `{metin}`.
    static let contactTemplateDefault = """
    Şu mesajdaki kişi bilgilerini Apple Kişiler kartına çevir. Mesaj hangi dilde olursa olsun.
    givenName / familyName: ad ve soyad (soyad yoksa "").
    phones ve emails: mesajdaki telefon numaralarını ve e-posta adreslerini HARFİ HARFİNE kopyala;
    tek harfini bile değiştirme, düzeltme ya da tamamlama.
    organization: şirket geçiyorsa, yoksa "". note: kart için kısa not (ör. "Tolga'nın kuzeni"), yoksa "".
    Mesajda olmayan bilgi uydurma.

    Mesaj:
    {metin}
    """

    static func contactPrompt(text: String, template: String = "") -> String {
        prompt(template: template, default: contactTemplateDefault, text: text, now: Date())
    }

    static func contact(from text: String, template: String = "") async throws -> ContactDraft {
        let schema = objectSchema(["givenName": stringField, "familyName": stringField,
                                   "phones": arrayField(stringField), "emails": arrayField(stringField),
                                   "organization": stringField, "note": stringField])
        let o = try jsonObject(try await complete(contactPrompt(text: text, template: template), schema: schema))
        let d = ContactDraft(givenName: nonEmpty(o["givenName"]) ?? "", familyName: nonEmpty(o["familyName"]) ?? "",
                             phones: verbatimPhones(o["phones"] as? [String] ?? [], in: text),
                             emails: verbatimEmails(o["emails"] as? [String] ?? [], in: text),
                             organization: nonEmpty(o["organization"]), note: nonEmpty(o["note"]))
        guard !d.displayName.isEmpty || !d.phones.isEmpty || !d.emails.isEmpty else {
            throw Failure.nothingFound(what: "kişi bilgisi", source: text)
        }
        return d
    }

    /// Önceki sürümlerin varsayılan istemleri: kullanıcının tuşunda hâlâ bunlardan
    /// biri duruyorsa (kendisi değiştirmemiş demek) yenisine geçiriliyor.
    static let legacyTemplates: [AIAction.Kind: [String]] = [
        .reminder: [#"""
    Şu mesajdaki yapılacakları Apple Hatırlatıcılar'a eklenecek maddelere çevir.
    Şu an: {şimdi}.
    Önümüzdeki günler (tarih ve haftanın günü): {takvim}.
    Mesaj hangi dilde olursa olsun gün adlarını ve göreli ifadeleri ("yarın", "next Friday"…) bu takvimden tarihe çevir;
    bugünün haftanın hangi günü olduğunu tahmin etme, takvime bak.
    Birden çok iş ya da alınacak şey varsa HER BİRİ AYRI madde olsun; miktarı başlıkta tut ("8 yumurta").
    Tek bir iş varsa tek madde. Başlıklar kısa ve mesajın dilinde; mesajdan gelmeli, açıklama ya da şablon metni yazma.
    due: "YYYY-MM-DDTHH:mm"; zaman yoksa "". Açık saat yoksa gün içi ifadeye göre: sabah 09:00, öğle 12:00,
    öğleden sonra 15:00, akşam 19:00, gece 21:00; hiçbiri yoksa 09:00. "Akşam 7" gibi ifadeleri 24 saate çevir (19:00).
    notes: gerekirse kısa not, yoksa "".
    Kullanıcının hatırlatıcı listeleri: {listeler}.
    list: maddelere uyan bir liste varsa adını AYNEN yaz. Yoksa ve birden çok madde varsa maddeleri toplayan
    kısa yeni bir liste adı yaz (ör. alınacaklar için "Alışveriş"). Tek bir iş için uygun liste yoksa boş bırak.

    Mesaj:
    {metin}
    """#],
        .event: [#"""
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
    """#],
        .contact: [#"""
    Şu mesajdaki kişi bilgilerini Apple Kişiler kartına çevir. Mesaj hangi dilde olursa olsun.
    givenName / familyName: ad ve soyad (soyad yoksa ""). phones: telefon numaraları, mesajdaki gibi.
    emails: e-posta adresleri. organization: şirket geçiyorsa, yoksa "". note: kart için kısa not (ör. "Tolga'nın kuzeni"), yoksa "".
    Mesajda olmayan bilgi uydurma.

    Mesaj:
    {metin}
    """#],
    ]

    // MARK: - Ortak yardımcılar

    /// Model e-postayı bir harf değiştirip yazabiliyor ("kayatesisat" → "kayetesisat").
    /// Mesajda harfi harfine geçmeyen adres yerine mesajdaki adresler alınıyor.
    static func verbatimEmails(_ model: [String], in text: String) -> [String] {
        let found = matches(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: text)
        let lower = text.lowercased()
        let kept = model.map { $0.trimmed }.filter { !$0.isEmpty && lower.contains($0.lowercased()) }
        return kept.count == model.filter({ !$0.isEmpty }).count && !kept.isEmpty ? kept : (found.isEmpty ? kept : found)
    }

    /// Telefon: rakamları mesajda (boşluk/tire farkı gözetmeden) geçmeyen numara atılıyor.
    static func verbatimPhones(_ model: [String], in text: String) -> [String] {
        let digits = text.filter(\.isNumber)
        return model.map { $0.trimmed }.filter { p in
            let d = p.filter(\.isNumber)
            return d.count >= 3 && digits.contains(d)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Yapılandırılmış yanıt şeması: alanların hepsi zorunlu (boş metin = yok),
    /// başka alan yok. Null'a izin veren tip dizileri her sağlayıcıda
    /// desteklenmiyor; boş metin hepsinde çalışıyor.
    static func objectSchema(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties,
         "required": properties.keys.sorted(), "additionalProperties": false]
    }
    static let stringField: [String: Any] = ["type": "string"]
    static func arrayField(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }

    /// Tuşun istemi: şablon boşsa varsayılan; `{şimdi}`, `{takvim}` ve verilen ad
    /// listesi yer tutucusu doluyor, mesaj `{metin}` yerine (yoksa sona) giriyor.
    /// Düzenleyicideki önizleme de bunu gösteriyor.
    static func prompt(template: String, default def: String, text: String, now: Date,
                       names: (placeholder: String, values: [String], none: String)? = nil) -> String {
        var p = fill(template.trimmed.isEmpty ? def : template, now: now)
        if let names {
            p = p.replacingOccurrences(of: names.placeholder,
                                       with: names.values.isEmpty ? names.none : names.values.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        return withMessage(p, text)
    }

    /// `{şimdi}` ve `{takvim}`.
    static func fill(_ tpl: String, now: Date) -> String {
        return tpl
            .replacingOccurrences(of: "{şimdi}", with: "\(DateFormats.iso8601.string(from: now)) (saat dilimi \(TimeZone.current.identifier))")
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
        ((v as? String) ?? "").trimmed.nilIfEmpty
    }

    static func parseDate(_ v: Any?) -> Date? {
        guard let s = nonEmpty(v) else { return nil }
        return DateFormats.posix("yyyy-MM-dd'T'HH:mm").date(from: String(s.prefix(16)))
            ?? DateFormats.posix("yyyy-MM-dd").date(from: String(s.prefix(10)))
    }
}

// MARK: - Tek giriş noktası

/// Yapılandırılmış çıkarımın sonucu (Hatırlatıcı / Takvim / Kişi).
enum Extraction {
    case reminders(AIService.ReminderPlan)
    case events(AIService.EventPlan)
    case contact(AIService.ContactDraft)

    /// Günlükteki kısa sonuç.
    var logSummary: String {
        switch self {
        case let .reminders(p): return "\(p.items.count) madde: " + p.items.map(\.title).joined(separator: ", ")
        case let .events(p): return p.items.map { $0.title + " · " + $0.trWhen }.joined(separator: "; ")
        case let .contact(d): return d.displayName
        }
    }
}

extension AIService {
    /// Mesajdan hatırlatıcı / etkinlik / kişi çıkarır ve günlüğe yazar — klavye,
    /// paylaşım eklentisi, Kestirmeler, Siri ve Kontrol Merkezi hepsi bunu çağırıyor.
    /// - Parameters:
    ///   - template: tuşun istemi (boş = varsayılan).
    ///   - action: günlükte görünen ad ("Takvim", "Görüntüden · Hatırlatıcı"…).
    ///   - source: metnin nereden geldiği ("Yazdığın", "Son ekran görüntüsü"…).
    static func extract(_ kind: AIAction.Kind, from text: String, template: String,
                        origin: AILog.Origin, action: String, source: String) async throws -> (value: Extraction, id: UUID) {
        // Metin ve resim tuşları buraya gelmemeli; sessizce hatırlatıcıya dönmesin.
        precondition(kind.isStructured, "extract yalnız hatırlatıcı / takvim / kişi için")
        return try await AILog.measure(origin: origin, action: action, source: source, text: text,
                                summarize: { (e: Extraction) in e.logSummary }) {
            switch kind {
            case .event: return .events(try await events(from: text, template: template))
            case .contact: return .contact(try await contact(from: text, template: template))
            case .reminder: return .reminders(try await reminders(from: text, template: template))
            case .text, .image: preconditionFailure("yapılandırılmamış tür")
            }
        }
    }
}

extension AIService.EventDraft {
    /// Bitiş yoksa (ya da başlangıçtan önceyse) 1 saat.
    var endOrDefault: Date { end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600) }

    /// "Cmt 10 Eki · 19:00"; tüm gün etkinliğinde "Cmt 10 Eki · tüm gün".
    var trWhen: String {
        DateFormats.turkish(allDay ? "EEE d MMM" : "EEE d MMM · HH:mm").string(from: start) + (allDay ? " · tüm gün" : "")
    }

    /// "2 saat", "1 sa 30 dk", "45 dk"; tüm gün etkinliğinde `nil`.
    var trDuration: String? {
        guard !allDay else { return nil }
        let m = Int((endOrDefault.timeIntervalSince(start) / 60).rounded())
        return m % 60 == 0 ? "\(m / 60) saat" : m > 60 ? "\(m / 60) sa \(m % 60) dk" : "\(m) dk"
    }
}

extension AIService {
    /// Hatırlatıcı zamanı kartta: "Bugün" / "Yarın" / "12 Eki" ve "19:00".
    /// Hatırlatıcının zamanı: "Yarın 09:00", "12 Eki 18:30"; zaman yoksa `nil`.
    static func trWhen(_ d: Date?) -> String? {
        let (day, time) = dayTime(d)
        return [day, time].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    private static func dayTime(_ d: Date?) -> (day: String?, time: String?) {
        guard let d else { return (nil, nil) }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(d) { day = "Bugün" }
        else if cal.isDateInTomorrow(d) { day = "Yarın" }
        else { day = DateFormats.turkish("d MMM").string(from: d) }
        return (day, DateFormats.turkish("HH:mm").string(from: d))
    }
}

// MARK: - Yapılacaklar uygulamaları (Things · Todoist · TickTick)

/// Başlığı olan taslak — boş başlıklı satır eklenmiyor (form, kart, kestirme aynı kural).
protocol TitledDraft { var title: String { get } }
extension TitledDraft {
    var hasTitle: Bool { !title.trimmed.isEmpty }
}
extension AIService.EventDraft: TitledDraft {}
extension AIService.ReminderDraft: TitledDraft {}

/// Önizleme kartlarının ekle düğmeleri — klavye kartı, paylaşım ve uygulama aynı metin.
enum AddText {
    static let calendar = "Takvime ekle"
    static let contacts = "Kişilere ekle"
    static let edit = "Düzenle"
    static let saving = "Ekleniyor…"
    static let openCalendar = "Takvim’de aç"
    static let openContacts = "Kişiler’de aç"
    /// "Takvime ekle" / "3 etkinliği ekle".
    static func events(_ n: Int) -> String { n > 1 ? "\(n) etkinliği ekle" : calendar }
}

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
    /// Eklendikten sonra "…’de aç": uygulamanın kendisi (Things bugün listesi).
    var openURL: URL? {
        switch self {
        case .apple: return URL(string: "x-apple-reminderkit://")
        case .things: return URL(string: "things:///show?id=today")
        case .todoist, .ticktick: return scheme.flatMap { URL(string: $0 + "://") }
        }
    }

    /// "Hatırlatıcılar’da aç", "Things’te aç".
    var openTitle: String {
        switch self {
        case .apple: return "Hatırlatıcılar’da aç"
        case .things: return "Things’te aç"
        case .todoist: return "Todoist’te aç"
        case .ticktick: return "TickTick’te aç"
        }
    }

    /// Ekle düğmesi; Hatırlatıcılar'da birden çok madde sayıyla.
    func addTitle(count: Int) -> String { self == .apple && count > 1 ? "\(count) maddeyi ekle" : addTitle }

    /// Kartın ana düğmesi (tasarım 30).
    var addTitle: String {
        switch self {
        case .apple: return "Hatırlatıcılar’a ekle"
        case .things: return "Things’e gönder"
        case .todoist: return "Todoist’e ekle"
        case .ticktick: return "TickTick’e gönder"
        }
    }

    private static var store: UserDefaults { AppGroup.store }

    /// Son seçilen hedef — kartta çipe dokununca değişiyor, sonraki sefere hatırlanıyor.
    static var current: TodoDestination {
        get { store.string(forKey: AppGroup.Key.todoDestination).flatMap(TodoDestination.init(rawValue:)) ?? .apple }
        set { store.set(newValue.rawValue, forKey: AppGroup.Key.todoDestination) }
    }

    /// Yüklü uygulamalar. Klavye `canOpenURL` soramıyor; uygulama açılınca yazıyor.
    static var installed: Set<TodoDestination> {
        get { Set((store.stringArray(forKey: AppGroup.Key.todoInstalled) ?? []).compactMap(TodoDestination.init(rawValue:))) }
        set { store.set(newValue.map(\.rawValue).sorted(), forKey: AppGroup.Key.todoInstalled) }
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
        return self == .todoist ? Self.todoistNotConnected
                                : "\(title) bu telefonda yüklü değil (uygulamayı bir kez açınca yenilenir)."
    }

    static let todoistNotConnected = "Todoist bağlı değil: uygulamada \(CommonText.aiScreen) › Bağlantılar’dan token ekle."

    /// Eklendiği yer: "Things › Alışveriş", "Hatırlatıcılar".
    func place(_ list: String?) -> String { title + (list.map { " › " + $0 } ?? "") }
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

    private static func thingsWhen(_ d: Date) -> String { DateFormats.posix("yyyy-MM-dd@HH:mm").string(from: d) }

    /// TickTick: tek görev alıyor; `x-success` ile uygulamaya dönülüp sıradaki
    /// gönderiliyor (`bestkeyboard://ticktick-sonraki?z=<jeton>`). blog.ticktick.com/2018/07/16
    static func tickTickURL(_ d: AIService.ReminderDraft, list: String?, token: String) -> URL? {
        var c = URLComponents(string: "ticktick://x-callback-url/v1/add_task")
        var q = [URLQueryItem(name: "title", value: d.title)]
        if let n = d.notes { q.append(URLQueryItem(name: "content", value: n)) }
        if let due = d.due {
            q.append(URLQueryItem(name: "startDate", value: DateFormats.posix("yyyy-MM-dd'T'HH:mm:ss.SSSZ").string(from: due)))
            q.append(URLQueryItem(name: "allDay", value: "false"))
        }
        if let list { q.append(URLQueryItem(name: "list", value: list)) }
        q += DeepLink.callbacks(.tickTickNext, [URLQueryItem(name: DeepLink.Param.token, value: token)])
        c?.queryItems = q
        return c?.url
    }

    // MARK: Todoist (API — birden çok görev ve proje için)

    /// Kişisel API token'ı anahtar zincirinde (Todoist › Ayarlar › Entegrasyonlar › Geliştirici).
    static var todoistToken: String? { AIService.secret("todoist") }
    @discardableResult static func setTodoistToken(_ t: String?) -> Bool { AIService.setSecret(t, account: "todoist") }

    /// Yarıda kalan gönderim. `added`: eklendiği **kesin** olanlar. `unknown`: istek
    /// gitti ama yanıt gelmedi — eklenmiş de olabilir; yeniden gönderilmiyor (çift
    /// görev olmasın), kullanıcıya Todoist'te bakması söyleniyor.
    struct TodoistPartial: LocalizedError {
        let added: Int
        let total: Int
        let unknown: String?
        let reason: String
        /// Yeniden denemede gönderilecekler: kesin eklenenler ve sonucu bilinmeyen hariç.
        func remaining<T>(_ items: [T]) -> [T] { Array(items.dropFirst(added + (unknown == nil ? 0 : 1))) }
        var errorDescription: String? {
            "Todoist: \(added)/\(total) görev eklendi (\(reason))."
                + (unknown.map { " “\($0)” gönderildi ama yanıt gelmedi: Todoist'te var mı bak, yoksa elle ekle." } ?? "")
        }
    }

    /// İstek sunucuya ulaşmış olabilir mi (yanıt gelmeden koptu ya da iptal edildi —
    /// iptal sunucudaki işi geri almıyor). Bağlantı hiç kurulamadıysa ya da sunucu
    /// hata döndürdüyse sonuç kesin: eklenmedi.
    private static func outcomeUnknown(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return ![.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed].contains(e.code)
    }

    private static func todoistRequest(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        HTTP.bearer(&req, token)
        return req
    }

    private static func checkTodoist(_ resp: URLResponse) throws {
        let code = HTTP.status(resp)
        guard HTTP.isSuccess(resp) else {
            throw AIService.Failure.http(code, code == 401 || code == 403 ? "Todoist token geçersiz" : "Todoist")
        }
    }

    /// Ada göre proje kimliği; bütün sayfalar (`next_cursor`) okunuyor. Sorgu
    /// başarısızsa hata — sessizce Gelen Kutusu'na yazılmıyor.
    static func todoistProjectID(named name: String, token: String) async throws -> String? {
        var cursor: String?
        repeat {
            var c = URLComponents(string: "https://api.todoist.com/api/v1/projects")!
            c.queryItems = [URLQueryItem(name: "limit", value: "200")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let (data, resp) = try await URLSession.shared.data(for: todoistRequest(c.url!, token: token))
            try checkTodoist(resp)
            let json = try JSONSerialization.jsonObject(with: data)
            let page: [[String: Any]]
            if let arr = json as? [[String: Any]] { page = arr; cursor = nil }
            else if let o = json as? [String: Any], let arr = o["results"] as? [[String: Any]] {
                page = arr; cursor = (o["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            } else { throw AIService.Failure.http(0, "Todoist proje listesi okunamadı") }
            if let p = page.first(where: { ($0["name"] as? String)?.trEquals(name) == true }) {
                return p["id"] as? String ?? (p["id"] as? Int).map(String.init)
            }
        } while cursor != nil
        return nil
    }

    /// Maddeleri Todoist'e ekler; liste adı bir projeyle eşleşirse oraya, yoksa Gelen Kutusu.
    /// developer.todoist.com/api/v1 — POST /tasks, GET /projects.
    static func addToTodoist(_ plan: AIService.ReminderPlan) async throws -> String {
        guard let token = todoistToken else { throw AIService.Failure.noKey }
        var projectID: String?
        var projectName = "Gelen Kutusu"
        if let list = plan.list, let id = try await todoistProjectID(named: list, token: token) {
            projectID = id
            projectName = list
        }
        for (i, d) in plan.items.enumerated() {
            var body: [String: Any] = ["content": d.title]
            if let n = d.notes { body["description"] = n }
            if let due = d.due { body["due_datetime"] = DateFormats.iso8601.string(from: due) }
            if let projectID { body["project_id"] = projectID }
            var req = todoistRequest(URL(string: "https://api.todoist.com/api/v1/tasks")!, token: token)
            try HTTP.postJSON(&req, body)
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                try checkTodoist(resp)
            } catch {
                let unknown = outcomeUnknown(error) ? d.title : nil
                guard i > 0 || unknown != nil else { throw error }
                throw TodoistPartial(added: i, total: plan.items.count, unknown: unknown, reason: error.localizedDescription)
            }
        }
        return projectName
    }
}

// MARK: - Klavye → uygulama aktarımı

/// ✦ kartının çıkarımı App Group'ta bekliyor; adreste yalnız tek kullanımlık
/// rastgele kimlik gidiyor (`bestkeyboard://kisi?id=…`). Uygulama kimliği
/// tüketmeden onaysız yazmıyor — başka bir uygulama ya da web sayfası
/// `bestkeyboard://` açtırıp Takvim/Kişiler'e veri yazdıramasın. Uzun planlar
/// da adres uzunluğuna takılmıyor.
enum Handoff {
    /// Her aktarım kendi anahtarında (`kb.handoff.<kimlik>`): ortak bir sözlüğü
    /// okuyup yazan put/take, klavye ve uygulama aynı anda çalışınca birbirinin
    /// kaydını ezebiliyor ya da tüketilmiş kaydı geri getirebiliyordu.
    private static let prefix = AppGroup.Key.handoffPrefix
    private static let ttl = AppGroup.handoffTTL
    private static var store: UserDefaults? { AppGroup.defaults }

    /// - Returns: adrese konacak kimlik; App Group yazılamıyorsa `nil`.
    static func put(_ payload: Data, now: Date = Date()) -> String? {
        guard let store else { return nil }
        let id = UUID().uuidString
        store.set(["d": payload, "t": now.timeIntervalSince1970], forKey: prefix + id)
        return id
    }

    /// Kimliğin verisini döndürür ve siler (ikinci kez açılan adres bir şey yapmaz).
    /// Süresi geçmişse veri dönmez.
    static func take(_ id: String, now: Date = Date()) -> Data? {
        guard let store, UUID(uuidString: id) != nil else { return nil }
        let entry = store.dictionary(forKey: prefix + id)
        store.removeObject(forKey: prefix + id)
        guard let t = entry?["t"] as? TimeInterval, now.timeIntervalSince1970 - t < ttl else { return nil }
        return entry?["d"] as? Data
    }

    /// Açılamayan ya da hiç tüketilmeyen aktarımların verisini siler
    /// (uygulama her öne geldiğinde; açılış başarısızsa hemen).
    static func purge(_ id: String? = nil, now: Date = Date()) {
        guard let store else { return }
        if let id { store.removeObject(forKey: prefix + id); return }
        for (k, v) in store.dictionaryRepresentation() where k.hasPrefix(prefix) {
            let t = (v as? [String: Any])?["t"] as? TimeInterval ?? 0
            if now.timeIntervalSince1970 - t >= ttl { store.removeObject(forKey: k) }
        }
    }

    /// Adresteki veri: `id` (klavyeden) ya da eski biçimdeki satır içi `param`
    /// (dışarıdan gelmiş olabilir → her zaman `edit`, onaysız yazılmaz).
    static func payload(from url: URL, _ host: DeepLink.Host) -> (data: Data, edit: Bool)? {
        guard DeepLink.matches(url, host),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let edit = items.contains { $0.name == DeepLink.Param.edit && $0.value == "1" }
        if let id = items.first(where: { $0.name == DeepLink.Param.id })?.value, let d = take(id) { return (d, edit) }
        if let b = items.first(where: { $0.name == DeepLink.payloadParam(host) })?.value,
           let d = Data(base64Encoded: b) { return (d, true) }
        return nil
    }

    /// Gönderen taraf (klavye, paylaşım eklentisi): veriyi ortak klasöre koyup
    /// adresi kurar. Ortak klasör yazılamazsa veri adresin içinde gider (uygulama
    /// onu onay ekranıyla açar). - Returns: adres ve (varsa) kimlik — açılamazsa `purge(id)`.
    static func link(_ host: DeepLink.Host, payload: Data, edit: Bool,
                     extra: [URLQueryItem] = []) -> (url: URL, id: String?)? {
        let id = put(payload)
        let carrier = id.map { URLQueryItem(name: DeepLink.Param.id, value: $0) }
            ?? URLQueryItem(name: DeepLink.payloadParam(host), value: payload.base64EncodedString())
        var q = [carrier] + extra
        if edit { q.append(URLQueryItem(name: DeepLink.Param.edit, value: "1")) }
        guard let url = DeepLink.url(host, q) else { if let id { purge(id) }; return nil }
        return (url, id)
    }
}
