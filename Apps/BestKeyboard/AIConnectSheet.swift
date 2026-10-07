import SwiftUI
import KBRuntime

/// "Bağla": sağlayıcı (OpenAI · Cerebras) + anahtar + model. Kaydetmeden
/// önce tek kısa istekle deneniyor; başarısızsa önceki anahtar geri konuyor.
struct AIConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIService.provider
    @State private var hasSavedKey = AIService.apiKey(AIService.provider) != nil
    @State private var key = ""
    @State private var model = AIService.model(AIService.provider)
    @State private var testing = false
    @State private var error: String?
    /// Sağlayıcının kendi listesi; anahtar kayıtlıysa çekiliyor.
    @State private var models: [String] = []
    @State private var loadingModels = false

    var body: some View {
        NavigationStack {
            BKScreen("Servis bağlantısı") {
                BKCard {
                    Text("Sağlayıcı").font(.headline)
                    Picker("Sağlayıcı", selection: $provider) {
                        ForEach(AIService.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _, p in
                        model = AIService.model(p); key = ""; error = nil; models = []; refreshSaved()
                        Task { await loadModels() }
                    }
                    Text(Self.providerNote(provider))
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                BKCard {
                    HStack {
                        Text("\(provider.title) anahtarı").font(.headline)
                        Spacer()
                        if hasSavedKey {
                            Label("Kayıtlı", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold)).foregroundStyle(BK.green.ink)
                        }
                    }
                    SecureField(hasSavedKey ? "Değiştirmek için yeni anahtar" : "anahtar", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                        .bkField()
                    Text("\(provider.keyHint)’ten alınır. Telefonun anahtar zincirinde saklanır; kullanım \(provider.title) hesabına ücretlendirilir.")
                        .font(.footnote).foregroundStyle(BK.sub)
                    if hasSavedKey {
                        Button("Anahtarı sil", role: .destructive) {
                            AIService.removeKey(provider)
                            key = ""; error = nil; refreshSaved()
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
                    } else if !hasSavedKey {
                        Text("Anahtarı girip bağlayınca \(provider.title) modelleri burada listelenir.")
                            .font(.caption).foregroundStyle(BK.sub)
                    }
                    TextField(provider.defaultModel, text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                        .bkField()
                }
                if let error { BKErrorText(error) }
                Button { Task { await connect() } } label: {
                    HStack {
                        if testing { ProgressView().tint(.white) }
                        Text(testing ? "Deneniyor…" : "\(provider.title) ile bağla")
                    }
                }
                .buttonStyle(.bkPrimary)
                .disabled(testing || (key.trimmed.isEmpty && !hasSavedKey))
            }
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
        guard hasSavedKey else { return }
        loadingModels = true
        defer { loadingModels = false }
        models = (try? await AIService.listModels(provider)) ?? []
    }

    /// Yeni anahtar yazılmadıysa kayıtlı olanla deneniyor (yalnız sağlayıcı/model değişimi).
    private func connect() async {
        testing = true; error = nil
        defer { testing = false }
        do {
            try await AIService.connect(provider, key: key, model: model)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    /// Anahtar zinciri her çizimde okunmasın: kayıtlı mı bilgisi burada tutuluyor.
    private func refreshSaved() { hasSavedKey = AIService.apiKey(provider) != nil }
}
