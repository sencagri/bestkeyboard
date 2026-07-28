import Foundation
import KBLexicon

/// Skor sözleşmesi §0 — **açık-vocabulary literal kanalı**.
///
/// Kullanıcının gerçekte bastığı harf dizisine `F_lex` verir. Commit kararı
/// (`Δ = cost(literal) − cost(best) > θ`) buna dayanır, dolayısıyla bu kanal
/// olmadan karar bilinmeyen kelimede tanımsız kalır.
///
/// ## Tek sahiplik
///
/// ```
/// w ∈ V  →  F_lex(w) = kanonik leksikal maliyet (form listesi ∪ morfoloji)
/// w ∉ V  →  F_lex(w) = c_unk + F_char-ngram(w | OOV)
/// ```
///
/// Aynı yüzey **asla iki kanaldan birden** maliyet almaz. Sözlükte bulunan bir
/// kelimeye karakter modelinin maliyetini de eklemek onu iki kez cezalandırır
/// ve uzun-ama-bilinen kelimeleri sistematik olarak kaybettirir.
/// `LexiconSet` `Sendable` değil (mmap'lenmiş `Data` sahipliği taşıyor), bu
/// yüzden kanal da değil. Zaten tek bir thread'den kullanılıyor: commit kararı
/// ana thread'de veriliyor.
public struct LiteralChannel {

    /// `V` — form listesi **ile** morfolojinin birleşimi. Yalnız form listesine
    /// bakmak, morfolojinin ürettiği ama listede olmayan formları bilinmeyen
    /// sayardı; tam da motoru eklerken hedeflediğimiz kelimeler korumasız kalırdı.
    private let vocabulary: LexiconSet?
    private let charModel: CharNGram?

    /// `c_unk` — sözlük dışı olmanın sabit bedeli.
    ///
    /// **Kalibre edilmemiştir.** Gerçek değeri, held-out veride yanlış düzeltme
    /// oranı hedefine göre `θ` ile birlikte oturtulacak (§6). Şimdiki değer
    /// şunu sağlıyor: tipik bir OOV token, kelime listesinin en nadir
    /// girdilerinden pahalı olsun ama orta sıklıktaki bir kelimeden ucuz olmasın.
    public var cUnk: Double

    /// Karakter modeli yokken kullanılan yedek. Bu bir **model değil**, paketin
    /// eksik olduğunu maskelemeyen bir sabit; `isCalibrated` ile ayırt edilir.
    public static let fallbackOOVCost = 14.0

    public init(vocabulary: LexiconSet?, charModel: CharNGram?, cUnk: Double = 6.0) {
        self.vocabulary = vocabulary
        self.charModel = charModel
        self.cUnk = cUnk
    }

    /// Karakter modeli yüklü mü. `false` ise `cost` yalnız kaba bir yaklaşımdır
    /// ve `θ` kalibrasyonu buna göre okunmalıdır.
    public var isCalibrated: Bool { charModel != nil }

    /// OOV token'lar otomatik düzeltilsin mi.
    ///
    /// ## Bu bir ürün kararı değil, bir ÖLÇÜM SONUCU
    ///
    /// `kbdiag --theta` iki aileyi karşılaştırdı: düzeltilmesi gereken typo'lar
    /// ve korunması gereken doğru yazılmış sözlük dışı kelimeler (özel adlar).
    /// Gerçek paketlerle çıkan sonuç:
    ///
    /// ```
    /// typo Δ aralığı          :  7.55 … 20.74
    /// doğru yazılmış Δ aralığı:  2.63 … 17.56
    /// ```
    ///
    /// **Aralıklar iç içe.** Ölçülen bu örneklemde (10 + 10 token) hiçbir tek
    /// eşik iki aileyi hatasız ayırmadı: typo'ları yakalayan her eşik
    /// `zeynepcim`'i `zeybeğim`'e çevirir, isimleri koruyan her eşik typo'ların
    /// çoğunu kaçırır. Küçük bir örneklem, popülasyon iddiası değil — ama `θ`'yı
    /// bir sayı seçerek çözebileceğimiz varsayımını çürütmeye yeter.
    ///
    /// Sözleşme §5c bu durumda ne yapılacağını yazıyor: *"Yanlış tespit maliyeti
    /// asimetrik — gereksiz koruma zararsız, gereksiz düzeltme can sıkıcı →
    /// eşik korumadan yana."* Bilinen bir kelimeyi bozmak kullanıcının güvenini
    /// kaybettirir; bir typo'yu kaçırmak yalnız yardım etmemektir.
    ///
    /// Dolayısıyla OOV token'lar **otomatik değiştirilmez**; aday öneri
    /// çubuğunda durur, kullanıcı dokunursa uygulanır. Sözlükteki kelimelerin
    /// düzeltilmesi bundan etkilenmez — orada `Δ` zaten iki bilinen kelime
    /// arasında ve kanal ölçekleri ortak.
    ///
    /// Kapının açılması üç koşula bağlı (§8.1): held-out veride yanlış-düzeltme
    /// hedefinin sağlanması, **yeni bir ayırt edici sinyal** (yalnız `θ`/`c_unk`
    /// yeniden fit etmek yetmez — iç içe iki aile tek eşikle ayrılamaz) ve o
    /// sinyalin karar modeline sokulması.
    public var autoCorrectsOutOfVocabulary = false

    public struct Score: Equatable, Sendable {
        /// Ham `F_lex` — `w_lex` ile çarpılmamış.
        public var lexCost: Double
        /// Token leksikonda mı. Öyleyse `θ = ∞` (bilinen kelime bozulmaz).
        public var isInVocabulary: Bool
        /// Uzunluk sınırı aşıldı → literal koruma, `θ = ∞` (§0 taşma kuralı).
        public var overflowed: Bool
        /// Sözlük dışı olduğu için korunuyor. İki ayrı sebep aynı sonucu verir:
        /// ürün kapısı kapalı (§8.1) **ya da** karakter modeli hiç yüklü değil.
        /// İkincisi bağımsız bir koşul — kapı elle açılsa bile kalibre olmayan
        /// bir yedek sabitle otomatik düzeltme yapılmamalı.
        public var protectedByOOVGate: Bool

        /// Commit kararında literal'in dokunulmaz sayılıp sayılmayacağı.
        public var demandsProtection: Bool {
            isInVocabulary || overflowed || protectedByOOVGate
        }
    }

    /// Token'ın leksikal maliyeti.
    ///
    /// **Her sonlu Unicode token'ı sonlu maliyet alır** — bu bir test kapısıdır
    /// (§Doğrulama). Sonsuz dönen tek bir yol `Δ`'yı tanımsız bırakır.
    public func score(_ token: String) -> Score {
        guard !token.isEmpty else {
            return Score(lexCost: 0, isInVocabulary: false,
                         overflowed: false, protectedByOOVGate: false)
        }
        // Kapı **ve** kalibrasyon: ikisi ayrı koşul, ikisi de gerekli.
        let oovProtected = !autoCorrectsOutOfVocabulary || charModel == nil
        // §7 kanonik yüzey kimliği: leksikal anahtar NFC-normalize edilmiş
        // yüzeydir. Normalize etmeden sorgulamak, `ç` ayrık yazıldığında aynı
        // kelimeyi hem sözlükte bulamamaya hem karakter modelinde OOV cezası
        // almaya yol açardı — üstelik `FormTrie.lookup` kendi içinde normalize
        // ettiği için hata yalnız morfoloji ve n-gram tarafında görünürdü.
        let key = token.precomposedStringWithCanonicalMapping

        if let raw = vocabulary?.lexCost(ofSurface: key) {
            return Score(lexCost: raw, isInVocabulary: true,
                         overflowed: false, protectedByOOVGate: false)
        }
        guard let m = charModel else {
            return Score(lexCost: Self.fallbackOOVCost, isInVocabulary: false,
                         overflowed: false, protectedByOOVGate: true)
        }
        let s = m.score(key)
        return Score(lexCost: cUnk + s.cost, isInVocabulary: false,
                     overflowed: s.overflowed, protectedByOOVGate: oovProtected)
    }
}
