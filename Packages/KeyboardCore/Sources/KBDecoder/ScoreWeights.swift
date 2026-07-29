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
    /// **Tekrar insertion'ı**: fazladan dokunma, en son emit edilen karakterin
    /// tuşuna düşüyor — `çoookk`, `evettt`, `bakkk`.
    ///
    /// Sözleşme §2'nin `F_ins,k` sınıflarına eklenen üçüncü sınıf. Plan sınıf
    /// sayısını sabitlemiyor: *"sınıf sayısı, veri miktarına göre ablation ile
    /// belirlenir"*. Bu sınıfın gerekçesi ölçüldü — mevcut iki sınıfla uzatmalar
    /// 8 vakanın yalnız 3'ünde çözülüyordu ve `bakkk → hakkı` gibi düpedüz
    /// yanlış sonuçlar çıkıyordu.
    ///
    /// Ayırt edici sinyal **zamanlama değil kimlik**: `wInsNear` `Δt < τ_fast`
    /// istiyor, ama kullanıcı harfi bilerek uzatırken kendi temposunda basıyor.
    /// Aynı tuşa tekrar basmak niyeti tek başına belli ediyor.
    public var wInsRepeat: Double = 1.0
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

    /// **Arama sezgiseli** (model terimi DEĞİL): art arda en fazla kaç omission
    /// zincirlenebilir.
    ///
    /// Sözleşme §2.5 sabit bütçeleri reddediyordu — ama şu şartla: *"Profil bir
    /// üst sınır gerektirirse, o zaman arama sezgiseli olarak eklenir ve bu
    /// belgeye kaydedilir."* Profil gerektirdi.
    ///
    /// Ölçüm: kapanış sınırsızken tuş başına 28.459 durum üretiliyordu (beam
    /// 128 ile ~222 ark/durum, ki bu ancak kapanışın onlarca kez dönmesiyle
    /// olur). Art arda 4'ten fazla harfi hiç yazmadan atlamak gerçek bir
    /// kullanıcı davranışı değil.
    ///
    /// **Model terimi olmadığı için dedup anahtarına GİRMEZ** — girseydi aynı
    /// duruma farklı omission geçmişiyle varan yollar yanlış ayrışırdı. Bu
    /// yüzden sınır yalnız kapanış döngüsünün derinliğini kesiyor, durumu
    /// etiketlemiyor.
    public var maxConsecutiveOmissions = 4

    /// Aday tuş budaması (§3): dokunma başına en fazla kaç tuş denensin.
    public var maxKeyCandidates = 6
    /// Aday budama penceresi: en iyi adaydan kaç nat uzağa kadar denensin.
    public var candidateCostWindow: Double = 8.0

    /// `Δt < τ_fast` ve `dist < d_near` — insertion sınıflandırma eşikleri.
    public var tauFast: Double = 0.060
    public var dNear: Double = 0.05

    public init() {}

    /// Bütün parametrelerin ad → değer eşlemesi — sözleşme §12 kaydı için.
    ///
    /// **Yansımayla** üretiliyor, elle yazılmıyor. Elle yazılan bir eşleme,
    /// yeni bir ağırlık eklendiğinde onu sessizce düşürürdü ve replay farkı
    /// "kod regresyonu" diye raporlanırdı — oysa sebep kayda hiç girmemiş bir
    /// parametre olurdu. Yansıma pahalı ama deneme başına bir kez çağrılıyor.
    ///
    /// Sayısal olmayan bir alan eklenirse burada **kaybolur**; testi bunu
    /// yakalıyor (`ScoreWeightsRecordingTests`).
    public var dictionary: [String: Double] {
        var out: [String: Double] = [:]
        for child in Mirror(reflecting: self).children {
            guard let name = child.label else { continue }
            switch child.value {
            case let v as Double: out[name] = v
            case let v as Int:    out[name] = Double(v)
            default: continue
            }
        }
        return out
    }

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
