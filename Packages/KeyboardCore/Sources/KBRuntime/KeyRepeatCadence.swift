/// Basılı tutma tekrarının **zamanlama politikası**.
///
/// Görünümden ayrı durmasının sebebi: kullanıcıya doğrudan toplu silme
/// uygulayan bir mekanizma bu; kademe geçişinin doğruluğu `Timer` ateşlemesini
/// beklemeden sınanabilmeli. Görünüme kalan iş yalnız zamanlayıcıyı kurmak ve
/// dokunmayı iletmek.
public struct KeyRepeatCadence: Sendable {

    public enum Stage: Sendable, Equatable {
        /// Karakter karakter.
        case character
        /// Kelime kelime — basılı tutma sürdüğünde.
        case word
    }

    /// İlk tekrara kadar beklenen süre. Yanlışlıkla tekrarı önler: normal bir
    /// dokunuş bunun çok altında.
    public var initialDelay: Double = 0.45
    /// Karakter kademesi aralığı.
    public var characterInterval: Double = 0.085
    /// Kelime kademesi aralığı. Karakter hızında kelime silmek kullanıcıya
    /// nerede durduğunu göstermez; bilerek yavaş.
    public var wordInterval: Double = 0.22
    /// Kaç karakter tekrarından sonra kelime kademesine geçilir (~1.2 sn).
    public var charactersBeforeWordStage = 14

    public init() {}

    /// `tick` 1'den başlar; 1. tekrar `initialDelay` sonra gelir.
    public func stage(forTick tick: Int) -> Stage {
        tick <= charactersBeforeWordStage ? .character : .word
    }

    /// `tick` numaralı tekrar ateşlendikten sonra bir sonrakine kadar beklenecek süre.
    ///
    /// Aralık **bir sonraki** tekrarın kademesinden okunur; yoksa kelime
    /// kademesinin ilk silmesi hâlâ karakter hızında gelirdi.
    public func interval(afterTick tick: Int) -> Double {
        stage(forTick: tick + 1) == .character ? characterInterval : wordInterval
    }
}
