import EventKit
import SwiftUI

// Klavyenin ✦ kartından gelen Takvim etkinliği ve kişi kartı (tasarım 28, 29,
// 32) ve Yapay zeka tuşlarındaki "Bağlantılar" kartı (tasarım 31).

/// Ekleme sayfalarının ortak durumu. `Done`: eklendikten sonra gösterilen.
enum MakerPhase<Done: Equatable>: Equatable {
    case editing, saving, done(Done), failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    /// Kaydedilirken ve sonra form kilitli: ekrandaki, kaydedilenle aynı kalsın.
    var locksForm: Bool { self == .saving || isDone }
    var error: String? { if case let .failed(m) = self { return m }; return nil }
    var done: Done? { if case let .done(d) = self { return d }; return nil }

    /// Kaydetme akışı — üç sayfa aynı sıra: kaydediliyor → eklendi ya da olmadı.
    @MainActor
    static func run(_ phase: Binding<MakerPhase>, _ work: () async throws -> Done) async {
        phase.wrappedValue = .saving
        do { phase.wrappedValue = .done(try await work()) }
        catch { phase.wrappedValue = .failed(error.localizedDescription) }
    }
}

/// Altta sabit duran ana düğme (tasarım 32): eklenince yeşil "…’de aç".
private struct MakerButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.semibold) : .headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .buttonStyle(.bkPrimary(done ? BK.green.ink : BK.accent))
        .accessibilityIdentifier("maker.primary")
        .disabled(saving || (!done && disabled))
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(BK.ground)
    }
}

/// Ekleme sayfalarının iskeleti: kaydırılan form, altta ana düğme, hata,
/// Vazgeç/Kapat. Etkinlik, kişi ve hatırlatıcı aynı düzen.
private struct MakerScaffold<Done: Equatable, Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var keyboardVisible = false
    let title: String
    let phase: MakerPhase<Done>
    let button: MakerButton
    var focusedField: String? = nil
    var dismissKeyboard: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                BKScreen(title) {
                    content
                    if let e = phase.error { BKErrorText(e) }
                }
                .safeAreaInset(edge: .bottom) {
                    if !dynamicTypeSize.isAccessibilitySize || !keyboardVisible { button }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    keyboardVisible = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                    keyboardVisible = false
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    if let focusedField { proxy.scrollTo(focusedField, anchor: .center) }
                }
                .onChange(of: focusedField) { _, field in
                    if keyboardVisible, let field { proxy.scrollTo(field, anchor: .center) }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if let dismissKeyboard {
                            Spacer()
                            Button("Bitti", action: dismissKeyboard)
                                .accessibilityLabel("Klavyeyi kapat")
                                .accessibilityIdentifier("maker.dismissKeyboard")
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(phase == .editing || phase == .saving ? "Vazgeç" : "Kapat") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct FieldRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Text(label).font(.footnote).foregroundStyle(BK.sub)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 64, alignment: .leading)
            content
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .frame(minHeight: 46)
    }
}

// MARK: - Etkinlik (32a)

struct EventSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                TextField("Başlık", text: d.title, axis: .vertical).font(.headline).frame(minHeight: 50)
                    .accessibilityLabel("Başlık")
                BKDivider()
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 20)).foregroundStyle(BK.sub)
                    TextField("Yer", text: d.location.orEmpty)
                }
                .frame(minHeight: 46)
            }
            .padding(.horizontal, 16)
        }
        BKCard(padding: 0) {
            VStack(spacing: 0) {
                Toggle("Tüm gün", isOn: d.allDay).tint(BK.green.ink).frame(minHeight: 50)
                BKDivider()
                dateField("Başlangıç", selection: Binding(get: { d.wrappedValue.start }, set: { new in
                    let len = (d.wrappedValue.end ?? new).timeIntervalSince(d.wrappedValue.start)
                    d.wrappedValue.start = new
                    d.wrappedValue.end = new.addingTimeInterval(max(len, 0))
                }), allDay: d.wrappedValue.allDay)
                BKDivider()
                dateField("Bitiş", selection: Binding(get: { d.wrappedValue.end ?? d.wrappedValue.start },
                                                       set: { d.wrappedValue.end = $0 }),
                          allDay: d.wrappedValue.allDay, earliest: d.wrappedValue.start)

                BKDivider()
                let alarmLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout())
                alarmLayout {
                    Text("Uyarı")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text(EventMaker.Alarm.text(allDay: d.wrappedValue.allDay)).foregroundStyle(BK.sub)
                }
                .frame(minHeight: 50)
            }
            .padding(.horizontal, 16)
            .environment(\.locale, .turkish)
        }
    }

    @ViewBuilder private func dateField(_ title: String, selection: Binding<Date>, allDay: Bool,
                                        earliest: Date = .distantPast) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                DatePicker(title, selection: selection, in: earliest..., displayedComponents: .date)
                    .labelsHidden()
                if !allDay {
                    DatePicker(title + " saati", selection: selection, in: earliest..., displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            DatePicker(title, selection: selection, in: earliest...,
                       displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                .frame(minHeight: 50)
        }
    }

    private var calendarCard: some View {
        BKCard(padding: 16) {
            BKSectionTitle(text: "Takvim", color: BK.accent)
            ForEach(calendars) { c in
                let on = calendarID == c.id
                let twin = calendars.filter { $0.title == c.title }.count > 1
                VStack(spacing: 0) {
                    BKDivider()
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
        let plan = AIService.EventPlan(calendar: handoff.plan.calendar, items: validItems)
        await MakerPhase.run($phase) {
            let cal = try await EventMaker.add(plan, calendarID: calendarID)
            calendars = EventMaker.calendarChoices()
            onDone?(plan, cal)
            return cal
        }
    }
}

// MARK: - Kişi (32b)

struct ContactSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: String?
    @State var handoff: ContactHandoff
    /// Eklendi (paylaşım eklentisi önizlemeyi günceller).
    var onDone: ((AIService.ContactDraft, String) -> Void)? = nil
    @State private var phase: MakerPhase<String> = .editing

    var body: some View {
        MakerScaffold(title: "Kişi", phase: phase,
                      button: MakerButton(saving: phase == .saving, done: phase.isDone,
                                          addTitle: AddText.contacts, openTitle: AddText.openContacts, disabled: isEmpty,
                                          add: { Task { await save() } },
                                          open: { URLOpener.launch(AppLinks.contacts) }), focusedField: focusedField, dismissKeyboard: { focusedField = nil }) {
            BKAvatar(initials: handoff.draft.initials, size: 76).frame(maxWidth: .infinity)
            if let name = phase.done { BKDoneBanner(text: MakerText.contactTitle(name)) }
            Group {
                BKCard(padding: 0) {
                    VStack(spacing: 0) {
                        FieldRow(label: "Ad") { TextField("Ad", text: $handoff.draft.givenName).focused($focusedField, equals: "contact.given").id("contact.given") }
                        BKDivider()
                        FieldRow(label: "Soyad") { TextField("Soyad", text: $handoff.draft.familyName).focused($focusedField, equals: "contact.family").id("contact.family") }
                        BKDivider()
                        FieldRow(label: "Kurum") {
                            TextField("Kurum", text: $handoff.draft.organization.orEmpty).focused($focusedField, equals: "contact.organization").id("contact.organization")
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
                    BKDivider()
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        HStack {
                            BKRemoveButton(label: "\(tag) sil") { values.wrappedValue.remove(at: i) }
                            Text(tag).font(.footnote).foregroundStyle(BK.sub)
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 52, alignment: .leading)
                        }
                        TextField(tag, text: values[i]).keyboardType(keyboard).textInputAutocapitalization(.never)
                            .focused($focusedField, equals: "contact.\(tag).\(i)").id("contact.\(tag).\(i)")
                    }
                    .frame(minHeight: 46)
                }
            }
            BKDivider()
            Button { values.wrappedValue.append("") } label: {
                Label(add, systemImage: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(BK.accent)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var cleaned: AIService.ContactDraft {
        var d = handoff.draft
        d.givenName = d.givenName.trimmed
        d.familyName = d.familyName.trimmed
        d.phones = d.phones.map { $0.trimmed }.filter { !$0.isEmpty }
        d.emails = d.emails.map { $0.trimmed }.filter { !$0.isEmpty }
        return d
    }

    private var isEmpty: Bool {
        let d = cleaned
        return d.displayName.isEmpty && d.phones.isEmpty && d.emails.isEmpty
    }

    private func save() async {
        let d = cleaned
        await MakerPhase.run($phase) {
            let name = try await ContactMaker.add(d)
            onDone?(d, name)
            return name
        }
    }
}

// MARK: - Klavyeden gelen işler

struct ReminderSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: String?
    @State var handoff: ReminderHandoff
    @State private var itemIDs: [UUID]
    @State private var lists: [String] = AIService.reminderLists
    @State private var phase: MakerPhase<Sent> = .editing

    /// Gönderilenin sonucu: nereye, kaç madde, maddeler.
    struct Sent: Equatable {
        let result: TodoRouter.Result
        let items: [AIService.ReminderDraft]
    }

    init(handoff: ReminderHandoff) {
        _handoff = State(initialValue: handoff)
        _itemIDs = State(initialValue: handoff.plan.items.map { _ in UUID() })
    }

    // Silinen satırın kontrolleri kapanırken eski bağlantıyı okuyabilir.
    // Kimlikle ara; kaldırılmış satıra gelen gecikmiş yazmaları yok say.
    private func itemBinding(_ id: UUID, fallback: AIService.ReminderDraft) -> Binding<AIService.ReminderDraft> {
        Binding(get: {
            guard let index = itemIDs.firstIndex(of: id), handoff.plan.items.indices.contains(index) else { return fallback }
            return handoff.plan.items[index]
        }, set: { value in
            guard let index = itemIDs.firstIndex(of: id), handoff.plan.items.indices.contains(index) else { return }
            handoff.plan.items[index] = value
        })
    }

    var body: some View {
        MakerScaffold(title: "Hatırlatıcı", phase: phase,
                      button: MakerButton(saving: phase == .saving, done: phase.isDone,
                                          addTitle: handoff.destination.addTitle(count: validItems.count),
                                          openTitle: handoff.destination.openTitle, disabled: validItems.isEmpty,
                                          add: { Task { await save() } },
                                          open: { URLOpener.launch(handoff.destination.openURL) }),
                      focusedField: focusedField, dismissKeyboard: { focusedField = nil }) {
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
            Menu {
                Picker("Liste", selection: $handoff.plan.list.orEmpty) {
                    Text("Varsayılan liste").tag("")
                    ForEach(lists, id: \.self) { Text($0).tag($0) }
                    // Önerilen yeni liste (henüz yok) da seçenek; eklenince açılıyor.
                    if let l = handoff.plan.list, !lists.contains(l) { Text("\(l) (yeni liste)").tag(l) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(handoff.plan.list.flatMap { $0.isEmpty ? nil : $0 } ?? "Varsayılan liste")
                        .font(.footnote).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .tint(BK.accent)
            .accessibilityLabel("Liste")
            .accessibilityValue(handoff.plan.list.flatMap { $0.isEmpty ? nil : $0 } ?? "Varsayılan liste")
        }
    }

    private var itemsCard: some View {
        BKCard(padding: 16) {
            BKFieldLabel("Maddeler")
            ForEach(itemIDs, id: \.self) { id in
                if let i = itemIDs.firstIndex(of: id), handoff.plan.items.indices.contains(i) {
                    let draft = itemBinding(id, fallback: handoff.plan.items[i])
                    VStack(alignment: .leading, spacing: 6) {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 10))
                        layout {
                            if !dynamicTypeSize.isAccessibilitySize {
                                Image(systemName: "circle").font(.system(size: 18)).foregroundStyle(BK.accent)
                            }
                            TextField("Madde", text: draft.title, axis: .vertical)
                                .font(.body.weight(.semibold))
                                .accessibilityLabel("Madde")
                                .focused($focusedField, equals: id.uuidString).id(id.uuidString)
                            BKRemoveButton(label: "Maddeyi sil") {
                                if focusedField == id.uuidString { focusedField = nil }
                                guard let index = itemIDs.firstIndex(of: id) else { return }
                                handoff.plan.items.remove(at: index)
                                itemIDs.remove(at: index)
                            }
                        }
                        Toggle("Zamanı var", isOn: Binding(
                            get: { draft.wrappedValue.due != nil },
                            set: { draft.wrappedValue.due = $0 ? Self.tomorrowMorning : nil }))
                            .font(.footnote).tint(BK.accent)
                        if draft.wrappedValue.due != nil {
                            let due = Binding(
                                get: { draft.wrappedValue.due ?? Self.tomorrowMorning },
                                set: { draft.wrappedValue.due = $0 })
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Ne zaman").font(.footnote)
                                    DatePicker("Tarih", selection: due, displayedComponents: .date).labelsHidden()
                                    DatePicker("Saat", selection: due, displayedComponents: .hourAndMinute).labelsHidden()
                                }
                                .environment(\.locale, .turkish)
                            } else {
                                DatePicker("Ne zaman", selection: due)
                                .font(.footnote).environment(\.locale, .turkish)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    BKDivider()
                }
            }
            Button {
                handoff.plan.items.append(.init(title: "", due: nil, notes: nil))
                itemIDs.append(UUID())
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
        // Gönderilen planın kopyası: sonuç ve kalanlar bundan (form o sırada kilitli de olsa).
        let sent = validItems
        await MakerPhase.run($phase) {
            do {
                let result = try await TodoRouter.send(AIService.ReminderPlan(list: handoff.plan.list, items: sent),
                                                       to: handoff.destination)
                return Sent(result: result, items: sent)
            } catch let partial as TodoExport.TodoistPartial {
                // Eklenenler (ve sonucu bilinmeyen) listeden çıkıyor: yeniden denemede çift görev olmasın.
                handoff.plan.items = partial.remaining(sent)
                throw partial
            }
        }
    }
}
