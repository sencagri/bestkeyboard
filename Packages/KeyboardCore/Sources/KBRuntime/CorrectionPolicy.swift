import KBGeometry
import KBSpatial
import KBDecoder

/// Otomatik düzeltme kararının **saf** hâli — skor sözleşmesi §8'in tek karar
/// fonksiyonu:
///
///     Δ = cost(literal) − cost(bestCandidate)
///     değiştir  ⟺  Δ > θ(literal, ctx)
///
/// ## Neden ayrı bir tip
///
/// Karar `InputCoordinator`'ın `private` yöntemlerindeydi ve `kbdiag --theta`
/// eşiği ölçerken `cost(literal)`'i **kendi** formülüyle yeniden kuruyordu:
/// dil önselini ve bağlam terimini atlıyor, korumayı da yalnız "sözlükte mi /
/// taştı mı" diye soruyordu. Yani `θ`'yı seçen ölçüm, klavyenin uyguladığından
/// başka bir `Δ` dağılımına bakıyordu. Kural tek yerde olunca ölçüm ile
/// uygulama aynı şeyi konuşuyor.
///
/// Koordinatör yalnız **hangi token'ın** yargılanacağına karar veriyor
/// (türetilmiş ya da kopuk kanıt, boş yüzey); yargının kendisi burada.
public struct CorrectionPolicy: Equatable, Sendable {

    /// Sözlük dışı literal için düzeltme eşiği (§8.1.1).
    ///
    /// **17.0 → 14.60.** Eski değer o günkü ölçümde "korunmalı" ailesinin
    /// maksimumunun (16.98) hemen üstüydü. Bugünkü `kbdiag --theta` aynı
    /// aileyi 14.60'ta bitiriyor: typo'ların %87'si düzelir, doğru yazılmış
    /// kelimelerin **%0**'ı bozulur. 17'de kalmak %82'ye razı olmak demekti.
    ///
    /// Gerçek pay ölçümden **daha geniş**: teşhis aracı yalnız form trie ile
    /// karakter modelini yüklüyor, kök paketini görmüyor. `mustafam`,
    /// `ahmete`, `zeynepten` artık morfolojiden türüyor, yani `isInVocabulary`
    /// ile θ=∞ alıyorlar ve eşiğin onları koruması gerekmiyor. "Korunmalı"
    /// ailesinin asıl büyük kısmı çekimli isimlerdi ve o kısım artık sözlükte.
    public var oovTheta = 14.60

    public init(oovTheta: Double = 14.60) {
        self.oovTheta = oovTheta
    }

    /// Düzeltme kararının **gerekçesiyle birlikte** hâli.
    ///
    /// Eskiden yalnız sonuç dönüyordu; `Δ` ve `θ` yerel değişkenlerde kalıp
    /// atılıyordu. Karar aynı, yalnız hesaplananlar artık çağırana ulaşıyor
    /// (§12.1: klavyenin hangi kararı neden verdiğini kaydedebilmek için).
    struct Decision {
        var word: String?
        var delta: Double?
        var theta: Double?
        var bestCost: Double?
        var bestWord: String?
        /// Literal `V` dışında mıydı — kişisel sözlük kanıtı (§8.7) için.
        ///
        /// Kararla **birlikte** taşınıyor: `matches(ofSurface:)` morfoloji
        /// üzerinde yüzey yürüyüşü yapıyor ve aynı soruyu commit yolunda ikinci
        /// kez sormak o işi boşuna tekrarlardı.
        var literalIsOOV = false

        /// Karar **hiç sorulmadı** — `Δ`/`θ` yok, düzeltme yok.
        static let notAsked = Decision()
    }

    /// Yargılanabilir bir token için kararı verir.
    ///
    /// Kanal bir kez sorgulanır: `matches(ofSurface:)` morfoloji üzerinde
    /// yüzey yürüyüşü yapıyor, iki kez çağırmak o işi boşuna tekrarlardı.
    func decide(literal: String, touches: [TouchSample], best: DecodeResult,
                engine: InputCoordinator.Engine, layout: KeyLayout,
                fieldProtectsLiteral: Bool) -> Decision {
        let score = engine.literalChannel.score(literal)
        let delta = Self.costOfLiteral(literal, touches: touches, score: score,
                                       layout: layout, decoder: engine.decoder,
                                       channel: engine.literalChannel) - best.cost
        let th = theta(score, literal: literal,
                       fieldProtectsLiteral: fieldProtectsLiteral)
        return Decision(word: delta > th ? best.word : nil,
                        delta: delta, theta: th,
                        bestCost: best.cost, bestWord: best.word,
                        literalIsOOV: !score.isInVocabulary)
    }

    /// `cost(literal)` — §0 açık-vocabulary literal kanalı üzerinden.
    ///
    /// `w_lex · F_lex + F_lang + w_ctx · F_ctx` — decoder'ın aday maliyetiyle
    /// **aynı** terimler. Bağlam terimini yalnız bir tarafa eklemek `Δ`'yı
    /// sessizce kaydırırdı (§2 öznitelik 13).
    public static func costOfLiteral(_ literal: String,
                                     touches: [TouchSample],
                                     score: LiteralChannel.Score,
                                     layout: KeyLayout,
                                     decoder: Decoder,
                                     channel: LiteralChannel) -> Double {
        let chars = Array(literal)
        // `ComposingSession` değişmezi: dokunma `i`, literal karakter `i`'nin
        // kanıtıdır.
        assert(touches.count == chars.count)
        let spatial = zip(touches, chars).reduce(0.0) { acc, pair in
            let (t, ch) = pair
            guard let k = layout.keyIndex(for: ch) else { return acc }
            return acc + decoder.spatial.negLogP(t, keyIndex: k)
        }
        return spatial + channel.totalLexicalCost(score, token: literal)
            + decoder.weights.wLen * Double(chars.count)
    }

    /// `θ(literal, ctx)` — artan koruma eşiği (§8).
    public func theta(_ score: LiteralChannel.Score, literal: String,
                      fieldProtectsLiteral: Bool) -> Double {
        // Bilinen kelime bozulmaz; uzunluk sınırını aşan token literal korumaya
        // düşer; kalibre edilmemiş OOV de korunur. Üçü de kanalın kendi kararı.
        if score.demandsProtection { return .infinity }
        // Kod/literal token koruma kuralları (§5c A/B).
        if Self.isProtectedToken(literal) { return .infinity }
        if fieldProtectsLiteral { return .infinity }
        return oovTheta
    }

    /// §5c A: rakam/`_`/`.`/`/`/`\`/`:`/`-` içeren, karışık büyük-küçük harfli,
    /// kısa TAMAMI BÜYÜK, `@`/`#` ile başlayan token'lar düzeltilmez.
    public static func isProtectedToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.hasPrefix("@") || s.hasPrefix("#") { return true }
        if s.contains(where: { "0123456789_./\\:-".contains($0) }) { return true }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        if hasUpper && hasLower { return true }
        if hasUpper && !hasLower && s.count <= 4 { return true }
        return false
    }
}
