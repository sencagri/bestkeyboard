import SwiftUI
import KBRuntime

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

    private static let eventSample = SampleData.meetingMessage
    private static let contactSample = SampleData.contactMessage
    private static let reminderSample = SampleData.reminderMessage
    /// Tuşun çalışacağı yer: kart, uygulamalar (`AIApp.all` — kural `takesText`), kestirme.
    private static let wheres: [(String, String, String)] =
        [(AIAction.here, "Klavyede", "Sonuç kartta gelir · servis bağlantısı gerekir")]
        + AIApp.all.map { ($0.id, $0.name, $0.takesText ? "Uygulama istemle açılır" : "İstem panoya konur, yapıştırırsın") }
        + [(AIAction.shortcut, "Kestirme", "Kendi kestirmen metinle çalışır")]

    var body: some View {
        BKScreen(actionID == nil ? "Yeni tuş" : "Tuşu düzenle") {
            BKCard {
                BKFieldLabel("Ad")
                TextField("ör. Çevir", text: $draft.name)
                    .bkField()
                BKFieldLabel("Simge")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(AIAction.icons, id: \.self) { ic in
                        let on = draft.icon == ic
                        Button { draft.icon = ic } label: {
                            Image(systemName: ic).font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(on ? .white : BK.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(on ? BK.accent : BK.ground, in: RoundedRectangle(cornerRadius: BK.Radius.field))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                BKFieldLabel("Ne üretsin")
                // Beş tür segmentli seçiciye sığmıyor: iki satırlık çipler.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AIAction.Kind.allCases, id: \.self) { k in
                        let on = draft.kind == k
                        Button { draft.kind = k } label: {
                            Text(k.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(on ? .white : BK.ink)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(on ? BK.accent : BK.ground, in: RoundedRectangle(cornerRadius: BK.Radius.thumb))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .onChange(of: draft.kind) { old, k in
                    // Yapılandırılmış türe geçince o türün istemi; boşsa ya da öbür türün varsayılanıysa.
                    let p = draft.prompt.trimmed
                    if k.isStructured, p.isEmpty || p == old.defaultTemplate.trimmed {
                        draft.prompt = k.defaultTemplate
                    } else if !k.isStructured, old.isStructured, p == old.defaultTemplate.trimmed {
                        draft.prompt = ""
                    }
                }
            }

            BKCard {
                if draft.kind.isStructured {
                    // Hatırlatıcı / Takvim / Kişi istemi tamamen düzenlenebilir; değişen kısımlar yer tutucu.
                    HStack {
                        BKFieldLabel("İstem")
                        Spacer()
                        Button("Varsayılan isteme dön") { draft.prompt = draft.kind.defaultTemplate }
                            .font(.footnote.weight(.semibold)).foregroundStyle(BK.accent)
                    }
                    TextField("İstem", text: $draft.prompt, axis: .vertical)
                        .font(.footnote)
                        .lineLimit(8...30)
                        .bkField()
                    placeholderRow
                    Text(structuredHelp)
                        .font(.caption).foregroundStyle(BK.sub)
                    requestPreview("[sistem]\n" + AIService.systemPrompt + "\n\n[kullanıcı]\n" + structuredRequest)
                } else {
                    BKFieldLabel("İstem")
                    TextField("ör. İngilizceye çevir, yalnız çeviriyi yaz:", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .bkField()
                    placeholderRow
                    Text("{metin} seçili metin, yoksa son cümle. Koymazsan metin istemin altına eklenir.")
                        .font(.caption).foregroundStyle(BK.sub)
                    // Tasarım 21'deki önizleme artık modele giden isteğin tamamı (hatırlatıcıdaki gibi).
                    requestPreview(fullRequest)
                }
            }

            BKCard(padding: 16) {
                BKFieldLabel("Nerede çalışsın")
                ForEach(Self.wheres, id: \.0) { id, title, sub in
                    VStack(spacing: 0) {
                        BKDivider()
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
                    BKDivider()
                    BKFieldLabel("Kestirmenin adı")
                    TextField("ör. Hatırlatıcıya ekle", text: $draft.shortcutName.orEmpty)
                        .bkField()
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
                } label: { Text("Tuşu sil") }
                .buttonStyle(.bkCard(BK.pink.ink))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Kaydet") { save() }
                    .disabled(draft.name.trimmed.isEmpty
                              || (!draft.kind.isStructured && draft.prompt.trimmed.isEmpty))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = actionID, let a = model.settings.aiActions.first(where: { $0.id == id }) { draft = a }
            if draft.kind.isStructured, draft.prompt.trimmed.isEmpty {
                draft.prompt = draft.kind.defaultTemplate
            }
        }
    }

    /// Şablona yer tutucu ekleyen çipler — türün kendi listesi.
    private var placeholderRow: some View {
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
    }

    /// Modele giden isteğin tamamı, açılır kutuda.
    private func requestPreview(_ request: String) -> some View {
        DisclosureGroup(isExpanded: $showRequest) {
            Text(request)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 6)
        } label: {
            Text("Modele giden istem").font(.subheadline.weight(.semibold))
        }
        .tint(BK.accent)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: BK.Radius.field)
            .strokeBorder(BK.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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


    private func save() {
        draft.name = draft.name.trimmed
        model.update { s in
            if let i = s.aiActions.firstIndex(where: { $0.id == draft.id }) { s.aiActions[i] = draft }
            else { s.aiActions.append(draft) }
        }
        dismiss()
    }
}
