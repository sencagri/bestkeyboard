import SwiftUI
import KBRuntime

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
                            .bkField()
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
