import SwiftUI
import KBRuntime

// Yapay zeka tuşları — tasarım tuvali 20 (liste) ve 21 (düzenleme).

private extension AIAction {
    var tint: BK.Tint {
        switch kind {
        case .image: return BK.orange
        case .reminder: return BK.green
        case .event: return BK.blue
        case .contact: return BK.teal
        case .text: return BK.purple
        }
    }
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

                IntegrationsCard()

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
        let kind = a.kind.title + " · "
        // Hatırlatıcı / Takvim / Kişi yalnız klavyedeki kartta çalışıyor.
        if a.kind.isStructured { return kind + (connected ? "Klavyede kart" : "Servis bağlantısı gerekir") }
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
    @State private var showRequest = true

    /// Bu tuşa basınca modele tam olarak giden şey (örnek metinle).
    private var fullRequest: String {
        let user = draft.render(text: Self.sample, clipboard: "Bu akşam çıkıyor muyuz?")
        if draft.kind == .image { return "[\(AIService.imageModel)]\n" + user }
        if draft.target == AIAction.shortcut { return "[Kestirme: \(draft.shortcutName ?? "?")] girdi: " + Self.sample }
        if draft.target != AIAction.here { return "[\(AIApp.byID[draft.target]?.name ?? "Uygulama")'de açılır]\n" + user }
        return "[sistem]\n" + AIService.systemPrompt + "\n\n[kullanıcı]\n" + user
    }

    private static let eventSample = "Cumartesi akşam 7'de Kadıköy'de buluşalım, 2 saat kadar otururuz."
    private static let contactSample = "Tesisatçının numarası: Murat Kaya 0532 418 77 90, mail murat@kayatesisat.com"
    private static let reminderSample = "Cumartesi annen gelecek, akşam otogardan alacaksın. 8 yumurta, 5 kedi maması al."
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
                    // Beş tür segmentli seçiciye sığmıyor: iki satırlık çipler.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(AIAction.Kind.allCases, id: \.self) { k in
                            let on = draft.kind == k
                            Button { draft.kind = k } label: {
                                Text(k.title).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(on ? .white : BK.ink)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? BK.accent : BK.ground, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .onChange(of: draft.kind) { old, k in
                        // Yapılandırılmış türe geçince o türün istemi; boşsa ya da öbür türün varsayılanıysa.
                        let p = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if k.isStructured, p.isEmpty || p == old.defaultTemplate.trimmingCharacters(in: .whitespacesAndNewlines) {
                            draft.prompt = k.defaultTemplate
                        } else if !k.isStructured, old.isStructured, p == old.defaultTemplate.trimmingCharacters(in: .whitespacesAndNewlines) {
                            draft.prompt = ""
                        }
                    }
                }

                BKCard {
                    if draft.kind.isStructured {
                        // Hatırlatıcı / Takvim / Kişi istemi tamamen düzenlenebilir; değişen kısımlar yer tutucu.
                        HStack {
                            label("İstem")
                            Spacer()
                            Button("Varsayılan isteme dön") { draft.prompt = draft.kind.defaultTemplate }
                                .font(.footnote.weight(.semibold)).foregroundStyle(BK.accent)
                        }
                        TextField("İstem", text: $draft.prompt, axis: .vertical)
                            .font(.footnote)
                            .lineLimit(8...30)
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Text("Ekle:").font(.footnote).foregroundStyle(BK.sub)
                                ForEach(draft.kind.placeholders, id: \.self) { v in
                                    Button { draft.prompt += (draft.prompt.isEmpty ? "" : " ") + v } label: {
                                        Text(v).font(.footnote.monospaced().weight(.bold)).foregroundStyle(BK.accent)
                                            .padding(.horizontal, 10).frame(height: 32)
                                            .background(BK.purple.chip, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Text(structuredHelp)
                            .font(.caption).foregroundStyle(BK.sub)
                        DisclosureGroup(isExpanded: $showRequest) {
                            Text("[sistem]\n" + AIService.systemPrompt + "\n\n[kullanıcı]\n" + structuredRequest)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.top, 6)
                        } label: {
                            Text("Modele giden istem").font(.subheadline.weight(.semibold))
                        }
                        .tint(BK.accent)
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BK.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    } else {
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
                        // Tasarım 21'deki önizleme artık modele giden isteğin tamamı (hatırlatıcıdaki gibi).
                        DisclosureGroup(isExpanded: $showRequest) {
                            Text(fullRequest)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.top, 6)
                        } label: {
                            Text("Modele giden istem").font(.subheadline.weight(.semibold))
                        }
                        .tint(BK.accent)
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BK.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
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
                              || (!draft.kind.isStructured && draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = actionID, let a = model.settings.aiActions.first(where: { $0.id == id }) { draft = a }
            if draft.kind.isStructured, draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.prompt = draft.kind.defaultTemplate
            }
        }
    }

    private var structuredHelp: String {
        switch draft.kind {
        case .event:
            return "{metin} mesaj · {şimdi} şu anki zaman · {takvim} önümüzdeki 14 gün · {takvimler} Takvim'deki takvimlerin. Yanıt biçimi (başlık, başlangıç, bitiş, tüm gün, yer, takvim) uygulama tarafından sabit."
        case .contact:
            return "{metin} mesaj. Yanıt biçimi (ad, soyad, telefonlar, e-postalar, kurum) uygulama tarafından sabit."
        default:
            return "{metin} mesaj · {şimdi} şu anki zaman · {takvim} önümüzdeki 14 gün · {listeler} Hatırlatıcılar'daki listelerin. Yanıt biçimi (başlık, zaman, not, liste) uygulama tarafından sabit."
        }
    }

    private var structuredRequest: String {
        switch draft.kind {
        case .event: return AIService.eventPrompt(text: Self.eventSample, template: draft.prompt)
        case .contact: return AIService.contactPrompt(text: Self.contactSample, template: draft.prompt)
        default: return AIService.reminderPrompt(text: Self.reminderSample, template: draft.prompt)
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
                if ["ai", "hatirlatici", "takvim", "kisi"].contains(panel) {
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
        case "takvim":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.events(calendar: "Ev", rows: [.init(title: "Kadıköy'de buluşma", when: "Cmt 10 Eki · 19:00",
                                                          duration: "2 saat", location: "Kadıköy")]))
            return p
        case "kisi":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.contact(name: "Murat Kaya", organization: "Kaya Tesisat", phones: ["0532 418 77 90"],
                            emails: ["murat@kayatesisat.com"]))
            return p
        case "hatirlatici":
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.reminders(list: "Alışveriş", rows: [("8 yumurta", nil), ("5 kedi maması", nil), ("4 süt", "Yarın 09:00")]))
            return p
        default:
            let p = AIPanel(actions: AIAction.defaults, theme: theme)
            p.show(.pick(source: "Are you free tomorrow evening?", label: "Panodan", canSwitch: true))
            return p
        }
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

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
}
