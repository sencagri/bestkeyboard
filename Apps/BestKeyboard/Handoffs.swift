import Foundation

// Klavyeden ve dışarıdan gelen ekleme işleri: adres → plan (onaylı ya da onaysız).

/// `bestkeyboard://<host>?id=<App Group kimliği>[&edit=1]` (klavyeden) ya da
/// satır içi `<param>=<base64 JSON>` — ikincisi her zaman onay ekranıyla açılır.
private func decodeHandoff<T: Decodable>(_ url: URL, _ host: DeepLink.Host) -> (T, Bool)? {
    guard let p = Handoff.payload(from: url, host),
          let value = try? JSONDecoder().decode(T.self, from: p.data) else { return nil }
    return (value, p.edit)
}

struct EventHandoff: Identifiable {
    let id = UUID()
    var plan: AIService.EventPlan
    var edit: Bool
    init(plan: AIService.EventPlan, edit: Bool) { self.plan = plan; self.edit = edit }
    init?(url: URL) {
        guard let (p, e): (AIService.EventPlan, Bool) = decodeHandoff(url, .event),
              !p.items.isEmpty else { return nil }
        plan = p; edit = e
    }
}

struct ContactHandoff: Identifiable {
    let id = UUID()
    var draft: AIService.ContactDraft
    var edit: Bool
    init(draft: AIService.ContactDraft, edit: Bool) { self.draft = draft; self.edit = edit }
    init?(url: URL) {
        guard let (d, e): (AIService.ContactDraft, Bool) = decodeHandoff(url, .contact) else { return nil }
        draft = d; edit = e
    }
}

/// `bestkeyboard://hatirlatici?plan=<base64 JSON>[&edit=1]` — klavyenin ✦ kartı
/// (tasarım 26). Eski tek maddelik `title/due/notes` biçimi de okunuyor.
struct ReminderHandoff: Identifiable {
    let id = UUID()
    var plan: AIService.ReminderPlan
    var edit: Bool
    /// Klavyede seçilen hedef (tasarım 30); yoksa Hatırlatıcılar.
    var destination: TodoDestination = .apple

    init(plan: AIService.ReminderPlan, edit: Bool, destination: TodoDestination) {
        self.plan = plan; self.edit = edit; self.destination = destination
    }

    init?(url: URL) {
        guard DeepLink.matches(url, .reminder),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        // Klavyeden gelen (App Group kimliği) onaysız eklenebilir; adresin
        // içinde gelen plan dışarıdan da gelmiş olabilir → düzenleme ekranı.
        if let h = Handoff.payload(from: url, .reminder),
           let p = try? JSONDecoder().decode(AIService.ReminderPlan.self, from: h.data), !p.items.isEmpty {
            plan = p
            edit = h.edit
        } else if let title = q("title"), !title.isEmpty {
            let due = q("due").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            plan = AIService.ReminderPlan(list: nil, items: [.init(title: title, due: due, notes: q("notes"))])
            edit = true
        } else { return nil }
        destination = q(DeepLink.Param.destination).flatMap(TodoDestination.init(rawValue:)) ?? .apple
    }
}
