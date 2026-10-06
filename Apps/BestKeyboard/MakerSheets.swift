import EventKit
import SwiftUI

// Klavyenin ✦ kartından gelen Takvim etkinliği ve kişi kartı (tasarım 28, 29,
// 32) ve Yapay zeka tuşlarındaki "Bağlantılar" kartı (tasarım 31).

/// `bestkeyboard://<host>?id=<App Group kimliği>[&edit=1]` (klavyeden) ya da
/// satır içi `<param>=<base64 JSON>` — ikincisi her zaman onay ekranıyla açılır.
private func decodeHandoff<T: Decodable>(_ url: URL, host: String, param: String) -> (T, Bool)? {
    guard let p = Handoff.payload(from: url, host: host, param: param),
          let value = try? JSONDecoder().decode(T.self, from: p.data) else { return nil }
    return (value, p.edit)
}

struct EventHandoff: Identifiable {
    let id = UUID()
    var plan: AIService.EventPlan
    var edit: Bool
    init?(url: URL) {
        guard let (p, e): (AIService.EventPlan, Bool) = decodeHandoff(url, host: "etkinlik", param: "plan"),
              !p.items.isEmpty else { return nil }
        plan = p; edit = e
    }
}

struct ContactHandoff: Identifiable {
    let id = UUID()
    var draft: AIService.ContactDraft
    var edit: Bool
    init?(url: URL) {
        guard let (d, e): (AIService.ContactDraft, Bool) = decodeHandoff(url, host: "kisi", param: "kisi") else { return nil }
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
                    if case let .done(cal) = phase { DoneBanner(text: "Takvime eklendi · \(cal)") }
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
                                if let url = URL(string: "calshow:\(t)") { UIApplication.shared.open(url) }
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
            .environment(\.locale, Locale(identifier: "tr_TR"))
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
        [handoff.draft.givenName, handoff.draft.familyName].compactMap(\.first).map(String.init).joined().uppercased()
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
                    if case let .done(name) = phase { DoneBanner(text: "Kişilere eklendi · \(name)") }
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
                            open: { if let url = URL(string: "contacts://") { UIApplication.shared.open(url) } })
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

// MARK: - Bağlantılar (31)

struct IntegrationsCard: View {
    @State private var tokenSaved = TodoExport.todoistToken != nil
    @State private var token = ""
    @State private var installed = TodoDestination.installed

    var body: some View {
        BKCard(padding: 16) {
            BKSectionTitle(text: "Bağlantılar", color: BK.accent)
            Text("Hatırlatıcı tuşu maddeleri buralara da gönderebilir.")
                .font(.footnote).foregroundStyle(BK.sub)

            Divider().overlay(BK.line)
            HStack(spacing: 12) {
                BKIcon(systemName: "square.stack.3d.up", tint: BK.pink, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Todoist").font(.body.weight(.semibold))
                    Text(tokenSaved ? "Token kayıtlı ✓ · Gelen Kutusu" : "Bağlı değil")
                        .font(.footnote).foregroundStyle(tokenSaved ? BK.green.ink : BK.sub)
                }
                Spacer()
                if tokenSaved {
                    Button {
                        TodoExport.setTodoistToken(nil)
                        tokenSaved = false
                    } label: {
                        Text("Sil").font(.subheadline.weight(.bold)).foregroundStyle(BK.pink.ink)
                            .padding(.horizontal, 14).frame(height: 36).background(BK.pink.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !tokenSaved {
                HStack(spacing: 8) {
                    SecureField("API token’ını yapıştır", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    Button {
                        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        tokenSaved = TodoExport.setTodoistToken(t)
                        token = ""
                    } label: {
                        Text("Kaydet").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(BK.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Todoist › Ayarlar › Entegrasyonlar › Geliştirici. Token yalnızca bu telefonun anahtarlığında durur.")
                    .font(.caption).foregroundStyle(BK.sub)
            }

            appRow(.things, note: "Liste adına göre yerleşir", tint: BK.blue)
            appRow(.ticktick, note: "Maddeler tek tek gönderilir", tint: BK.teal)
        }
        .onAppear { installed = TodoDestination.refreshInstalled() }
    }

    private func appRow(_ d: TodoDestination, note: String, tint: BK.Tint) -> some View {
        let ok = installed.contains(d)
        return VStack(spacing: 0) {
            Divider().overlay(BK.line)
            HStack(spacing: 12) {
                BKIcon(systemName: "checkmark", tint: ok ? tint : BK.Tint(ink: BK.sub, chip: BK.line), size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.title).font(.body.weight(.semibold))
                    Text(note).font(.footnote).foregroundStyle(BK.sub)
                }
                Spacer()
                Text(ok ? "Yüklü" : "Yüklü değil").font(.footnote.weight(.bold))
                    .foregroundStyle(ok ? BK.green.ink : BK.sub)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(ok ? BK.green.chip : BK.line, in: Capsule())
            }
            .frame(minHeight: 60)
        }
    }
}

extension TodoDestination {
    /// Uygulama açıkken yüklü yapılacaklar uygulamalarını yazar (klavye soramıyor).
    @discardableResult
    static func refreshInstalled() -> Set<TodoDestination> {
        let set = Set(allCases.filter { d in
            d.scheme.flatMap { URL(string: "\($0)://") }.map(UIApplication.shared.canOpenURL) ?? false
        })
        installed = set
        return set
    }

    /// Eklendikten sonra "…’de aç".
    var openURL: URL? {
        switch self {
        case .apple: return URL(string: "x-apple-reminderkit://")
        case .things: return URL(string: "things:///show?id=today")
        case .todoist: return URL(string: "todoist://")
        case .ticktick: return URL(string: "ticktick://")
        }
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
        let data = (try? JSONEncoder().encode(plan))?.base64EncodedString() ?? ""
        var c = URLComponents(string: "bestkeyboard://etkinlik")!
        c.queryItems = [URLQueryItem(name: "plan", value: data), URLQueryItem(name: "edit", value: "1")]
        return EventHandoff(url: c.url!)!
    }
}

extension ContactHandoff {
    /// `-bkScreen yzkisi`: tasarım 32b'deki örnek.
    static var sample: ContactHandoff {
        let d = AIService.ContactDraft(givenName: "Murat", familyName: "Kaya", phones: ["0532 418 77 90"],
                                       emails: ["murat@kayatesisat.com"], organization: "Kaya Tesisat", note: nil)
        let data = (try? JSONEncoder().encode(d))?.base64EncodedString() ?? ""
        var c = URLComponents(string: "bestkeyboard://kisi")!
        c.queryItems = [URLQueryItem(name: "kisi", value: data), URLQueryItem(name: "edit", value: "1")]
        return ContactHandoff(url: c.url!)!
    }
}
#endif
