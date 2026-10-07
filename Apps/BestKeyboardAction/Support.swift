import Foundation

// Paylaşım eklentisinde uygulamanın büyük ayar deposu ve bildirimleri yok;
// ortak dosyaların (AIService, AIExtract, Makers…) istediği küçük parçalar.

enum KeyboardSettingsStore {
    /// Kullanıcının yapay zeka tuşları — uygulama ve klavyeyle aynı kural (`AIActionStore`).
    static func aiActions() -> [AIAction] { AIActionStore.load(from: AppGroup.defaults ?? .standard) }
}

/// Eklentide bildirim yok: sonuç kartın kendisinde gösteriliyor.
final class Notifier {
    static let shared = Notifier()
    func post(title: String, body: String, url: URL?) async {}
}
