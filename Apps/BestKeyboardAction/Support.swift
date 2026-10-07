import Foundation

// Paylaşım eklentisinde uygulamanın büyük ayar deposu ve bildirimleri yok;
// ortak dosyaların (AIService, AIExtract, Makers…) istediği küçük parçalar.

enum KeyboardSettingsStore {
    static let appGroup = "group.com.sencagri.bestkeyboard"

    /// Kullanıcının yapay zeka tuşları (uygulamadaki listeyle aynı); kayıt yoksa varsayılanlar.
    static func aiActions() -> [AIAction] {
        UserDefaults(suiteName: appGroup)?.data(forKey: "kb.ai.actions")
            .flatMap { try? JSONDecoder().decode([AIAction].self, from: $0) }
            .map(AIAction.upgradingTemplates) ?? AIAction.defaults
    }
}

/// Eklentide bildirim yok: sonuç kartın kendisinde gösteriliyor.
final class Notifier {
    static let shared = Notifier()
    func post(title: String, body: String, url: URL?) async {}
}
