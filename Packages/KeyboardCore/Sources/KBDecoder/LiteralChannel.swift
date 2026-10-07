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
    private var vocabulary: LexiconSet?
    /// Karakter modelleri — **dil başına**.
    ///
    /// Tek model, iki dilli kurulumda yanlıştı: `en-US.bkc` üretiliyor ama
    /// hiç kullanılmıyordu ve İngilizce sözlük dışı kelimeler **Türkçe**
    /// modelle puanlanıyordu. Türkçe modele göre `awkward` implausible görünür,
    /// `cost(literal)` şişer, `Δ` büyür ve kelime düzeltilir.
    ///
    /// Sözlük dışı bir token'ın dili **bilinmiyor** (tanımı gereği). Doğru
    /// yüklem "aktif dillerden **en az birinde** makul mü": maliyet modellerin
    /// **minimumu**. Tek modelde bu mevcut davranışa indirgenir.
    private let charModels: [CharNGram]

    /// `c_unk` — sözlük dışı olmanın sabit bedeli.
    ///
    /// **Kalibre edilmemiştir.** Gerçek değeri, held-out veride yanlış düzeltme
    /// oranı hedefine göre `θ` ile birlikte oturtulacak (§6). Şimdiki değer
    /// şunu sağlıyor: tipik bir OOV token, kelime listesinin en nadir
    /// girdilerinden pahalı olsun ama orta sıklıktaki bir kelimeden ucuz olmasın.
    public var cUnk: Double

    /// Sözlük dışı token'ın dili — referans dil.
    ///
    /// Bilinmeyen bir kelimenin dilini seçmek ayrı bir sınıflandırma problemi;
    /// `V` dışındayken elde kanıt yok.
    ///
    /// **Bu seçim nötr DEĞİL:** referans dilin de bir önseli var ve önceki
    /// kelime başka dildeyse `w_switch` cezası doğuyor. Yani OOV bir token
    /// örtük olarak referans dile atanmış oluyor. Şu an zararsız — OOV
    /// otomatik düzeltme kapısı kapalı (§8.1), dolayısıyla bu maliyet hiçbir
    /// commit kararını çevirmiyor. Kapı açılmadan önce ya açık bir "dil
    /// bilinmiyor" durumu tanımlanıp `F_lang` uygulanmamalı, ya da dil
    /// marjinalize edilmeli.
    public static let oovLanguage = Language.reference

    /// Karakter modeli yokken kullanılan yedek. Bu bir **model değil**, paketin
    /// eksik olduğunu maskelemeyen bir sabit; `isCalibrated` ile ayırt edilir.
    public static let fallbackOOVCost = 14.0

    /// Dil terimleri — decoder ile **aynı** `LanguageModel` verilmelidir.
    /// Ayrışırlarsa `Δ = cost(literal) − cost(best)` iki farklı formülün farkı
    /// olur ve commit kararı sessizce kayar.
    public var languageModel = LanguageModel()
    public var weights = ScoreWeights()

    /// Kelime bigramı — decoder ile **aynı** paket ve **aynı** bağlam.
    ///
    /// Ayrı bırakılamaz: `Δ = cost(literal) − cost(best)` iki tarafı da `F_ctx`
    /// taşımalı. Yalnız decoder tarafına eklemek, bağlamın beklediği bir adayı
    /// ucuzlatırken literal'i olduğu yerde bırakır ve `Δ` bağlam gücü kadar
    /// şişer — yani `θ` eşiği sessizce düşmüş olurdu.
    ///
    /// Sözlük **dışı** bir literal için `F_ctx = 0` kalır: paket yalnız
    /// gördüğü yüzeyleri taşıyor ve OOV bir token orada yok. Bu, kanalın OOV
    /// tarafındaki `c_unk + karakter modeli` yolunun bağlamdan etkilenmemesi
    /// demek — bilinçli, çünkü bağlam kanıtı yalnız bilinen kelimeler için var.
    public var bigrams: BigramPack?
    public var contextWord: String?

    public init(vocabulary: LexiconSet?, charModel: CharNGram?, cUnk: Double = 6.0) {
        self.init(vocabulary: vocabulary,
                  charModels: charModel.map { [$0] } ?? [],
                  cUnk: cUnk)
    }

    /// Çoklu dil: her aktif dilin karakter modeli verilir.
    public init(vocabulary: LexiconSet?, charModels: [CharNGram], cUnk: Double = 6.0) {
        self.vocabulary = vocabulary
        self.charModels = charModels
        self.cUnk = cUnk
    }

    /// Karakter modeli yüklü mü. `false` ise `cost` yalnız kaba bir yaklaşımdır
    /// ve `θ` kalibrasyonu buna göre okunmalıdır.
    public var isCalibrated: Bool { !charModels.isEmpty }

    /// `V`'yi değiştirir — kişisel sözlüğe kelime kabul edildiğinde (§8.7).
    ///
    /// **Decoder ile birlikte** çağrılmalıdır. Ayrı bırakılırsa `Δ = cost(literal)
    /// − cost(best)` iki farklı sözlüğün farkı olur: decoder kişisel kelimeyi
    /// aday üretir ama kanal onu hâlâ OOV sayıp `c_unk` + karakter modeliyle
    /// puanlar, yani `Δ` şişer ve kelime tam da korumaya alındığı anda
    /// düzeltilmeye açık kalır. `InputCoordinator.applyPersonalLexicon`
    /// ikisini tek adımda değiştiriyor; başka çağıran olmamalı.
    public mutating func setVocabulary(_ v: LexiconSet?) { vocabulary = v }

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
        /// Kazanan dil (sözlükteyse). Sözlük dışında referans dil (0).
        public var language: UInt8
        /// Kazanan eşleşmenin `offset_ℓ`'si — `totalLexicalCost` bunu kullanır.
        public var offset: Double

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
            return Score(lexCost: 0, isInVocabulary: false, overflowed: false,
                         language: Self.oovLanguage, offset: 0,
                         protectedByOOVGate: false)
        }
        // Kapı **ve** kalibrasyon: ikisi ayrı koşul, ikisi de gerekli.
        let oovProtected = !autoCorrectsOutOfVocabulary || charModels.isEmpty
        // §7 kanonik yüzey kimliği: leksikal anahtar NFC-normalize edilmiş
        // yüzeydir. Normalize etmeden sorgulamak, `ç` ayrık yazıldığında aynı
        // kelimeyi hem sözlükte bulamamaya hem karakter modelinde OOV cezası
        // almaya yol açardı — üstelik `FormTrie.lookup` kendi içinde normalize
        // ettiği için hata yalnız morfoloji ve n-gram tarafında görünürdü.
        let key = token.precomposedStringWithCanonicalMapping

        // Kazanan dil, decoder'ınkiyle **aynı** ölçütle seçilir: ham `F_lex`
        // `w_lex` ile çarpılır, üstüne dil terimleri eklenir. Ham maliyette
        // minimum almak farklı bir dil seçebilirdi.
        if let matches = vocabulary?.matches(ofSurface: key), !matches.isEmpty {
            var bestTotal = Double.infinity
            var bestRaw = 0.0
            var bestLang = Self.oovLanguage
            var bestOffset = 0.0
            for m in matches {
                let total = weights.wLex * m.lexCost
                    + languageModel.cost(language: m.language, offset: m.offset,
                                         weights: weights)
                if total < bestTotal || (total == bestTotal && m.language < bestLang) {
                    bestTotal = total; bestRaw = m.lexCost
                    bestLang = m.language; bestOffset = m.offset
                }
            }
            return Score(lexCost: bestRaw, isInVocabulary: true, overflowed: false,
                         language: bestLang, offset: bestOffset,
                         protectedByOOVGate: false)
        }
        guard !charModels.isEmpty else {
            return Score(lexCost: Self.fallbackOOVCost, isInVocabulary: false,
                         overflowed: false, language: Self.oovLanguage,
                         offset: 0, protectedByOOVGate: true)
        }
        // Aktif dillerin **minimumu**: token hangi dilde makulse o dilde
        // ölçülür. Taşma bayrağı uzunluk sınırından geliyor ve modelden
        // bağımsız olarak aynı; kazananınki alınıyor.
        var best = charModels[0].score(key)
        for m in charModels.dropFirst() {
            let s = m.score(key)
            if s.cost < best.cost { best = s }
        }
        return Score(lexCost: cUnk + best.cost, isInVocabulary: false,
                     overflowed: best.overflowed, language: Self.oovLanguage,
                     offset: 0, protectedByOOVGate: oovProtected)
    }

    /// Bu skorun **tam** maliyeti: `w_lex · F_lex + F_lang + w_ctx · F_ctx`.
    ///
    /// Decoder'ın aday maliyetiyle karşılaştırılabilir tek büyüklük budur;
    /// çağıran uzamsal terimi ve `w_len`'i ekler.
    ///
    /// - Parameter token: `F_ctx` yüzeye bağlı olduğu için gerekiyor; `Score`
    ///   yüzeyi taşımıyor. Verilmezse bağlam terimi **uygulanmaz** — eski
    ///   çağrı yerleri (bağlamı olmayan teşhis yolları) aynı sayıyı almaya
    ///   devam etsin diye.
    public func totalLexicalCost(_ s: Score, token: String? = nil) -> Double {
        weights.wLex * s.lexCost
            + languageModel.cost(language: s.language, offset: s.offset, weights: weights)
            + weights.wCtx * contextDelta(of: token)
    }

    /// `F_ctx(token | ctx)` — ham. Paket ya da bağlam yoksa 0.
    public func contextDelta(of token: String?) -> Double {
        guard let pack = bigrams, let ctx = contextWord, let token,
              let c = pack.id(of: ctx), let w = pack.id(of: token) else { return 0 }
        return pack.delta(context: c, word: w)
    }
}
