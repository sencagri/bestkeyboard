import Foundation

/// Skor sözleşmesi §2 — 16 öznitelik ailesi, 2 aktif dilde 15 serbest skaler parametre.
///
/// Sabitlenmiş: `w_spa ≡ 1` (ölçek gauge'ı), `offset_tr ≡ 0` (dil gauge'ı).
///
/// **Uyarı:** buradaki varsayılanlar gerçek dokunma verisiyle öğrenilmiş değildir;
/// §6'daki "yeterli veri yokken varsayılanlar" kuralına uyar — edit sınıfları
/// birleşik ve `wLen = 0` (işaret veriyle belirlenene kadar nötr).
public struct ScoreWeights: Sendable {
    // Uzamsal — wSpa sabit 1, tabloda yok.
    public var wSpaEq: Double = 0.9
    public var wEq: Double = 1.2

    // Edit — `-1A₁`'de sınıflar birleşik tutulur (§6.2 korelasyon uyarısı).
    public var wOmGem: Double = 2.0
    public var wOmInit: Double = 5.0
    public var wOm: Double = 4.5
    public var wInsNear: Double = 2.5
    public var wIns: Double = 4.5
    public var wInsBg: Double = 1.0

    public var wTr: Double = 5.0

    /// Emisyon başına. Beklenen işaret negatif (§6.1) ama bu bir **ampirik prior**;
    /// veriyle belirlenene kadar nötr. Negatif değer yalnız (I2) sağlanırsa meşrudur.
    public var wLen: Double = 0.0

    /// **Kısıt: > 0** — maliyet itmenin admissible alt sınır üretmesi buna bağlı (§7.1).
    public var wLex: Double = 1.0

    public var wCtx: Double = 1.0
    public var wLang: Double = 1.0
    public var wSwitch: Double = 3.0

    /// `Δt < τ_fast` ve `dist < d_near` — insertion sınıflandırma eşikleri.
    public var tauFast: Double = 0.060
    public var dNear: Double = 0.05

    public init() {}

    /// (I2) Emisyon başına kesin pozitif net maliyet — §2.5.
    ///
    /// `w_om_min + w_len + w_lex · ΔF_lex_min > 0`
    ///
    /// Emisyon-only (`OM`) yolların sonlu ve aşağıdan sınırlı olmasını garanti eder.
    /// Paket üretiminde denetlenir; sağlanmazsa üretim başarısız olur.
    public func satisfiesTerminationInvariant(minLexDelta: Double) -> Bool {
        let wOmMin = min(wOmGem, min(wOmInit, wOm))
        return wOmMin + wLen + wLex * minLexDelta > 0
    }

    /// `w_lex > 0` kısıtı (§7.1).
    public var satisfiesLexPositivity: Bool { wLex > 0 }
}
