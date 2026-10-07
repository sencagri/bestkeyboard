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
        fileprivate var modelKey: String { AppGroup.Key.aiModel(rawValue) }
    }

    private static let providerKey = AppGroup.Key.aiProvider

    /// Metin isteklerinin gittiği sağlayıcı.
    static var provider: Provider {
        get { AppGroup.store.string(forKey: providerKey).flatMap(Provider.init(rawValue:)) ?? .openai }
        set { AppGroup.store.set(newValue == .openai ? nil : newValue.rawValue, forKey: providerKey) }
    }

    // MARK: Anahtar

    static func apiKey(_ p: Provider) -> String? { secret(p.account) }

    static var apiKey: String? { apiKey(provider) }
    static var isConnected: Bool { apiKey != nil }
    /// Resim çizilebiliyor mu (OpenAI anahtarı var mı).
    static var canDraw: Bool { apiKey(.openai) != nil }

    @discardableResult
    static func setKey(_ key: String?, for p: Provider? = nil) -> Bool {
        setSecret(key, account: (p ?? provider).account)
    }

    /// Önce güncelle, yoksa ekle — eskisini silip eklerken ekleme başarısız
    /// olursa çalışan anahtar kayboluyordu. Boş değer siler; "zaten yok" da başarı.
    private static func writeKeychain(_ value: String?, query: [String: Any]) -> Bool {
        guard let v = value?.trimmed, !v.isEmpty else {
            let rc = SecItemDelete(query as CFDictionary)
            return rc == errSecSuccess || rc == errSecItemNotFound
        }
        let attrs: [String: Any] = [kSecValueData as String: Data(v.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let rc = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if rc == errSecSuccess { return true }
        guard rc == errSecItemNotFound else { return false }
        var q = query
        q[kSecValueData as String] = Data(v.utf8)
        // Yedekle başka cihaza taşınmasın: anahtar yalnız bu telefonda.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Anahtar zincirindeki sır (sağlayıcı anahtarları, Todoist token…) — ortak grup.
    static func secret(_ account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func setSecret(_ value: String?, account: String) -> Bool {
        writeKeychain(value, query: query(account: account))
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppIdentity.keychainService,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: AppIdentity.keychainGroup]
    }

    // MARK: Model

    static func model(_ p: Provider) -> String {
        AppGroup.store.string(forKey: p.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
    }
    static func setModel(_ m: String, for p: Provider) {
        AppGroup.store.set(m == p.defaultModel || m.isEmpty ? nil : m, forKey: p.modelKey)
    }
    static var model: String { model(provider) }

    // MARK: İstekler

    enum Failure: LocalizedError {
        case noKey, http(Int, String), empty, needsOpenAIForImages, keyNotSaved
        /// Model yanıt verdi ama metinde aranan şey yok (servis hatası değil).
        /// `what`: "etkinlik", "yapılacak", "kişi bilgisi"; `source`: bakılan metin.
        case nothingFound(what: String, source: String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Servis bağlı değil — uygulamada \(CommonText.aiScreen) › Bağla."
            case .keyNotSaved: return "Anahtar kaydedilemedi."
            case let .http(code, msg):
                return code == 401 ? "Anahtar geçersiz. Uygulamadan yeniden bağla." : "Servis hatası (\(code)): \(msg)"
            case .empty: return "Servis boş yanıt döndü."
            case .needsOpenAIForImages: return "Resim üretmek için OpenAI anahtarı gerekli (resimler OpenAI ile çiziliyor)."
            case let .nothingFound(what, source):
                let t = source.trimmed
                if t.isEmpty { return "Bakılacak metin yok: mesajı seç ya da kopyala, sonra tekrar dene." }
                let shown = t.count > 80 ? String(t.prefix(80)) + "…" : t
                return "Bu metinde \(what) bulamadım: “\(shown)”. Mesajı seçip ya da kopyalayıp tekrar dene."
            }
        }
    }

    /// Metin isteklerinin sistem talimatı — düzenleyicide de gösteriliyor.
    static let systemPrompt =
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
                .trimmed
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
        // Yapılandırılmış çıkarımda (tarih hesabı, madde bölme) "low" tutarsızdı —
        // aynı "Cumartesi" bir seferinde doğru, bir seferinde Çarşamba çıktı. Orada "medium".
        if p == .cerebras {
            let oss = model(p).contains("gpt-oss")
            body["reasoning_effort"] = schema != nil ? (oss ? "medium" : "low") : (oss ? "low" : "none")
        }
        let json = try await post("chat/completions", body, provider: p, timeout: 45)
        guard let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = (msg["content"] as? String)?.trimmed,
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
        get { AppGroup.store.stringArray(forKey: AppGroup.Key.reminderLists) ?? [] }
        set { AppGroup.store.set(newValue, forKey: AppGroup.Key.reminderLists) }
    }

    /// "8 yumurta, 5 kedi maması, 4 süt lazım" → üç madde, Alışveriş listesi.
    /// "Yarın 7'de Kadıköy'de buluşalım" → tek madde, yarın 19:00. Göreli
    /// zamanlar için modele **şimdi** ve saat dilimi veriliyor.
    static func reminders(from text: String, lists: [String] = reminderLists, template: String = "",
                          now: Date = Date()) async throws -> ReminderPlan {
        let prompt = reminderPrompt(text: text, lists: lists, template: template, now: now)
        let item = objectSchema(["title": stringField, "due": stringField, "notes": stringField])
        let schema = objectSchema(["list": stringField, "items": arrayField(item)])
        let obj = try jsonObject(try await complete(prompt, schema: schema))
        // Eski tek maddelik biçim de kabul ediliyor (şemasız yanıt).
        let rawItems = (obj["items"] as? [[String: Any]]) ?? [obj]
        let items: [ReminderDraft] = rawItems.prefix(30).compactMap { o in
            guard let t = nonEmpty(o["title"]) else { return nil }
            return ReminderDraft(title: t, due: parseDate(o["due"]), notes: nonEmpty(o["notes"]))
        }
        guard !items.isEmpty else { throw Failure.nothingFound(what: "yapılacak", source: text) }
        // Var olan bir listeye denk geliyorsa onun yazımı; yoksa önerilen yeni
        // ad (uygulama açacak). Boş = varsayılan liste.
        let list: String? = nonEmpty(obj["list"]).map { name in lists.first { $0.trEquals(name) } ?? String(name.prefix(40)) }
        return ReminderPlan(list: list, items: items)
    }

    /// Hatırlatıcı tuşunun varsayılan istemi — kullanıcı düzenleyicide tamamını
    /// değiştirebiliyor. Yer tutucular: `{şimdi}`, `{takvim}`, `{listeler}`, `{metin}`.
    static let reminderTemplateDefault = """
    Şu mesajdaki yapılacakları Apple Hatırlatıcılar'a eklenecek maddelere çevir.
    Şu an: {şimdi}.
    Önümüzdeki günler (tarih ve haftanın günü): {takvim}.
    Mesaj hangi dilde olursa olsun gün adlarını ve göreli ifadeleri ("yarın", "next Friday"…) bu takvimden tarihe çevir;
    bugünün haftanın hangi günü olduğunu tahmin etme, takvime bak.
    Her iş ve alınacak her şey AYRI madde: "ekmek, süt ve deterjan al" → üç madde: "Ekmek", "Süt", "Deterjan".
    Miktarı başlıkta tut ("8 yumurta"). Tek bir iş varsa tek madde. Başlıklar kısa (1-4 kelime) ve mesajın dilinde;
    mesajdan gelmeli, açıklama ya da şablon metni yazma.
    due: "YYYY-MM-DDTHH:mm". Zamanı yalnız o zamanın ait olduğu maddeye ver ("yarın faturayı yatır" → yalnız fatura);
    mesajda kendisi için gün ya da saat geçmeyen maddede due "". Gün var ama saat yoksa gün içi ifadeye göre:
    sabah 09:00, öğle 12:00, öğleden sonra 15:00, akşam 19:00, gece 21:00; hiçbiri yoksa 09:00.
    "Akşam 7" gibi ifadeleri 24 saate çevir (19:00).
    notes: gerekirse kısa not, yoksa "".
    Kullanıcının hatırlatıcı listeleri: {listeler}.
    list: maddelere uyan bir liste varsa adını AYNEN yaz. Yoksa ve birden çok madde varsa maddeleri toplayan
    kısa yeni bir liste adı yaz (ör. alınacaklar için "Alışveriş"). Tek bir iş için uygun liste yoksa boş bırak.

    Mesaj:
    {metin}
    """

    /// Hatırlatıcı istemi: şablondaki yer tutucular dolduruluyor. Boş şablon =
    /// varsayılan; `{metin}` yoksa mesaj sona ekleniyor. Düzenleyici de bunu gösteriyor.
    static func reminderPrompt(text: String, lists: [String] = reminderLists, template: String = "",
                               now: Date = Date()) -> String {
        prompt(template: template, default: reminderTemplateDefault, text: text, now: now,
               names: (.lists, lists, "henüz liste yok"))
    }

    /// Modele bağlam: "2026-10-07 Wednesday (today), 2026-10-08 Thursday (tomorrow), …".
    /// Modeller "bugün çarşamba → cumartesi kaç?" hesabında yanılıyordu
    /// ("cumartesi akşam" → "yarın 09:00"); takvimi hazır veriyoruz.
    static func calendarLines(now: Date, days: Int = 14) -> String {
        let f = DateFormats.posix("yyyy-MM-dd EEEE")
        let tr = DateFormats.turkish("EEEE")
        // Her gün ayrı satır, İngilizce + Türkçe gün adıyla: model "Cumartesi"yi satırda bulsun.
        return "\n" + (0..<days).map { i in
            let day = Calendar.current.date(byAdding: .day, value: i, to: now)!
            return "- " + f.string(from: day) + " / " + tr.string(from: day)
                + (i == 0 ? " (today / bugün)" : i == 1 ? " (tomorrow / yarın)" : "")
        }.joined(separator: "\n")
    }

    /// Sağlayıcının model listesi (`GET /v1/models`). OpenAI'de yalnız sohbet
    /// modelleri bırakılıyor — ses, resim, gömme modelleri burada işe yaramaz.
    static func listModels(_ p: Provider) async throws -> [String] {
        guard let key = apiKey(p) else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: p.baseURL + (p.isAnthropic ? "models?limit=100" : "models"))!,
                             timeoutInterval: 20)
        authorize(&req, p, key)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard HTTP.isSuccess(resp) else { throw Failure.http(HTTP.status(resp), "") }
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
            HTTP.bearer(&req, key)
        }
        if p == .openrouter { req.setValue("BestKeyboard", forHTTPHeaderField: "X-OpenRouter-Title") }
    }

    private static func post(_ path: String, _ body: [String: Any], provider p: Provider,
                             timeout: TimeInterval) async throws -> [String: Any] {
        guard let key = apiKey(p) else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: p.baseURL + path)!, timeoutInterval: timeout)
        authorize(&req, p, key)
        try HTTP.postJSON(&req, body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard HTTP.isSuccess(resp) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw Failure.http(HTTP.status(resp), String(msg.prefix(160)))
        }
        return json
    }
}

/// İstek yardımcıları — yapay zeka sağlayıcıları ve Todoist aynı kurallarla.
enum HTTP {
    /// Yanıtın durum kodu (HTTP değilse 0).
    static func status(_ resp: URLResponse) -> Int { (resp as? HTTPURLResponse)?.statusCode ?? 0 }
    static func isSuccess(_ resp: URLResponse) -> Bool { (200..<300).contains(status(resp)) }

    static func bearer(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// POST + JSON gövde.
    static func postJSON(_ req: inout URLRequest, _ body: [String: Any]) throws {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
}

/// Metin ya da resim tuşunun sonucu.
struct AIOutput {
    var text: String?
    var image: UIImage?
}

extension AIService {
    /// Metin/resim tuşunu çalıştırıp günlüğe yazar — klavye kartı, paylaşım
    /// eklentisi, dikte ekranı ve kestirme aynı yoldan. (Hatırlatıcı/Takvim/Kişi:
    /// `extract`.)
    static func run(_ a: AIAction, prompt: String, origin: AILog.Origin, source: String,
                    text: String) async throws -> (value: AIOutput, id: UUID) {
        precondition(!a.kind.isStructured, "yapılandırılmış tür `extract` ile çalışır")
        if a.kind == .image {
            let r = try await AILog.measure(origin: origin, action: a.name, source: source, text: text,
                                            summarize: { (_: UIImage) in "resim" }) { try await image(prompt) }
            return (AIOutput(image: r.value), r.id)
        }
        let r = try await AILog.measure(origin: origin, action: a.name, source: source, text: text,
                                        summarize: { (t: String) in t }) { try await complete(prompt) }
        return (AIOutput(text: r.value), r.id)
    }
}

// MARK: - Bağlantı

extension AIService {
    /// Bağla: yazıldıysa anahtar ve model kaydedilip kısa bir istekle deneniyor;
    /// olmazsa önceki anahtar ve model geri konuyor, sağlayıcı değişmiyor.
    /// `key` boşsa kayıtlı anahtarla deneniyor (yalnız sağlayıcı/model değişimi).
    static func connect(_ p: Provider, key: String, model: String) async throws {
        let previousKey = apiKey(p), previousModel = self.model(p)
        let typed = key.trimmed
        if !typed.isEmpty, !setKey(typed, for: p) { throw Failure.keyNotSaved }
        setModel(model.trimmed, for: p)
        do {
            _ = try await complete("Yalnız 'tamam' yaz.", using: p)
            provider = p
        } catch {
            setKey(previousKey, for: p)
            setModel(previousModel, for: p)
            throw error
        }
    }

    /// Anahtarı siler; etkin sağlayıcı oysa anahtarı olan başka birine geçilir.
    static func removeKey(_ p: Provider) {
        setKey(nil, for: p)
        if provider == p, let other = Provider.allCases.first(where: { apiKey($0) != nil }) { provider = other }
    }
}
