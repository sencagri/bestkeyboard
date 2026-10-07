import EventKit
import SwiftUI

// Klavyenin ✦ kartından gelen Takvim etkinliği ve kişi kartı (tasarım 28, 29,
// 32) ve Yapay zeka tuşlarındaki "Bağlantılar" kartı (tasarım 31).

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

/// Ekleme sayfalarının ortak durumu.
private enum MakerPhase: Equatable { case editing, saving, done(String), failed(String) }

/// Altta sabit duran ana düğme (tasarım 32): eklenince yeşil "…’de aç".
private struct MakerButton: View {
    let phase: MakerPhase
    let addTitle: String
    let openTitle: String
    let disabled: Bool
    let add: () -> Void
    let open: () -> Void
    var body: some View {
        let done = if case .done = phase { true } else { false }
        Button { done ? open() : add() } label: {
            Text(phase == .saving ? "Ekleniyor…" : done ? openTitle : addTitle).font(.headline)
                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                .background(done ? BK.green.ink : BK.accent, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(phase == .saving || (!done && disabled))
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(BK.ground)
    }
}

private struct DoneBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy))
            Text(text).font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(BK.green.ink)
        .padding(.horizontal, 14).frame(minHeight: 46)
        .background(BK.green.chip, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.footnote).foregroundStyle(BK.sub).frame(width: 64, alignment: .leading)
            content
        }
        .frame(minHeight: 46)
    }
}

// MARK: - Etkinlik (32a)

struct EventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var handoff: EventHandoff
    @State private var calendars: [EventMaker.Choice] = []
    @State private var calendarID: String?
    @State private var phase: MakerPhase = .editing
    /// Kaydedilirken ve sonra form kilitli: ekrandaki, kaydedilenle aynı kalsın.
    private var locked: Bool { phase == .saving || { if case .done = phase { return true }; return false }() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case let .done(cal) = phase { DoneBanner(text: MakerText.eventsTitle(count: validItems.count, calendar: cal)) }
                    Group {
                        ForEach(handoff.plan.items.indices, id: \.self) { i in item(i) }
                        if !calendars.isEmpty { calendarCard }
                    }
                    .disabled(locked)
                    if case let .failed(msg) = phase { Text(msg).font(.footnote).foregroundStyle(BK.orange.ink) }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                MakerButton(phase: phase,
                            addTitle: handoff.plan.items.count > 1 ? "\(handoff.plan.items.count) etkinliği ekle" : "Takvime ekle",
                            openTitle: "Takvim’de aç", disabled: validItems.isEmpty,
                            add: { Task { await save() } },
                            open: {
                                let t = handoff.plan.items.first?.start.timeIntervalSinceReferenceDate ?? 0
                                if let url = AppLinks.calendar(at: Date(timeIntervalSinceReferenceDate: t)) { Task { _ = await URLOpener.open(url) } }
                            })
            }
            .background(BK.ground.ignoresSafeArea())
            .foregroundStyle(BK.ink)
            .navigationTitle("Etkinlik")
            .navigationBarTitleDisplayMode(.inline)
            .bkScreen("Etkinlik")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .editing || phase == .saving ? "Vazgeç" : "Kapat") { dismiss() }
                }
            }
        }
        .task {
            calendars = EventMaker.calendarChoices()
            calendarID = EventMaker.calendarID(named: handoff.plan.calendar)
            if !handoff.edit { await save() }
        }
    }

    @ViewBuilder private func item(_ i: Int) -> some View {
        let d = $handoff.plan.items[i]
        BKCard(padding: 0) {
            VStack(spacing: 0) {
                TextField("Başlık", text: d.title).font(.headline).frame(minHeight: 50)
                Divider().overlay(BK.line)
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(BK.sub)
                    TextField("Yer", text: Binding(get: { d.wrappedValue.location ?? "" },
                                                   set: { d.wrappedValue.location = $0.isEmpty ? nil : $0 }))
                }
                .frame(minHeight: 46)
            }
            .padding(.horizontal, 16)
        }
        BKCard(padding: 0) {
            VStack(spacing: 0) {
                Toggle("Tüm gün", isOn: d.allDay).tint(BK.green.ink).frame(minHeight: 50)
                Divider().overlay(BK.line)
                DatePicker("Başlangıç", selection: Binding(get: { d.wrappedValue.start }, set: { new in
                    // Başlangıç kayınca süre korunuyor.
                    let len = (d.wrappedValue.end ?? new).timeIntervalSince(d.wrappedValue.start)
                    d.wrappedValue.start = new
                    d.wrappedValue.end = new.addingTimeInterval(max(len, 0))
                }), displayedComponents: d.wrappedValue.allDay ? .date : [.date, .hourAndMinute])
                    .frame(minHeight: 50)
                Divider().overlay(BK.line)
                DatePicker("Bitiş", selection: Binding(get: { d.wrappedValue.end ?? d.wrappedValue.start },
                                                       set: { d.wrappedValue.end = $0 }),
                           in: d.wrappedValue.start..., displayedComponents: d.wrappedValue.allDay ? .date : [.date, .hourAndMinute])
                    .frame(minHeight: 50)
                Divider().overlay(BK.line)
                HStack {
                    Text("Uyarı")
                    Spacer()
                    Text(d.wrappedValue.allDay ? "O gün 09:00" : "30 dk önce").foregroundStyle(BK.sub)
                }
                .frame(minHeight: 50)
            }
            .padding(.horizontal, 16)
            .environment(\.locale, .turkish)
        }
    }

    private var calendarCard: some View {
        BKCard(padding: 16) {
            BKSectionTitle(text: "Takvim", color: BK.accent)
            ForEach(calendars) { c in
                let on = calendarID == c.id
                let twin = calendars.filter { $0.title == c.title }.count > 1
                VStack(spacing: 0) {
                    Divider().overlay(BK.line)
                    Button { calendarID = c.id } label: {
                        HStack(spacing: 10) {
                            Circle().fill(c.color).frame(width: 12, height: 12)
                            Text(c.title).foregroundStyle(BK.ink)
                            if twin { Text(c.account).font(.footnote).foregroundStyle(BK.sub) }
                            Spacer()
                            if on { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(BK.accent) }
                        }
                        .frame(minHeight: 46).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var validItems: [AIService.EventDraft] {
        handoff.plan.items.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func save() async {
        phase = .saving
        do {
            let cal = try await EventMaker.add(AIService.EventPlan(calendar: handoff.plan.calendar, items: validItems),
                                               calendarID: calendarID)
            phase = .done(cal)
            calendars = EventMaker.calendarChoices()
        } catch { phase = .failed(error.localizedDescription) }
    }
}

// MARK: - Kişi (32b)

struct ContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var handoff: ContactHandoff
    @State private var phase: MakerPhase = .editing
    private var locked: Bool { phase == .saving || { if case .done = phase { return true }; return false }() }

    private var initials: String {
        handoff.draft.initials
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(Color(white: 0.58), in: Circle())
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    if case let .done(name) = phase { DoneBanner(text: MakerText.contactTitle(name)) }
                    BKCard(padding: 0) {
                        VStack(spacing: 0) {
                            FieldRow(label: "Ad") { TextField("Ad", text: $handoff.draft.givenName) }
                            Divider().overlay(BK.line)
                            FieldRow(label: "Soyad") { TextField("Soyad", text: $handoff.draft.familyName) }
                            Divider().overlay(BK.line)
                            FieldRow(label: "Kurum") {
                                TextField("Kurum", text: Binding(get: { handoff.draft.organization ?? "" },
                                                                 set: { handoff.draft.organization = $0.isEmpty ? nil : $0 }))
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .disabled(locked)
                    listCard("Telefonlar", tag: "cep", values: $handoff.draft.phones, add: "Telefon ekle", keyboard: .phonePad)
                        .disabled(locked)
                    listCard("E-postalar", tag: "e-posta", values: $handoff.draft.emails, add: "E-posta ekle", keyboard: .emailAddress)
                        .disabled(locked)
                    if case let .failed(msg) = phase { Text(msg).font(.footnote).foregroundStyle(BK.orange.ink) }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                MakerButton(phase: phase, addTitle: "Kişilere ekle", openTitle: "Kişiler’de aç", disabled: isEmpty,
                            add: { Task { await save() } },
                            open: { if let url = AppLinks.contacts { Task { _ = await URLOpener.open(url) } } })
            }
            .background(BK.ground.ignoresSafeArea())
            .foregroundStyle(BK.ink)
            .navigationTitle("Kişi")
            .navigationBarTitleDisplayMode(.inline)
            .bkScreen("Kişi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .editing || phase == .saving ? "Vazgeç" : "Kapat") { dismiss() }
                }
            }
        }
        .task { if !handoff.edit { await save() } }
    }

    private func listCard(_ title: String, tag: String, values: Binding<[String]>, add: String,
                          keyboard: UIKeyboardType) -> some View {
        BKCard(padding: 16) {
            BKSectionTitle(text: title, color: BK.accent)
            ForEach(values.wrappedValue.indices, id: \.self) { i in
                VStack(spacing: 0) {
                    Divider().overlay(BK.line)
                    HStack(spacing: 10) {
                        Button { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle").font(.title3).foregroundStyle(BK.pink.ink).frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tag) sil")
                        Text(tag).font(.footnote).foregroundStyle(BK.sub).frame(width: 52, alignment: .leading)
                        TextField(tag, text: values[i]).keyboardType(keyboard).textInputAutocapitalization(.never)
                    }
                    .frame(minHeight: 46)
                }
            }
            Divider().overlay(BK.line)
            Button { values.wrappedValue.append("") } label: {
                Label(add, systemImage: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(BK.accent)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var cleaned: AIService.ContactDraft {
        var d = handoff.draft
        d.givenName = d.givenName.trimmingCharacters(in: .whitespaces)
        d.familyName = d.familyName.trimmingCharacters(in: .whitespaces)
        d.phones = d.phones.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        d.emails = d.emails.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return d
    }

    private var isEmpty: Bool {
        let d = cleaned
        return d.displayName.isEmpty && d.phones.isEmpty && d.emails.isEmpty
    }

    private func save() async {
        phase = .saving
        do { phase = .done(try await ContactMaker.add(cleaned)) }
        catch { phase = .failed(error.localizedDescription) }
    }
}

extension TodoDestination {
    /// Eklendikten sonra "…’de aç".
    var openURL: URL? {
        switch self {
        case .apple: return AppLinks.reminders()
        case .things: return URL(string: "things:///show?id=today")
        case .todoist: return URL(string: "todoist://")
        case .ticktick: return URL(string: "ticktick://")
        }
    }
}

// MARK: - Klavyeden gelen işler

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

struct ReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var handoff: ReminderHandoff
    @State private var lists: [String] = AIService.reminderLists
    @State private var state: Phase = .editing
    enum Phase: Equatable { case editing, saving, done(TodoRouter.Result, count: Int), failed(String) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state {
                    case let .done(result, count):
                        BKCard {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                                    .frame(width: 36, height: 36).background(BK.green.ink, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(!result.confirmed ? "Gönderildi" : count > 1 ? "\(count) madde eklendi" : "Eklendi").font(.headline)
                                    Text(summary).font(.subheadline).foregroundStyle(BK.sub).lineLimit(3)
                                }
                            }
                            Text(result.confirmed ? "\(result.place). \(CommonText.backToChat)."
                                 : "\(result.place) açıldı; maddelerin orada göründüğünü kontrol et (ilk kullanımda izin isteyebilir).")
                                .font(.footnote).foregroundStyle(BK.sub)
                        }
                        // Eklendiği uygulamada görmek için.
                        Button {
                            if let url = handoff.destination.openURL { Task { _ = await URLOpener.open(url) } }
                        } label: {
                            Label("\(handoff.destination.title)’da aç", systemImage: "checklist").font(.headline)
                                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                                .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    default:
                        Group {
                        BKCard {
                            Text("Nereye").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(TodoDestination.allCases, id: \.self) { d in
                                        let on = handoff.destination == d
                                        Button { handoff.destination = d; TodoDestination.current = d } label: {
                                            Text(d.title).font(.subheadline.weight(.bold))
                                                .foregroundStyle(on ? .white : BK.ink)
                                                .padding(.horizontal, 12).frame(height: 34)
                                                .background(on ? BK.accent : BK.ground, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .opacity(d.isAvailable ? 1 : 0.45)
                                        .accessibilityAddTraits(on ? .isSelected : [])
                                    }
                                }
                            }
                            if let note = handoff.destination.unavailableNote {
                                Text(note).font(.caption).foregroundStyle(BK.orange.ink)
                            }
                            Text("Liste").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                            Picker("Liste", selection: Binding(get: { handoff.plan.list ?? "" },
                                                              set: { handoff.plan.list = $0.isEmpty ? nil : $0 })) {
                                Text("Varsayılan liste").tag("")
                                ForEach(lists, id: \.self) { Text($0).tag($0) }
                                // Önerilen yeni liste (henüz yok) da seçenek; eklenince açılıyor.
                                if let l = handoff.plan.list, !lists.contains(l) { Text("\(l) (yeni liste)").tag(l) }
                            }
                            .pickerStyle(.menu).tint(BK.accent)
                        }
                        BKCard(padding: 16) {
                            Text("Maddeler").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                            ForEach(handoff.plan.items.indices, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "circle").foregroundStyle(BK.accent)
                                        TextField("Madde", text: $handoff.plan.items[i].title)
                                            .font(.body.weight(.semibold))
                                        Button {
                                            handoff.plan.items.remove(at: i)
                                        } label: {
                                            Image(systemName: "minus.circle").foregroundStyle(BK.pink.ink).frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Maddeyi sil")
                                    }
                                    Toggle("Zamanı var", isOn: Binding(
                                        get: { handoff.plan.items[i].due != nil },
                                        set: { handoff.plan.items[i].due = $0 ? Self.tomorrowNine : nil }))
                                        .font(.footnote).tint(BK.accent)
                                    if handoff.plan.items[i].due != nil {
                                        DatePicker("Ne zaman", selection: Binding(
                                            get: { handoff.plan.items[i].due ?? Self.tomorrowNine },
                                            set: { handoff.plan.items[i].due = $0 }))
                                            .font(.footnote).environment(\.locale, .turkish)
                                    }
                                }
                                .padding(.vertical, 4)
                                Divider().overlay(BK.line)
                            }
                            Button {
                                handoff.plan.items.append(.init(title: "", due: nil, notes: nil))
                            } label: {
                                Label("Madde ekle", systemImage: "plus").font(.subheadline.weight(.semibold))
                            }
                        }
                        }
                        .disabled(state == .saving)
                        if case let .failed(msg) = state { Text(msg).font(.footnote).foregroundStyle(BK.orange.ink) }
                        Button { Task { await save() } } label: {
                            Text(state == .saving ? "Ekleniyor…" : addLabel).font(.headline)
                                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                                .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(state == .saving || validItems.isEmpty)
                    }
                }
                .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen("Hatırlatıcı")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .task {
            lists = await ReminderMaker.refreshListNames() ?? lists
            // "Ekle" ile geldiyse düzenleme ekranı gösterilmeden ekleniyor.
            if !handoff.edit { await save() }
        }
    }

    private static var tomorrowNine: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
    }

    private var validItems: [AIService.ReminderDraft] {
        handoff.plan.items.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var addLabel: String {
        handoff.destination == .apple && validItems.count > 1 ? "\(validItems.count) maddeyi ekle" : handoff.destination.addTitle
    }

    private var summary: String { MakerText.reminderLines(validItems) }

    private func save() async {
        state = .saving
        // Gönderilen planın kopyası: sonuç ve kalanlar bundan (form o sırada kilitli de olsa).
        let sent = validItems
        do {
            let result = try await TodoRouter.send(AIService.ReminderPlan(list: handoff.plan.list, items: sent),
                                                   to: handoff.destination)
            state = .done(result, count: sent.count)
        } catch let partial as TodoExport.TodoistPartial {
            // Eklenenler (ve sonucu bilinmeyen) listeden çıkıyor: yeniden denemede çift görev olmasın.
            handoff.plan.items = partial.remaining(sent)
            state = .failed(partial.localizedDescription)
        } catch { state = .failed(error.localizedDescription) }
    }
}

#if DEBUG
extension EventHandoff {
    /// `-bkScreen yzetkinlik`: tasarım 32a'daki örnek.
    static var sample: EventHandoff {
        let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 7),
                                              matchingPolicy: .nextTime) ?? Date()
        let plan = AIService.EventPlan(calendar: nil, items: [
            .init(title: "Kadıköy'de buluşma", start: start, end: start.addingTimeInterval(7200),
                  allDay: false, location: "Kadıköy", notes: nil)])
        return EventHandoff(plan: plan, edit: true)
    }
}

extension ContactHandoff {
    /// `-bkScreen yzkisi`: tasarım 32b'deki örnek.
    static var sample: ContactHandoff {
        let d = AIService.ContactDraft(givenName: "Murat", familyName: "Kaya", phones: ["0532 418 77 90"],
                                       emails: ["murat@kayatesisat.com"], organization: "Kaya Tesisat", note: nil)
        return ContactHandoff(draft: d, edit: true)
    }
}
#endif
