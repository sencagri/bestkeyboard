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
                    Text(connected ? "ChatGPT bağlı" : "Klavyede sonuç al").font(.headline)
                    Text(connected ? "Çeviri ve düzeltme sohbetten çıkmadan kartta gelir."
                                   : "İsteğe bağlı. Bağlamazsan tuşlar ChatGPT ya da Claude’u açar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                Spacer(minLength: 4)
                Button {
                    if connected { AIService.setKey(nil); connected = false } else { connecting = true }
                } label: {
                    Text(connected ? "Kes" : "Bağla").font(.subheadline.weight(.bold))
                        .foregroundStyle(connected ? BK.ink : .white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(connected ? BK.line : BK.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subtitle(_ a: AIAction) -> String {
        let kind = a.kind == .image ? "Resim · " : "Metin · "
        if a.target == AIAction.here { return kind + (connected ? "Klavyede sonuç" : "ChatGPT'de açılır") }
        return kind + "\(AIApp.byID[a.target]?.name ?? "ChatGPT")'de açılır"
    }
}

/// "Bağla": OpenAI anahtarı. Kaydetmeden önce tek kısa istekle deneniyor.
struct AIConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var model = AIService.model
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BKCard {
                        Text("OpenAI anahtarı").font(.headline)
                        SecureField("sk-…", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        Text("platform.openai.com › API keys’ten alınır. Telefonun anahtar zincirinde saklanır; kullanım OpenAI hesabına ücretlendirilir.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    }
                    BKCard {
                        Text("Metin modeli").font(.headline)
                        TextField(AIService.defaultModel, text: $model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                        Text("Resimler \(AIService.imageModel) ile çizilir.").font(.footnote).foregroundStyle(BK.sub)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(BK.orange.ink) }
                    Button { Task { await connect() } } label: {
                        HStack {
                            if testing { ProgressView().tint(.white) }
                            Text(testing ? "Deneniyor…" : "Bağla").font(.headline)
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                        .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                }
                .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen("Servis bağlantısı")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } } }
        }
    }

    private func connect() async {
        testing = true; error = nil
        defer { testing = false }
        AIService.model = model.trimmingCharacters(in: .whitespaces)
        guard AIService.setKey(key) else { error = "Anahtar kaydedilemedi."; return }
        do {
            _ = try await AIService.complete("Yalnız 'tamam' yaz.")
            dismiss()
        } catch {
            AIService.setKey(nil)
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
                        BackdropRepresentable(theme: theme).frame(height: 230)
                        PanelRepresentable(theme: theme, kind: panel).frame(height: 230)
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
            p.show(.pick(source: "yarın akşam müsaitim, yedide buluşalım"))
            return p
        }
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
