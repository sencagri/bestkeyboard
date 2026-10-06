import Foundation
import Security
import UIKit

/// "Klavyede sonuç al" — yapay zeka tuşlarının servis bağlantısı (OpenAI).
///
/// Anahtar **anahtar zincirinde**, uygulama ile klavyenin ortak erişim
/// grubunda: uygulama yazıyor, klavye (Tam Erişimle) okuyor. Ortak klasördeki
/// bir dosyaya koymak daha kolaydı ama bir parola dosyada durmamalı.
enum AIService {
    static let keychainGroup = "KQQ4W7T779.com.sencagri.bestkeyboard.shared"
    private static let account = "openai"
    private static let modelKey = "kb.ai.model"
    static let defaultModel = "gpt-4.1-mini"
    static let imageModel = "gpt-image-1"

    // MARK: Anahtar

    static var apiKey: String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static var isConnected: Bool { apiKey != nil }

    @discardableResult
    static func setKey(_ key: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var q = baseQuery
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sencagri.bestkeyboard.ai",
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: keychainGroup]
    }

    // MARK: Model

    private static var shared: UserDefaults { UserDefaults(suiteName: KeyboardSettingsStore.appGroup) ?? .standard }
    static var model: String {
        get { shared.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel }
        set { shared.set(newValue == defaultModel ? nil : newValue, forKey: modelKey) }
    }

    // MARK: İstekler

    enum Failure: LocalizedError {
        case noKey, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey: return "Servis bağlı değil — uygulamada Yapay zeka tuşları › Bağla."
            case let .http(code, msg):
                return code == 401 ? "Anahtar geçersiz. Uygulamadan yeniden bağla." : "Servis hatası (\(code)): \(msg)"
            case .empty: return "Servis boş yanıt döndü."
            }
        }
    }

    /// Metin: istem → tek yanıt.
    static func complete(_ prompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Bir klavyenin içinden çağrılıyorsun. Yalnız istenen çıktıyı ver: açıklama, tırnak ya da başlık ekleme."],
                ["role": "user", "content": prompt],
            ],
        ]
        let json = try await post("chat/completions", body, timeout: 45)
        guard let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw Failure.empty }
        return text
    }

    /// Resim: istem → kare PNG.
    static func image(_ prompt: String) async throws -> UIImage {
        let body: [String: Any] = ["model": imageModel, "prompt": prompt, "size": "1024x1024", "n": 1]
        let json = try await post("images/generations", body, timeout: 120)
        guard let data = (json["data"] as? [[String: Any]])?.first,
              let b64 = data["b64_json"] as? String, let d = Data(base64Encoded: b64),
              let img = UIImage(data: d) else { throw Failure.empty }
        return img
    }

    private static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let key = apiKey else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/" + path)!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
