import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Paylaşım listesindeki "BestKeyboard ✦" (tasarım 33–35): paylaşılan mesaj,
// bağlantı ya da resim yapay zeka tuşlarıyla işleniyor. Klavyeden farkı:
// eylem eklentisi Takvim / Hatırlatıcılar / Kişiler'e kendisi yazabiliyor,
// uygulamaya geçmek gerekmiyor.

final class ActionViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKPalette.ground.ui
        AILog.prepare()
        URLOpener.open = { [weak self] url in self?.bkOpenURL(url) ?? false }
        // Eklenti `canOpenURL` soramıyor: uygulamanın yazdığı "yüklü" listesi.
        URLOpener.canOpen = { url in
            TodoDestination.allCases.first { $0.scheme == url.scheme }.map(TodoDestination.installed.contains) ?? true
        }
        TodoRouter.handOffToApp = { [weak self] plan, dest in
            guard let self, let json = try? JSONEncoder().encode(plan),
                  let link = Handoff.link(.reminder, payload: json, edit: false,
                                          extra: [URLQueryItem(name: DeepLink.Param.destination, value: dest.rawValue)])
            else { return false }
            if self.bkOpenURL(link.url) { return true }
            if let id = link.id { Handoff.purge(id) }
            return false
        }
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }

        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(items) }
    }

}

// MARK: - Durum

@MainActor @Observable
final class ShareModel {
    enum Phase {
        case reading
        case pick
        case working(String)
        case text(String)
        case image(UIImage)
        case event(AIService.EventPlan, added: String?)
        case contact(AIService.ContactDraft, added: String?)
        case failed(String)
    }

    var phase: Phase = .reading
    /// Paylaşılan metin (resimse içinden okunan yazı).
    var text = ""
    var thumbnail: UIImage?
    /// Kartta ve günlükte aynı etiket.
    var sourceLabel: String { thumbnail != nil ? AILog.Source.sharedImage : AILog.Source.sharedText }
    var actions: [AIAction] = KeyboardSettingsStore.aiActions()
    var current: AIAction?
    /// Düzenleme ve hatırlatıcı sayfaları.
    var editEvent: EventHandoff?
    var editContact: ContactHandoff?
    var reminder: ReminderHandoff?
    var copied = false
    var finish: () -> Void = {}

    private var task: Task<Void, Never>?
    /// İş akışı kuşağı: her tuş çalıştırması yeni bir akış. Kapatılmış eski
    /// bir sayfanın geç gelen sonucu yeni akışın önizlemesini ezmesin.
    private(set) var flow = 0

    /// Sayfada eklenen önizlemeye işleniyor — yalnız ait olduğu akış hâlâ güncelse.
    func sheetDidAdd(_ result: Phase, flow: Int) {
        guard flow == self.flow else { return }
        phase = result
    }

    func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        for item in items {
            if let t = item.attributedContentText?.string, !t.isEmpty { texts.append(t) }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !u.isFileURL {
                    texts.append(u.absoluteString)
                } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let img = await Self.image(from: p) {
                    thumbnail = img
                    if let ocr = await TextRecognizer.text(in: img), !ocr.isEmpty { texts.append(ocr) }
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(s)
                }
            }
        }
        // Aynı metin hem başlıkta hem ekte gelebiliyor.
        var seen = Set<String>()
        text = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        phase = .pick
    }

    private static func image(from p: NSItemProvider) async -> UIImage? {
        let item = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier)
        if let img = item as? UIImage { return img }
        if let d = item as? Data { return UIImage(data: d) }
        if let u = item as? URL, let d = try? Data(contentsOf: u) { return UIImage(data: d) }
        return nil
    }

    func run(_ a: AIAction) {
        flow += 1
        current = a
        copied = false
        let source = text
        guard !source.isEmpty || a.kind == .image else {
            phase = .failed("Paylaşılanda yazı bulunamadı.")
            return
        }
        // Kestirme hedefli tuş: kestirmeyi metinle çalıştır, sonuç uygulamaya döner.
        if a.target == AIAction.shortcut { launchExternally(a, text: source); return }
        #if DEBUG
        let selfTest = source.contains("BK-SELFTEST-EVENT")
        #else
        let selfTest = false
        #endif
        guard AIService.isConnected || selfTest else {
            // Servis yoksa metin tuşu uygulamasında (ChatGPT…) istemle açılıyor.
            if !a.kind.isStructured { launchExternally(a, text: source); return }
            phase = .failed(AIService.Failure.noKey.localizedDescription)
            return
        }
        #if DEBUG
        // UI testi: modelsiz, sabit plan — eklentinin Takvim'e kendisi yazabildiğini doğruluyor.
        if a.kind == .event, source.contains("BK-SELFTEST-EVENT") {
            let start = Date().addingTimeInterval(3 * 86_400)
            phase = .event(AIService.EventPlan(calendar: nil, items: [
                .init(title: "Paylaşım testi \(source.suffix(6))", start: start, end: start.addingTimeInterval(3600),
                      allDay: false, location: "Kadıköy", notes: nil)]), added: nil)
            return
        }
        #endif
        phase = .working(a.workingText)
        task?.cancel()
        let label = sourceLabel
        task = Task {
            do {
                switch a.kind {
                case .event, .contact, .reminder:
                    let e = try await AIService.extract(a.kind, from: source, template: a.prompt,
                                                        origin: .share, action: a.name, source: label).value
                    switch e {
                    case let .events(p): phase = .event(p, added: nil)
                    case let .contact(d): phase = .contact(d, added: nil)
                    case let .reminders(plan):
                        phase = .pick
                        reminder = ReminderHandoff(plan: plan, edit: true, destination: TodoDestination.current)
                    }
                case .image, .text:
                    let out = try await AIService.run(a, prompt: a.render(text: source, clipboard: nil),
                                                      origin: .share, source: label, text: source).value
                    phase = out.image.map(Phase.image) ?? .text(out.text ?? "")
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Kestirme ya da sohbet uygulaması — klavyeyle aynı kural (`AIAction.externalLaunch`).
    private func launchExternally(_ a: AIAction, text: String) {
        do {
            let launch = try a.externalLaunch(text: text, clipboard: nil)
            if let copy = launch.pasteboard { UIPasteboard.general.string = copy }
            Task { _ = await URLOpener.open(launch.url); finish() }
        } catch { phase = .failed(error.localizedDescription) }
    }

    func back() {
        task?.cancel()
        phase = .pick
    }

    /// Ekleme sürerken önizleme "Ekleniyor…" — düğme bir daha basılamıyor
    /// (çift dokunuş iki kayıt açıyordu).
    func addEvent(_ plan: AIService.EventPlan) {
        add { .event(plan, added: try await EventMaker.add(plan, notify: false)) }
    }

    func addContact(_ d: AIService.ContactDraft) {
        add { .contact(d, added: try await ContactMaker.add(d, notify: false)) }
    }

    private func add(_ work: @escaping () async throws -> Phase) {
        phase = .working(AddText.saving)
        let flow = self.flow
        Task {
            let result: Phase
            do { result = try await work() } catch { result = .failed(error.localizedDescription) }
            sheetDidAdd(result, flow: flow)
        }
    }
}

// MARK: - Görünüm

struct ShareRootView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isPick {
                        Button("Vazgeç") { model.finish() }
                    } else {
                        Button { model.back() } label: { Label("Tuşlar", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                    }
                }
            }
        }
        .tint(BK.accent)
        .sheet(item: $model.reminder) { r in ReminderSheet(handoff: r) }
        // Sayfada eklenen önizlemeye de işleniyor: kart "Takvime ekle"de kalıyor
        // ve ikinci kez eklenebiliyordu.
        .sheet(item: $model.editEvent) { e in
            let flow = model.flow
            EventSheet(handoff: e) { plan, cal in model.sheetDidAdd(.event(plan, added: cal), flow: flow) }
        }
        .sheet(item: $model.editContact) { c in
            let flow = model.flow
            ContactSheet(handoff: c) { d, name in model.sheetDidAdd(.contact(d, added: name), flow: flow) }
        }
    }

    private var isPick: Bool {
        switch model.phase { case .pick, .reading: return true; default: return false }
    }

    private var title: String { isPick ? "BestKeyboard ✦" : (model.current?.name ?? "BestKeyboard ✦") }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 140)
        case .pick:
            sourceCard
            keyGrid
            Text("Tuşlar Yapay zeka tuşlarındakiyle aynı. Takvim, Hatırlatıcı ve Kişi burada doğrudan eklenir; uygulamaya geçmezsin.")
                .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
        case let .working(text):
            BKCard {
                VStack(spacing: 12) {
                    ProgressView().tint(BK.accent)
                    Text(text).font(.subheadline).foregroundStyle(BK.sub)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }
        case let .text(result):
            BKCard {
                BKSectionTitle(text: "Sonuç", color: BK.accent)
                Text(result).font(.body).textSelection(.enabled)
            }
            buttons(primary: model.copied ? "Kopyalandı" : "Kopyala", primaryAction: {
                UIPasteboard.general.string = result
                model.copied = true
            }, secondary: "Bitti", secondaryAction: model.finish)
            doneNote
        case let .image(img):
            BKCard {
                Image(uiImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Üretilen resim")
            }
            buttons(primary: model.copied ? "Kopyalandı" : "Kopyala", primaryAction: {
                UIPasteboard.general.image = img
                model.copied = true
            }, secondary: "Bitti", secondaryAction: model.finish)
        case let .event(plan, added):
            if let added { BKDoneBanner(text: MakerText.eventsTitle(count: plan.items.count, calendar: added) + " · uyarı kuruldu") }
            ForEach(plan.items.indices, id: \.self) { i in eventCard(plan.items[i], calendar: i == 0 ? plan.calendar : nil) }
            if added == nil {
                buttons(primary: AddText.events(plan.items.count), primaryAction: { model.addEvent(plan) },
                        secondary: AddText.edit, secondaryAction: { model.editEvent = EventHandoff(plan: plan, edit: true) })
            } else {
                buttons(primary: "Bitti", primaryAction: model.finish, secondary: AddText.openCalendar, secondaryAction: {
                    URLOpener.launch(AppLinks.calendar(for: plan))
                })
                doneNote
            }
        case let .contact(d, added):
            if let added { BKDoneBanner(text: MakerText.contactTitle(added)) }
            contactCard(d)
            if added == nil {
                buttons(primary: AddText.contacts, primaryAction: { model.addContact(d) },
                        secondary: AddText.edit, secondaryAction: { model.editContact = ContactHandoff(draft: d, edit: true) })
            } else {
                buttons(primary: "Bitti", primaryAction: model.finish, secondary: AddText.openContacts, secondaryAction: {
                    URLOpener.launch(AppLinks.contacts)
                })
                doneNote
            }
        case let .failed(msg):
            BKCard {
                Text("Olmadı").font(.headline)
                Text(msg).font(.subheadline).foregroundStyle(BK.sub)
            }
            buttons(primary: "Geri", primaryAction: model.back, secondary: "Kapat", secondaryAction: model.finish)
        }
    }

    private var sourceCard: some View {
        BKCard {
            BKSectionTitle(text: model.sourceLabel, color: BK.accent)
            HStack(alignment: .top, spacing: 12) {
                if let img = model.thumbnail {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(model.text.isEmpty ? (model.thumbnail != nil ? "Resimde okunabilen yazı yok" : "Yazı yok")
                                        : "“\(model.text)”")
                    .font(.subheadline).foregroundStyle(BK.sub).lineLimit(5)
            }
        }
    }

    private var keyGrid: some View {
        BKCard {
            BKSectionTitle(text: "Ne yapayım?", color: BK.accent)
            // Ekleyen tuşlar (Takvim, Hatırlatıcı, Kişi) önde: paylaşımın asıl işi.
            let ordered = model.actions.filter(\.kind.isStructured) + model.actions.filter { !$0.kind.isStructured }
            BKActionKeyGrid(actions: ordered, isOn: \.kind.isStructured) { model.run($0) }
        }
    }

    private func eventCard(_ d: AIService.EventDraft, calendar: String?) -> some View {
        BKCard {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(BK.blue.ink).frame(width: 4)
                VStack(alignment: .leading, spacing: 8) {
                    if let calendar { Text("Takvim: \(calendar)").font(.caption.weight(.bold)).foregroundStyle(BK.blue.ink) }
                    Text(d.title).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        chip(d.trWhen)
                        if let dur = d.trDuration { chip(dur) }
                    }
                    if let loc = d.location {
                        Label(loc, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(BK.sub)
                    }
                }
            }
        }
    }

    private func contactCard(_ d: AIService.ContactDraft) -> some View {
        BKCard {
            HStack(spacing: 12) {
                BKAvatar(initials: d.initials)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.displayName.nilIfEmpty ?? AIService.ContactDraft.unnamed).font(.headline)
                    if let o = d.organization { Text(o).font(.footnote).foregroundStyle(BK.sub) }
                }
            }
            ForEach(d.phones, id: \.self) { Label($0, systemImage: "phone").font(.subheadline) }
            ForEach(d.emails, id: \.self) { Label($0, systemImage: "envelope").font(.subheadline) }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.bold)).foregroundStyle(BK.blue.ink)
            .padding(.horizontal, 10).frame(height: 28).background(BK.blue.chip, in: Capsule())
    }

    private var doneNote: some View {
        Text("“Bitti” kartı kapatır, kaldığın yere dönersin.").font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
    }

    private func buttons(primary: String, primaryAction: @escaping () -> Void,
                         secondary: String, secondaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(primary, action: primaryAction).buttonStyle(.bkPrimary)
            Button(secondary, action: secondaryAction).buttonStyle(.bkSecondary)
        }
    }
}
