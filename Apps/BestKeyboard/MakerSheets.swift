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

/// Ekleme sayfalarının ortak durumu. `Done`: eklendikten sonra gösterilen.
enum MakerPhase<Done: Equatable>: Equatable {
    case editing, saving, done(Done), failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    /// Kaydedilirken ve sonra form kilitli: ekrandaki, kaydedilenle aynı kalsın.
    var locksForm: Bool { self == .saving || isDone }
    var error: String? { if case let .failed(m) = self { return m }; return nil }
    var done: Done? { if case let .done(d) = self { return d }; return nil }
}

/// Altta sabit duran ana düğme (tasarım 32): eklenince yeşil "…’de aç".
private struct MakerButton: View {
    let saving: Bool
    let done: Bool
    let addTitle: String
    let openTitle: String
    let disabled: Bool
    let add: () -> Void
    let open: () -> Void
    var body: some View {
        Button { done ? open() : add() } label: {
            Text(saving ? AddText.saving : done ? openTitle : addTitle)
        }
        .buttonStyle(.bkPrimary(done ? BK.green.ink : BK.accent))
        .disabled(saving || (!done && disabled))
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(BK.ground)
    }
}

/// Ekleme sayfalarının iskeleti: kaydırılan form, altta ana düğme, hata,
/// Vazgeç/Kapat. Etkinlik, kişi ve hatırlatıcı aynı düzen.
private struct MakerScaffold<Done: Equatable, Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let phase: MakerPhase<Done>
    let button: MakerButton
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    if let e = phase.error { BKErrorText(e) }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) { button }
            .foregroundStyle(BK.ink)
            .bkScreen(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .editing || phase == .saving ? "Vazgeç" : "Kapat") { dismiss() }
                }
            }
        }
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
    @State var handoff: EventHandoff
    /// Eklendi (paylaşım eklentisi önizlemeyi günceller).
    var onDone: ((AIService.EventPlan, String) -> Void)? = nil
    @State private var calendars: [EventMaker.Choice] = []
    @State private var calendarID: String?
    @State private var phase: MakerPhase<String> = .editing

    var body: some View {
        MakerScaffold(title: "Etkinlik", phase: phase,
                      button: MakerButton(saving: phase == .saving, done: phase.isDone,
                                          addTitle: AddText.events(handoff.plan.items.count),
                                          openTitle: AddText.openCalendar, disabled: validItems.isEmpty,
                                          add: { Task { await save() } },
                                          open: { URLOpener.launch(AppLinks.calendar(for: handoff.plan)) })) {
            if let cal = phase.done { BKDoneBanner(text: MakerText.eventsTitle(count: validItems.count, calendar: cal)) }
            Group {
                ForEach(handoff.plan.items.indices, id: \.self) { i in item(i) }
                if !calendars.isEmpty { calendarCard }
            }
            .disabled(phase.locksForm)
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
                                                   set: { d.wrappedValue.location = $0.nilIfEmpty }))
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
                    Text(EventMaker.Alarm.text(allDay: d.wrappedValue.allDay)).foregroundStyle(BK.sub)
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

    private var validItems: [AIService.EventDraft] { handoff.plan.items.filter(\.hasTitle) }

    private func save() async {
        phase = .saving
        let plan = AIService.EventPlan(calendar: handoff.plan.calendar, items: validItems)
        do {
            let cal = try await EventMaker.add(plan, calendarID: calendarID)
            phase = .done(cal)
            calendars = EventMaker.calendarChoices()
            onDone?(plan, cal)
        } catch { phase = .failed(error.localizedDescription) }
    }
}

// MARK: - Kişi (32b)

struct ContactSheet: View {
    @State var handoff: ContactHandoff
    /// Eklendi (paylaşım eklentisi önizlemeyi günceller).
    var onDone: ((AIService.ContactDraft, String) -> Void)? = nil
    @State private var phase: MakerPhase<String> = .editing

    var body: some View {
        MakerScaffold(title: "Kişi", phase: phase,
                      button: MakerButton(saving: phase == .saving, done: phase.isDone,
                                          addTitle: AddText.contacts, openTitle: AddText.openContacts, disabled: isEmpty,
                                          add: { Task { await save() } },
                                          open: { URLOpener.launch(AppLinks.contacts) })) {
            BKAvatar(initials: handoff.draft.initials, size: 76).frame(maxWidth: .infinity)
            if let name = phase.done { BKDoneBanner(text: MakerText.contactTitle(name)) }
            Group {
                BKCard(padding: 0) {
                    VStack(spacing: 0) {
                        FieldRow(label: "Ad") { TextField("Ad", text: $handoff.draft.givenName) }
                        Divider().overlay(BK.line)
                        FieldRow(label: "Soyad") { TextField("Soyad", text: $handoff.draft.familyName) }
                        Divider().overlay(BK.line)
                        FieldRow(label: "Kurum") {
                            TextField("Kurum", text: Binding(get: { handoff.draft.organization ?? "" },
                                                             set: { handoff.draft.organization = $0.nilIfEmpty }))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                listCard("Telefonlar", tag: "cep", values: $handoff.draft.phones, add: "Telefon ekle", keyboard: .phonePad)
                listCard("E-postalar", tag: "e-posta", values: $handoff.draft.emails, add: "E-posta ekle", keyboard: .emailAddress)
            }
            .disabled(phase.locksForm)
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
                        BKRemoveButton(label: "\(tag) sil") { values.wrappedValue.remove(at: i) }
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
        let d = cleaned
        do {
            let name = try await ContactMaker.add(d)
            phase = .done(name)
            onDone?(d, name)
        } catch { phase = .failed(error.localizedDescription) }
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
    @State var handoff: ReminderHandoff
    @State private var lists: [String] = AIService.reminderLists
    @State private var phase: MakerPhase<Sent> = .editing

    /// Gönderilenin sonucu: nereye, kaç madde, maddeler.
    struct Sent: Equatable {
        let result: TodoRouter.Result
        let items: [AIService.ReminderDraft]
    }

    var body: some View {
        MakerScaffold(title: "Hatırlatıcı", phase: phase,
                      button: MakerButton(saving: phase == .saving, done: phase.isDone,
                                          addTitle: handoff.destination.addTitle(count: validItems.count),
                                          openTitle: handoff.destination.openTitle, disabled: validItems.isEmpty,
                                          add: { Task { await save() } },
                                          open: { URLOpener.launch(handoff.destination.openURL) })) {
            if let sent = phase.done {
                doneCard(sent)
            } else {
                Group {
                    destinationCard
                    itemsCard
                }
                .disabled(phase.locksForm)
            }
        }
        .task {
            lists = await ReminderMaker.refreshListNames() ?? lists
            // "Ekle" ile geldiyse düzenleme ekranı gösterilmeden ekleniyor.
            if !handoff.edit { await save() }
        }
    }

    private func doneCard(_ sent: Sent) -> some View {
        BKCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(BK.green.ink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(!sent.result.confirmed ? "Gönderildi" : sent.items.count > 1 ? "\(sent.items.count) madde eklendi" : "Eklendi")
                        .font(.headline)
                    Text(MakerText.reminderLines(sent.items)).font(.subheadline).foregroundStyle(BK.sub).lineLimit(3)
                }
            }
            Text(sent.result.confirmed ? "\(sent.result.place). \(CommonText.backToChat)."
                 : "\(sent.result.place) açıldı; maddelerin orada göründüğünü kontrol et (ilk kullanımda izin isteyebilir).")
                .font(.footnote).foregroundStyle(BK.sub)
        }
    }

    private var destinationCard: some View {
        BKCard {
            BKFieldLabel("Nereye")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TodoDestination.allCases, id: \.self) { d in
                        BKChip(title: d.title, on: handoff.destination == d) {
                            handoff.destination = d
                            TodoDestination.current = d
                        }
                        .opacity(d.isAvailable ? 1 : 0.45)
                    }
                }
            }
            if let note = handoff.destination.unavailableNote {
                Text(note).font(.caption).foregroundStyle(BK.orange.ink)
            }
            BKFieldLabel("Liste")
            Picker("Liste", selection: Binding(get: { handoff.plan.list ?? "" },
                                              set: { handoff.plan.list = $0.nilIfEmpty })) {
                Text("Varsayılan liste").tag("")
                ForEach(lists, id: \.self) { Text($0).tag($0) }
                // Önerilen yeni liste (henüz yok) da seçenek; eklenince açılıyor.
                if let l = handoff.plan.list, !lists.contains(l) { Text("\(l) (yeni liste)").tag(l) }
            }
            .pickerStyle(.menu).tint(BK.accent)
        }
    }

    private var itemsCard: some View {
        BKCard(padding: 16) {
            BKFieldLabel("Maddeler")
            ForEach(handoff.plan.items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle").foregroundStyle(BK.accent)
                        TextField("Madde", text: $handoff.plan.items[i].title)
                            .font(.body.weight(.semibold))
                        BKRemoveButton(label: "Maddeyi sil") { handoff.plan.items.remove(at: i) }
                    }
                    Toggle("Zamanı var", isOn: Binding(
                        get: { handoff.plan.items[i].due != nil },
                        set: { handoff.plan.items[i].due = $0 ? Self.tomorrowMorning : nil }))
                        .font(.footnote).tint(BK.accent)
                    if handoff.plan.items[i].due != nil {
                        DatePicker("Ne zaman", selection: Binding(
                            get: { handoff.plan.items[i].due ?? Self.tomorrowMorning },
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

    /// Zaman açılınca önerilen: yarın, etkinlik uyarısıyla aynı saat.
    private static var tomorrowMorning: Date {
        Calendar.current.date(bySettingHour: EventMaker.Alarm.allDayHour, minute: 0, second: 0,
                              of: Date().addingTimeInterval(86_400)) ?? Date()
    }

    private var validItems: [AIService.ReminderDraft] { handoff.plan.items.filter(\.hasTitle) }

    private func save() async {
        phase = .saving
        // Gönderilen planın kopyası: sonuç ve kalanlar bundan (form o sırada kilitli de olsa).
        let sent = validItems
        do {
            let result = try await TodoRouter.send(AIService.ReminderPlan(list: handoff.plan.list, items: sent),
                                                   to: handoff.destination)
            phase = .done(Sent(result: result, items: sent))
        } catch let partial as TodoExport.TodoistPartial {
            // Eklenenler (ve sonucu bilinmeyen) listeden çıkıyor: yeniden denemede çift görev olmasın.
            handoff.plan.items = partial.remaining(sent)
            phase = .failed(partial.localizedDescription)
        } catch { phase = .failed(error.localizedDescription) }
    }
}

/// Örnek veri — tuş düzenleyicisindeki örnek mesajlar, tasarım karşılaştırma
/// ekranları ve öz-testler aynı buluşmayı ve aynı kişiyi kullanıyor.
enum SampleData {
    static let meetingMessage = "Cumartesi akşam 7'de Kadıköy'de buluşalım, 2 saat kadar otururuz"
    static let contactMessage = "Tesisatçının numarası: Murat Kaya 0532 418 77 90, mail murat@kayatesisat.com"
    static let reminderMessage = "Cumartesi annen gelecek, akşam otogardan alacaksın. 8 yumurta, 5 kedi maması al."

    /// Gelecek cumartesi 19:00.
    static var saturdayEvening: Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 7),
                                  matchingPolicy: .nextTime) ?? Date()
    }

    static var meeting: AIService.EventDraft {
        let start = saturdayEvening
        return .init(title: "Kadıköy'de buluşma", start: start, end: start.addingTimeInterval(7200),
                     allDay: false, location: "Kadıköy", notes: nil)
    }

    static let contact = AIService.ContactDraft(givenName: "Murat", familyName: "Kaya", phones: ["0532 418 77 90"],
                                                emails: ["murat@kayatesisat.com"], organization: "Kaya Tesisat", note: nil)
}

#if DEBUG
extension EventHandoff {
    /// `-bkScreen yzetkinlik`: tasarım 32a'daki örnek.
    static var sample: EventHandoff { EventHandoff(plan: .init(calendar: nil, items: [SampleData.meeting]), edit: true) }
}

extension ContactHandoff {
    /// `-bkScreen yzkisi`: tasarım 32b'deki örnek.
    static var sample: ContactHandoff { ContactHandoff(draft: SampleData.contact, edit: true) }
}
#endif
