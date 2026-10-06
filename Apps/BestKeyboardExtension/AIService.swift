import Foundation
import Security
import UIKit

/// "Klavyede sonuç al" — yapay zeka tuşlarının servis bağlantısı.
///
/// İki sağlayıcı: OpenAI ve Cerebras (çok hızlı; API'si OpenAI biçiminde).
/// Metin istekleri **seçili** sağlayıcıya gidiyor; resim yalnız OpenAI'de
/// var, o yüzden resimler OpenAI anahtarıyla çiziliyor.
///
/// Anahtar **anahtar zincirinde**, uygulama ile klavyenin ortak erişim
/// grubunda: uygulama yazıyor, klavye (Tam Erişimle) okuyor. Ortak klasördeki
/// bir dosyaya koymak daha kolaydı ama bir parola dosyada durmamalı.
enum AIService {
    static let keychainGroup = "KQQ4W7T779.com.sencagri.bestkeyboard.shared"
    static let imageModel = "gpt-image-1"

    enum Provider: String, CaseIterable, Sendable {
        case openai, anthropic, cerebras, openrouter
        var title: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Claude"
            case .cerebras: return "Cerebras"
            case .openrouter: return "OpenRouter"
            }
        }
        var baseURL: String {
            switch self {
            case .openai: return "https://api.openai.com/v1/"
            case .anthropic: return "https://api.anthropic.com/v1/"
            case .cerebras: return "https://api.cerebras.ai/v1/"
            case .openrouter: return "https://openrouter.ai/api/v1/"
            }
        }
        /// Klavyede hız önemli: her sağlayıcının hızlı/ucuz modeli.
        var defaultModel: String {
            switch self {
            case .openai: return "gpt-4.1-mini"
            case .anthropic: return "claude-haiku-4-5"
            case .cerebras: return "gpt-oss-120b"
            case .openrouter: return "openrouter/auto"
            }
        }
        var keyHint: String {
            switch self {
            case .openai: return "platform.openai.com › API keys"
            case .anthropic: return "platform.claude.com › API keys"
            case .cerebras: return "cloud.cerebras.ai › API Keys"
            case .openrouter: return "openrouter.ai › Keys"
            }
        }
        /// Claude'un kendi biçimi var; diğerleri OpenAI biçiminde.
        var isAnthropic: Bool { self == .anthropic }
        /// Anahtar zincirindeki hesap adı — OpenAI eski kayıtla aynı kalıyor.
        fileprivate var account: String { rawValue }
        fileprivate var modelKey: String { self == .openai ? "kb.ai.model" : "kb.ai.model.\(rawValue)" }
    }

    private static let providerKey = "kb.ai.provider"
    private static var shared: UserDefaults { UserDefaults(suiteName: KeyboardSettingsStore.appGroup) ?? .standard }

    /// Metin isteklerinin gittiği sağlayıcı.
    static var provider: Provider {
        get { shared.string(forKey: providerKey).flatMap(Provider.init(rawValue:)) ?? .openai }
        set { shared.set(newValue == .openai ? nil : newValue.rawValue, forKey: providerKey) }
    }

    // MARK: Anahtar

    static func apiKey(_ p: Provider) -> String? {
        var q = baseQuery(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static var apiKey: String? { apiKey(provider) }
    static var isConnected: Bool { apiKey != nil }
    /// Resim çizilebiliyor mu (OpenAI anahtarı var mı).
    static var canDraw: Bool { apiKey(.openai) != nil }

    @discardableResult
    static func setKey(_ key: String?, for p: Provider? = nil) -> Bool {
        let p = p ?? provider
        SecItemDelete(baseQuery(p) as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var q = baseQuery(p)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ p: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sencagri.bestkeyboard.ai",
         kSecAttrAccount as String: p.account,
         kSecAttrAccessGroup as String: keychainGroup]
    }

    // MARK: Model

    static func model(_ p: Provider) -> String {
        shared.string(forKey: p.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
    }
    static func setModel(_ m: String, for p: Provider) {
        shared.set(m == p.defaultModel || m.isEmpty ? nil : m, forKey: p.modelKey)
    }
    static var model: String { model(provider) }

    // MARK: İstekler

    enum Failure: LocalizedError {
        case noKey, http(Int, String), empty, needsOpenAIForImages
        var errorDescription: String? {
            switch self {
            case .noKey: return "Servis bağlı değil — uygulamada Yapay zeka tuşları › Bağla."
            case let .http(code, msg):
                return code == 401 ? "Anahtar geçersiz. Uygulamadan yeniden bağla." : "Servis hatası (\(code)): \(msg)"
            case .empty: return "Servis boş yanıt döndü."
            case .needsOpenAIForImages: return "Resim üretmek için OpenAI anahtarı gerekli (resimler OpenAI ile çiziliyor)."
            }
        }
    }

    private static let systemPrompt =
        "Bir klavyenin içinden çağrılıyorsun. Yalnız istenen çıktıyı ver: açıklama, tırnak ya da başlık ekleme."

    /// Metin: istem → tek yanıt (seçili sağlayıcı; `using` ile başkası).
    ///
    /// `schema` verilirse yanıt o JSON şemasına **zorlanıyor** (yapılandırılmış
    /// çıktı): Claude'da `output_config.format`, OpenAI biçimindekilerde
    /// `response_format: json_schema`. OpenRouter'da her model desteklemiyor;
    /// reddedilirse şemasız bir kez daha deneniyor.
    static func complete(_ prompt: String, using p: Provider? = nil,
                         schema: [String: Any]? = nil) async throws -> String {
        let p = p ?? provider
        do {
            return try await completeOnce(prompt, p, schema)
        } catch Failure.http(let code, _) where schema != nil && code == 400 {
            return try await completeOnce(prompt, p, nil)
        }
    }

    private static func completeOnce(_ prompt: String, _ p: Provider, _ schema: [String: Any]?) async throws -> String {
        if p.isAnthropic {
            var body: [String: Any] = [
                "model": model(p), "max_tokens": 1024, "system": systemPrompt,
                "messages": [["role": "user", "content": prompt]],
            ]
            if let schema { body["output_config"] = ["format": ["type": "json_schema", "schema": schema]] }
            let json = try await post("messages", body, provider: p, timeout: 45)
            let text = (json["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.empty }
            return text
        }
        var body: [String: Any] = [
            "model": model(p),
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
        ]
        if let schema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "cikti", "strict": true, "schema": schema]]
        }
        // Cerebras: akıl yürütme adımı klavyede beklemek demek. gpt-oss en az
        // "low" kabul ediyor; qwen/gemma "none" ile tamamen kapatılabiliyor
        // (inference-docs.cerebras.ai/capabilities/reasoning).
        if p == .cerebras {
            body["reasoning_effort"] = model(p).contains("gpt-oss") ? "low" : "none"
        }
        let json = try await post("chat/completions", body, provider: p, timeout: 45)
        guard let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw Failure.empty }
        return text
    }

    /// Mesajdan hatırlatıcı taslağı — başlık, (varsa) zaman, not.
    struct ReminderDraft: Sendable, Codable, Hashable {
        var title: String
        var due: Date?
        var notes: String?
    }

    /// Mesajdan çıkan yapılacaklar: her iş/alınacak **ayrı** madde (Hatırlatıcılar'da
    /// tek tek işaretlenebilsin) ve uygun liste ("Alışveriş"…; `nil` = varsayılan).
    struct ReminderPlan: Sendable, Codable, Hashable {
        var list: String?
        var items: [ReminderDraft]
    }

    /// Kullanıcının Hatırlatıcılar listeleri — klavye EventKit'e erişemiyor;
    /// uygulama izni olduğunda adları ortak depoya yazıyor, klavye buradan okuyor.
    static var reminderLists: [String] {
        get { shared.stringArray(forKey: "kb.reminder.lists") ?? [] }
        set { shared.set(newValue, forKey: "kb.reminder.lists") }
    }

    /// "8 yumurta, 5 kedi maması, 4 süt lazım" → üç madde, Alışveriş listesi.
    /// "Yarın 7'de Kadıköy'de buluşalım" → tek madde, yarın 19:00. Göreli
    /// zamanlar için modele **şimdi** ve saat dilimi veriliyor.
    static func reminders(from text: String, lists: [String] = reminderLists,
                          now: Date = Date()) async throws -> ReminderPlan {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let listLine = lists.isEmpty ? "" :
            "Kullanıcının hatırlatıcı listeleri: \(lists.map { "\"\($0)\"" }.joined(separator: ", ")). " +
            "list alanına bunlardan en uygun olanın adını aynen yaz (ör. alınacaklar için alışveriş listesi); uygun yoksa boş bırak."
        let prompt = """
        Şu mesajdaki yapılacakları Apple Hatırlatıcılar'a eklenecek maddelere çevir.
        Şu an: \(f.string(from: now)) (saat dilimi \(TimeZone.current.identifier)).
        Birden çok iş ya da alınacak şey varsa HER BİRİ AYRI madde olsun; miktarı başlıkta tut ("8 yumurta").
        Tek bir iş varsa tek madde. Başlıklar kısa ve Türkçe; mesajdan gelmeli, açıklama ya da şablon metni yazma.
        due: "YYYY-MM-DDTHH:mm"; zaman yoksa "". Saat yoksa ama gün varsa 09:00. notes: gerekirse kısa not, yoksa "".
        \(listLine)

        Mesaj:
        \(text)
        """
        // Şema: alanlar zorunlu, boş metin = yok. (Null'a izin veren tip
        // dizileri her sağlayıcıda desteklenmiyor; boş metin hepsinde çalışıyor.)
        let item: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "due": ["type": "string"], "notes": ["type": "string"]],
            "required": ["title", "due", "notes"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["list": ["type": "string"], "items": ["type": "array", "items": item]],
            "required": ["list", "items"],
            "additionalProperties": false,
        ]
        let raw = try await complete(prompt, schema: schema)
        // Şema desteklenmeyip düz metin döndüyse de ilk {…} bloğu ayıklanıyor.
        let jsonText = raw.drop { $0 != "{" }.reversed().drop { $0 != "}" }.reversed()
        guard let d = String(jsonText).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure.empty }
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = .current
        p.dateFormat = "yyyy-MM-dd'T'HH:mm"
        // Eski tek maddelik biçim de kabul ediliyor (şemasız yanıt).
        let rawItems = (obj["items"] as? [[String: Any]]) ?? [obj]
        let items: [ReminderDraft] = rawItems.prefix(30).compactMap { o in
            guard let t = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let due = (o["due"] as? String).flatMap { $0.isEmpty ? nil : p.date(from: String($0.prefix(16))) }
            let notes = (o["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ReminderDraft(title: t, due: due, notes: notes)
        }
        guard !items.isEmpty else { throw Failure.empty }
        // Model listede olmayan bir ad uydurduysa varsayılana düşülüyor.
        let list = (obj["list"] as? String).flatMap { name in
            lists.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        return ReminderPlan(list: list, items: items)
    }

    /// Tek madde (Kestirmeler eylemi ve eski çağıranlar için).
    static func reminder(from text: String, now: Date = Date()) async throws -> ReminderDraft {
        try await reminders(from: text, now: now).items[0]
    }

    /// Sağlayıcının model listesi (`GET /v1/models`). OpenAI'de yalnız sohbet
    /// modelleri bırakılıyor — ses, resim, gömme modelleri burada işe yaramaz.
    static func listModels(_ p: Provider) async throws -> [String] {
        guard let key = apiKey(p) else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: p.baseURL + (p.isAnthropic ? "models?limit=100" : "models"))!,
                             timeoutInterval: 20)
        authorize(&req, p, key)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code, "") }
        let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
        if p.isAnthropic { return ids }   // en yeni başta geliyor
        guard p == .openai else { return ids.sorted() }
        let skip = ["image", "audio", "realtime", "tts", "whisper", "embedding", "dall-e", "transcribe",
                    "moderation", "search", "davinci", "babbage", "instruct", "codex"]
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o")) && !skip.contains { id.contains($0) }
        }.sorted()
    }

    /// Resim: istem → kare PNG.
    static func image(_ prompt: String) async throws -> UIImage {
        let body: [String: Any] = ["model": imageModel, "prompt": prompt, "size": "1024x1024", "n": 1]
        // Resim yalnız OpenAI'de.
        guard canDraw else { throw Failure.needsOpenAIForImages }
        let json = try await post("images/generations", body, provider: .openai, timeout: 120)
        guard let data = (json["data"] as? [[String: Any]])?.first,
              let b64 = data["b64_json"] as? String, let d = Data(base64Encoded: b64),
              let img = UIImage(data: d) else { throw Failure.empty }
        return img
    }

    /// Claude `x-api-key` + sürüm başlığı; diğerleri `Bearer`. OpenRouter
    /// uygulama adını da istiyor (isteğe bağlı, sıralama için).
    private static func authorize(_ req: inout URLRequest, _ p: Provider, _ key: String) {
        if p.isAnthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if p == .openrouter { req.setValue("BestKeyboard", forHTTPHeaderField: "X-OpenRouter-Title") }
    }

    private static func post(_ path: String, _ body: [String: Any], provider p: Provider,
                             timeout: TimeInterval) async throws -> [String: Any] {
        guard let key = apiKey(p) else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: p.baseURL + path)!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        authorize(&req, p, key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw Failure.http(code, String(msg.prefix(160)))
        }
        return json
    }
}
