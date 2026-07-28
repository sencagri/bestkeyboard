import Foundation

/// `F_lang` — skor sözleşmesi §5b'nin dil terimleri, **tek tanım**.
///
/// Decoder ve literal kanalı bu aynı fonksiyonu çağırır. İki yerde ayrı ayrı
/// kurulsaydı `Δ = cost(literal) − cost(best)` iki farklı formülün farkı olurdu
/// ve commit kararı sessizce kayardı.
///
/// ```
/// F_lang(ℓ) = w_lang · (−log P(ℓ|oturum))  +  w_switch · [ℓ ≠ ℓ_önceki]  +  offset_ℓ
/// ```
///
/// **`offset` kendi katsayısını taşımaz.** §0 düz öznitelik vektörü istiyor:
/// tek seviyeli katsayılar, dış ağırlık × iç ağırlık yok. `w_lang · offset`
/// yazmak `w_lang` değiştiğinde paket kalibrasyonunu da kaydırırdı — oysa
/// offset pakete ait sabit bir düzeltmedir, ağırlık ayarından bağımsızdır.
public struct LanguageModel: Sendable {

    /// `−log P(ℓ | oturum)` — **çalışma anında öğrenilir**.
    /// Boş = düzgün dağılım (her dil 0 nat).
    public var prior: [UInt8: Double] = [:]

    /// Önceki **kelimenin** dili. `nil` → geçiş cezası yok (oturumun ilki).
    ///
    /// Kelime içinde değişmez: bir token tek bir dile aittir. Token sınırında
    /// güncellenir; bu, artımlı decode'un "model sabit" varsayımıyla uyumlu
    /// olmasının da tek yolu (§5b model sürümleme).
    public var previous: UInt8?

    public init(prior: [UInt8: Double] = [:], previous: UInt8? = nil) {
        self.prior = prior
        self.previous = previous
    }

    /// Bir dilin kelime başına sabit maliyeti.
    ///
    /// - Parameter offset: kaynağın paketten gelen `offset_ℓ`'si.
    public func cost(language: UInt8, offset: Double, weights: ScoreWeights) -> Double {
        let p = weights.wLang * (prior[language] ?? 0)
        let sw = (previous != nil && previous != language) ? weights.wSwitch : 0
        return p + sw + offset
    }
}
