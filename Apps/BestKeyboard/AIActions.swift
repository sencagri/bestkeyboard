import SwiftUI
import KBRuntime

// Yapay zeka tuşları — tasarım tuvali 20 (liste) ve 21 (düzenleme).

private extension AIAction {
    var tint: BK.Tint { kind == .image ? BK.orange : BK.purple }
}

struct AIActionsView: View {
    let model: KeyboardSettingsModel
    @State private var connected = AIService.isConnected
    @State private var connecting = false

    private var list: [AIAction] { model.settings.aiActions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                serviceCard

                BKCard(padding: 16) {
                    HStack {
                        BKSectionTitle(text: "Tuşlarım · \(list.count)", color: BK.accent)
                        Spacer()
                        Button("Varsayılanlara dön") { model.update { $0.aiActions = AIAction.defaults } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BK.accent)
                    }
                    if list.isEmpty {
                        Text("Liste boş — aşağıdan yeni tuş ekle ya da varsayılanlara dön.")
                            .font(.subheadline).foregroundStyle(BK.sub)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        VStack(spacing: 0) {
                            Divider().overlay(BK.line)
                            HStack(spacing: 12) {
                                NavigationLink { AIActionEditor(model: model, actionID: a.id) } label: {
                                    HStack(spacing: 12) {
                                        BKIcon(systemName: a.icon, tint: a.tint, size: 38)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(a.name).font(.body.weight(.semibold)).foregroundStyle(BK.ink)
                                            Text(subtitle(a)).font(.footnote).foregroundStyle(BK.sub)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { model.update { $0.aiActions.remove(at: i) } } label: {
                                    Image(systemName: "minus.circle").font(.title3).foregroundStyle(BK.pink.ink)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(a.name) tuşunu sil")
                            }
                            .frame(minHeight: 60)
                        }
                    }
                }

                NavigationLink { AIActionEditor(model: model, actionID: nil) } label: {
                    Text("+ Yeni tuş").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                (Text("Klavyede araç satırındaki ✦ tuşuna bas ya da mesajın sonuna ")
                 + Text("/çevir").font(.footnote.monospaced()).foregroundColor(BK.ink)
                 + Text(" gibi tuşun adını yaz. Seçili metin yoksa son cümle kullanılır."))
                    .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Yapay zeka tuşları")
        .sheet(isPresented: $connecting, onDismiss: { connected = AIService.isConnected }) {
            AIConnectSheet()
        }
    }

    private var serviceCard: some View {
        BKCard {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(connected ? BK.green.ink : BK.accent, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "\(AIService.provider.title) bağlı" : "Klavyede sonuç al").font(.headline)
                    Text(connected ? "Çeviri ve düzeltme sohbetten çıkmadan kartta gelir."
                                   : "İsteğe bağlı. Bağlamazsan tuşlar ChatGPT ya da Claude’u açar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                Spacer(minLength: 4)
                Button {
                    connecting = true
                } label: {
                    Text(connected ? "Değiştir" : "Bağla").font(.subheadline.weight(.bold))
                        .foregroundStyle(connected ? BK.ink : .white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(connected ? BK.line : BK.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subtitle(_ a: AIAction) -> String {
        let kind = a.kind == .image ? "Resim · " : a.kind == .reminder ? "Hatırlatıcı · " : "Metin · "
        if a.target == AIAction.here { return kind + (connected ? "Klavyede sonuç" : "ChatGPT'de açılır") }
        if a.target == AIAction.shortcut { return kind + "Kestirme: \(a.shortcutName ?? "?")" }
        return kind + "\(AIApp.byID[a.target]?.name ?? "ChatGPT")'de açılır"
    }
}

/// "Bağla": sağlayıcı (OpenAI · Cerebras) + anahtar + model. Kaydetmeden
/// önce tek kısa istekle deneniyor; başarısızsa önceki anahtar geri konuyor.
struct AIConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIService.provider
    @State private var key = ""
    @State private var model = AIService.model(AIService.provider)
    @State private var testing = false
    @State private var error: String?
    /// Sağlayıcının kendi listesi; anahtar kayıtlıysa çekiliyor.
    @State private var models: [String] = []
    @State private var loadingModels = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BKCard {
                        Text("Sağlayıcı").font(.headline)
                        Picker("Sağlayıcı", selection: $provider) {
                            ForEach(AIService.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: provider) { _, p in
                            model = AIService.model(p); key = ""; error = nil; models = []
                            Task { await loadModels() }
                        }
                        Text(Self.providerNote(provider))
                            .font(.footnote).foregroundStyle(BK.sub)
                    }
                    BKCard {
                        HStack {
                            Text("\(provider.title) anahtarı").font(.headline)
                            Spacer()
                            if AIService.apiKey(provider) != nil {
                                Label("Kayıtlı", systemImage: "checkmark.circle.fill")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(BK.green.ink)
                            }
                        }
                        SecureField(AIService.apiKey(provider) != nil ? "Değiştirmek için yeni anahtar" : "anahtar", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        Text("\(provider.keyHint)’ten alınır. Telefonun anahtar zincirinde saklanır; kullanım \(provider.title) hesabına ücretlendirilir.")
                            .font(.footnote).foregroundStyle(BK.sub)
                        if AIService.apiKey(provider) != nil {
                            Button("Anahtarı sil", role: .destructive) {
                                AIService.setKey(nil, for: provider)
                                if AIService.provider == provider,
                                   let other = AIService.Provider.allCases.first(where: { AIService.apiKey($0) != nil }) {
                                    AIService.provider = other
                                }
                                key = ""; error = nil
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    BKCard {
                        HStack {
                            Text("Metin modeli").font(.headline)
                            Spacer()
                            if loadingModels { ProgressView() }
                        }
                        if !models.isEmpty {
                            Picker("Model", selection: $model) {
                                if !models.contains(model) { Text(model).tag(model) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(BK.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                            Text("\(provider.title) hesabındaki modeller. Listede yoksa aşağıya elle yaz.")
                                .font(.caption).foregroundStyle(BK.sub)
                        } else if AIService.apiKey(provider) == nil {
                            Text("Anahtarı girip bağlayınca \(provider.title) modelleri burada listelenir.")
                                .font(.caption).foregroundStyle(BK.sub)
                        }
                        TextField(provider.defaultModel, text: $model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(BK.orange.ink) }
                    Button { Task { await connect() } } label: {
                        HStack {
                            if testing { ProgressView().tint(.white) }
                            Text(testing ? "Deneniyor…" : "\(provider.title) ile bağla").font(.headline)
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                        .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(testing || (key.trimmingCharacters(in: .whitespaces).isEmpty && AIService.apiKey(provider) == nil))
                }
                .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen("Servis bağlantısı")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } } }
            .task { await loadModels() }
        }
    }

    private static func providerNote(_ p: AIService.Provider) -> String {
        switch p {
        case .openai: return "Metin ve resim. Resimler \(AIService.imageModel) ile çizilir."
        case .anthropic: return "Claude modelleri. Resim çizmiyor — resim tuşları için OpenAI anahtarı da gerekir."
        case .cerebras: return "Çok hızlı: çeviri ve düzeltme neredeyse anında gelir. Resim çizmiyor — resim tuşları için OpenAI anahtarı da gerekir."
        case .openrouter: return "Tek anahtarla yüzlerce model (OpenAI, Claude, Gemini, Llama…). Resim tuşları için OpenAI anahtarı gerekir."
        }
    }

    private func loadModels() async {
        guard AIService.apiKey(provider) != nil else { return }
        loadingModels = true
        defer { loadingModels = false }
        models = (try? await AIService.listModels(provider)) ?? []
    }

    /// Yeni anahtar yazılmadıysa kayıtlı olanla deneniyor (yalnız sağlayıcı/model değişimi).
    private func connect() async {
        testing = true; error = nil
        defer { testing = false }
        let previous = AIService.apiKey(provider)
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard AIService.setKey(typed, for: provider) else { error = "Anahtar kaydedilemedi."; return }
        }
        let oldModel = AIService.model(provider)
        AIService.setModel(model.trimmingCharacters(in: .whitespaces), for: provider)
        do {
            _ = try await AIService.complete("Yalnız 'tamam' yaz.", using: provider)
            AIService.provider = provider
            dismiss()
        } catch {
            AIService.setKey(previous, for: provider)
            AIService.setModel(oldModel, for: provider)
            self.error = error.localizedDescription
        }
    }
}

struct AIActionEditor: View {
    let model: KeyboardSettingsModel
    /// `nil` = yeni tuş.
    let actionID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AIAction(name: "", icon: "sparkles", prompt: "", target: AIAction.here)
    @State private var loaded = false

    private static let sample = "yarın akşam müsait misin"
    private static let wheres: [(String, String, String)] = [
        (AIAction.here, "Klavyede", "Sonuç kartta gelir · servis bağlantısı gerekir"),
        ("chatgpt", "ChatGPT", "Uygulama istemle açılır"),
        ("claude", "Claude", "Uygulama istemle açılır"),
        ("gemini", "Gemini", "İstem panoya konur, yapıştırırsın"),
        (AIAction.shortcut, "Kestirme", "Kendi kestirmen metinle çalışır"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    label("Ad")
                    TextField("ör. Çevir", text: $draft.name)
                        .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    label("Simge")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(AIAction.icons, id: \.self) { ic in
                            let on = draft.icon == ic
                            Button { draft.icon = ic } label: {
                                Image(systemName: ic).font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(on ? .white : BK.ink)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(on ? BK.accent : BK.ground, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    label("Ne üretsin")
                    Picker("Ne üretsin", selection: $draft.kind) {
                        Text("Metin").tag(AIAction.Kind.text)
                        Text("Resim").tag(AIAction.Kind.image)
                        Text("Hatırlatıcı").tag(AIAction.Kind.reminder)
                    }
                    .pickerStyle(.segmented)
                }

                BKCard {
                    label("İstem")
                    TextField("ör. İngilizceye çevir, yalnız çeviriyi yaz:", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 8) {
                        Text("Ekle:").font(.footnote).foregroundStyle(BK.sub)
                        ForEach(["{metin}", "{pano}"], id: \.self) { v in
                            Button { draft.prompt += (draft.prompt.isEmpty ? "" : " ") + v } label: {
                                Text(v).font(.footnote.monospaced().weight(.bold)).foregroundStyle(BK.accent)
                                    .padding(.horizontal, 10).frame(height: 32)
                                    .background(BK.purple.chip, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("{metin} seçili metin, yoksa son cümle. Koymazsan metin istemin altına eklenir.")
                        .font(.caption).foregroundStyle(BK.sub)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ÖNİZLEME").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(BK.sub)
                        Text(draft.render(text: Self.sample, clipboard: "Bu akşam çıkıyor muyuz?"))
                            .font(.subheadline)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BK.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }

                BKCard(padding: 16) {
                    label("Nerede çalışsın")
                    ForEach(Self.wheres, id: \.0) { id, title, sub in
                        VStack(spacing: 0) {
                            Divider().overlay(BK.line)
                            Button { draft.target = id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: draft.target == id ? "largecircle.fill.circle" : "circle")
                                        .font(.title3).foregroundStyle(draft.target == id ? BK.accent : BK.sub)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(title).font(.body.weight(.semibold)).foregroundStyle(BK.ink)
                                        Text(sub).font(.caption).foregroundStyle(BK.sub)
                                    }
                                    Spacer()
                                }
                                .frame(minHeight: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(draft.target == id ? .isSelected : [])
                        }
                    }
                    if draft.target == AIAction.shortcut {
                        Divider().overlay(BK.line)
                        label("Kestirmenin adı")
                        TextField("ör. Hatırlatıcıya ekle", text: Binding(get: { draft.shortcutName ?? "" },
                                                                          set: { draft.shortcutName = $0 }))
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        Text("Kestirmeler uygulamasındaki adıyla aynı yaz. Metin kestirmeye girdi olarak gider; kestirme bir sonuç verirse panoya konur.")
                            .font(.caption).foregroundStyle(BK.sub)
                        Link("Kestirmeler’de aç", destination: URL(string: "shortcuts://")!)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if actionID != nil {
                    Button(role: .destructive) {
                        model.update { $0.aiActions.removeAll { $0.id == actionID } }
                        dismiss()
                    } label: {
                        Text("Tuşu sil").font(.headline).foregroundStyle(BK.pink.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen(actionID == nil ? "Yeni tuş" : "Tuşu düzenle")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Kaydet") { save() }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = actionID, let a = model.settings.aiActions.first(where: { $0.id == id }) { draft = a }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        model.update { s in
            if let i = s.aiActions.firstIndex(where: { $0.id == draft.id }) { s.aiActions[i] = draft }
            else { s.aiActions.append(draft) }
        }
        dismiss()
    }
}

#if DEBUG
/// `-bkScreen yzkart -aiTheme <id> [-panel ai|emoji|pano|medya]`: klavyedeki
/// kartı ve panelleri seçili temayla, klavye önizlemesinin üstünde çizer —
/// simülatörde klavye eklentisinin temasını dışarıdan değiştirmek mümkün değil.
struct AIPanelThemePreview: View {
    @Environment(\.colorScheme) private var scheme
    private func arg(_ k: String, _ d: String) -> String {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: k), i + 1 < a.count else { return d }
        return a[i + 1]
    }
    var body: some View {
        let themeID = arg("-aiTheme", "light"), panel = arg("-panel", "ai")
        let theme = (ThemeSpec.preset(id: themeID) ?? ThemeSpec.preset(id: "light")!).resolved()
        var settings = KeyboardSettings.default
        settings.theme = ThemeChoice(rawValue: themeID)
        return GeometryReader { g in
            VStack(spacing: 0) {
                Spacer()
                if panel == "ai" {
                    ZStack(alignment: .top) {
                        BackdropRepresentable(theme: theme).frame(height: 300)
                        PanelRepresentable(theme: theme, kind: panel).frame(height: 300)
                    }
                    ScaledKeyboardPreview(settings: settings, scheme: scheme, width: g.size.width, themeOverride: theme)
                } else {
                    let h = ThemedKeyboardPreview.height(settings) * g.size.width / ThemedKeyboardPreview.width
                    ZStack {
                        BackdropRepresentable(theme: theme)
                        PanelRepresentable(theme: theme, kind: panel)
                    }
                    .frame(height: h)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .bkScreen("\(panel) · \(themeID)")
    }
}

private struct PanelRepresentable: UIViewRepresentable {
    let theme: KeyboardTheme
    let kind: String
    func makeUIView(context: Context) -> UIView {
        switch kind {
        case "emoji":
            return EmojiPanel(theme: theme, recents: EmojiRecents(items: ["😂", "🇹🇷", "❤️", "👍", "🙏", "😊", "🎉", "🔥"]))
        case "pano":
            return ClipboardPanel(items: [], theme: theme)
        case "medya":
            return MediaPanel(theme: theme)
        default:
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.pick(source: "Are you free tomorrow evening?", label: "Panodan", canSwitch: true))
            return p
        }
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

// MARK: - Klavyeden gelen işler

/// `bestkeyboard://hatirlatici?title=…&due=…&notes=…[&edit=1]` — klavyenin
/// ✦ kartı (tasarım 26). Düzenleme alanları kartla aynı: başlık, gün/saat, not.
struct ReminderHandoff: Identifiable {
    let id = UUID()
    var draft: AIService.ReminderDraft
    var edit: Bool

    init?(url: URL) {
        guard url.host == "hatirlatici",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = items.first(where: { $0.name == "title" })?.value, !title.isEmpty else { return nil }
        let due = items.first(where: { $0.name == "due" })?.value.flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        draft = AIService.ReminderDraft(title: title, due: due,
                                        notes: items.first(where: { $0.name == "notes" })?.value)
        edit = items.first(where: { $0.name == "edit" })?.value == "1"
    }
}

struct ReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var handoff: ReminderHandoff
    @State private var hasTime = true
    @State private var due = Date()
    @State private var state: Phase = .editing
    enum Phase: Equatable { case editing, saving, done(list: String), failed(String) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state {
                    case let .done(list):
                        BKCard {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                                    .frame(width: 36, height: 36).background(BK.green.ink, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hatırlatıcılar’a eklendi").font(.headline)
                                    Text(summary).font(.subheadline).foregroundStyle(BK.sub)
                                }
                            }
                            Text("Apple Hatırlatıcılar › \(list) listesinde; iCloud ile diğer cihazlarına da gider. Sol üstteki ◀ ile sohbete dönebilirsin.")
                                .font(.footnote).foregroundStyle(BK.sub)
                        }
                        // Apple'ın kendi uygulamasında görmek için.
                        Button {
                            if let url = URL(string: "x-apple-reminderkit://") { UIApplication.shared.open(url) }
                        } label: {
                            Label("Hatırlatıcılar’da aç", systemImage: "checklist").font(.headline)
                                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                                .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    default:
                        BKCard {
                            Text("Başlık").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                            TextField("Başlık", text: $handoff.draft.title)
                                .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                            Toggle("Zamanı var", isOn: $hasTime).tint(BK.accent)
                            if hasTime {
                                DatePicker("Gün ve saat", selection: $due).environment(\.locale, Locale(identifier: "tr_TR"))
                            }
                            Text("Not").font(.footnote.weight(.bold)).foregroundStyle(BK.sub)
                            TextField("Not", text: Binding(get: { handoff.draft.notes ?? "" },
                                                           set: { handoff.draft.notes = $0 }), axis: .vertical)
                                .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if case let .failed(msg) = state { Text(msg).font(.footnote).foregroundStyle(BK.orange.ink) }
                        Button { Task { await save() } } label: {
                            Text(state == .saving ? "Ekleniyor…" : "Hatırlatıcılar’a ekle").font(.headline)
                                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                                .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(state == .saving || handoff.draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen("Hatırlatıcı")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .task {
            hasTime = handoff.draft.due != nil
            due = handoff.draft.due ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                              of: Date().addingTimeInterval(86_400)) ?? Date()
            // "Ekle" ile geldiyse düzenleme ekranı gösterilmeden ekleniyor.
            if !handoff.edit { await save() }
        }
    }

    private var summary: String {
        handoff.draft.title + (handoff.draft.due.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }

    private func save() async {
        state = .saving
        handoff.draft.due = hasTime ? due : nil
        do { state = .done(list: try await ReminderMaker.add(handoff.draft)) }
        catch { state = .failed(error.localizedDescription) }
    }
}

/// `bestkeyboard://kestirme-sonuc?result=…` — Kestirme bitti; sonuç panoya.
struct ShortcutResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: String?
    let failed: Bool
    /// Kestirmeler'in `x-error` ile eklediği açıklama.
    var errorMessage: String? = nil
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    Text(failed ? "Kestirme çalışmadı" : (result?.isEmpty == false ? "Sonuç panoya kondu" : "Kestirme bitti"))
                        .font(.headline)
                    if failed {
                        if let errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage).font(.subheadline).foregroundStyle(BK.orange.ink)
                        }
                        Text("Kestirmenin adını Kestirmeler uygulamasındakiyle aynı yazdığından emin ol: Yapay zeka tuşları › tuş › Kestirmenin adı.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    } else if let result, !result.isEmpty {
                        Text(result).font(.subheadline).foregroundStyle(BK.sub).lineLimit(6)
                        Text("Sol üstteki ◀ ile sohbete dön; mesaj kutusuna basılı tutup Yapıştır de.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    } else {
                        Text("Kestirme bir sonuç döndürmedi. Sol üstteki ◀ ile sohbete dönebilirsin.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    }
                }
                Spacer()
            }
            .padding(16)
            .foregroundStyle(BK.ink)
            .bkScreen("Kestirme")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .onAppear { if let result, !result.isEmpty, !failed { UIPasteboard.general.string = result } }
    }
}

struct ShortcutResultPayload: Identifiable {
    let id = UUID()
    let result: String?
    let failed: Bool
    var errorMessage: String? = nil
}
