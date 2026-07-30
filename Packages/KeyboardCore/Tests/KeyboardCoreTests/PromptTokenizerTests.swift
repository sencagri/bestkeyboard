import Foundation
import Testing
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions

/// Ortak tokenizer — plan v8 §2.3, baseline A5'in kapanışı.
///
/// Kural `PromptCorpus.words` içinde `Apps/` altında yaşıyordu ve yalnız
/// boşluktan bölüp **uç** noktalamayı sıyırıyordu. A5 testi bunu
/// `withKnownIssue` altında donduruyordu ama gerçek `PromptCorpus`u çağırmayan
/// **yerel bir kopyayı** sınıyordu — yani kuralın kendisi hiç test edilmiyordu.
@Suite("Hedef tokenizer'ı")
struct PromptTokenizerTests {

    private let tokenizer = PromptTokenizer(layout: RecordingTestSupport.layout)

    // MARK: - Maksimal layout-harf dizileri

    /// **A5.** İç ayırıcı token'ı bölüyor.
    ///
    /// Bölmediğinde `Wi-Fi` tek hedef sayılıyordu; kullanıcı `-` tuşuna
    /// bastığında `insertSymbol` token'ı kapatıp cursor'ı ilerletiyor, `Fi` bir
    /// sonraki hedefe bağlanıyor ve cümlenin **kalanı kayıyor**.
    @Test("İç ayırıcı token'ı bölüyor")
    func internalSeparatorsSplit() {
        #expect(tokenizer.tokens(of: "Wi-Fi şifresi") == ["wi", "fi", "şifresi"])
        #expect(tokenizer.tokens(of: "Caddesi'ne") == ["caddesi", "ne"])
        #expect(tokenizer.tokens(of: "iki, üç ve dört.") == ["iki", "üç", "ve", "dört"])
    }

    /// Rakam da ayırıcı: klavyede harf düzleminde yok.
    @Test("Rakamlar ayırıcı sayılıyor")
    func digitsAreSeparators() {
        #expect(tokenizer.tokens(of: "saat 12de") == ["saat", "de"])
    }

    /// **Ölçüt "harf olmak" değil, layout'ta bulunmak.**
    ///
    /// Klavyede olmayan bir karakteri kullanıcı yazamaz; hedefin parçası saymak
    /// yazılamaz bir hedef üretmek olur. `é` bir harf ama bu layout'ta tuşu yok.
    @Test("Layout dışı harf ayırıcı")
    func charactersOutsideTheLayoutSplit() throws {
        try #require(RecordingTestSupport.layout.keyIndex(for: "é") == nil)
        #expect(tokenizer.tokens(of: "aéb") == ["a", "b"])
        // Kontrol: aynı konumdaki layout harfi bölmüyor.
        #expect(tokenizer.tokens(of: "aeb") == ["aeb"])
    }

    // MARK: - Küçültme ve normalizasyon

    /// **A5'in ikinci yüzü.** Büyük harfli hedefte bütün örnekler düşüyordu.
    ///
    /// Etiket Türkçe küçük harf karşılaştırmasıyla `strong` oluyor ama çıkarıcı
    /// `layout.keyIndex("A") == nil` gördüğü için o token'ın **hepsini** atıyor.
    @Test("Hedef küçük harfe çevriliyor")
    func targetsAreLowercased() {
        #expect(tokenizer.tokens(of: "Ali") == ["ali"])
        for ch in tokenizer.tokens(of: "Ali").joined() {
            #expect(RecordingTestSupport.layout.keyIndex(for: ch) != nil,
                    "her harf bir tuşa çözülmeli, yoksa örnek düşer")
        }
    }

    /// Küçültme **Türkçe locale** ile: `I → ı`, `İ → i`.
    ///
    /// Varsayılan locale `I → i` üretir ve `Ilgaz` hedefi `ilgaz` olur —
    /// kullanıcının basacağı tuş değil.
    @Test("Türkçe küçültme uygulanıyor")
    func turkishCaseFolding() {
        #expect(tokenizer.tokens(of: "Ilgaz") == ["ılgaz"])
        #expect(tokenizer.tokens(of: "İzmir") == ["izmir"])
    }

    /// **NFC önce, casing sonra.**
    ///
    /// `ş` iki biçimde temsil edilebiliyor (`U+015F` ya da `s` + `U+0327`).
    /// Normalize etmeden `keyIndex` kombine biçimi tanımıyor ve harf ayırıcı
    /// sayılıp token ikiye bölünüyordu.
    @Test("Ayrık Unicode biçimi birleştiriliyor")
    func decomposedFormIsNormalized() {
        let decomposed = "i\u{015F}"                     // "iş", hazır biçim
        let combining = "is\u{0327}"                     // "is" + cedilla
        #expect(decomposed.unicodeScalars.count != combining.unicodeScalars.count)
        #expect(tokenizer.tokens(of: combining) == ["iş"])
        #expect(tokenizer.tokens(of: combining) == tokenizer.tokens(of: decomposed))
    }

    // MARK: - Boş hedef

    /// **Yazılabilir harfi olmayan hedef deneme başlatmıyor** (§2.3).
    ///
    /// `---` tokenizer'dan boş dizi çıkarıyor; tamamlanma koşulu
    /// (`cursor == promptTokens.count`) daha başlamadan sağlanıyor ve deneme
    /// hiçbir şey ölçmeden `completed` oluyordu.
    @Test("Harfsiz hedef yazılabilir değil")
    func promptWithoutLettersIsNotTypable() {
        #expect(tokenizer.tokens(of: "---") == [])
        #expect(tokenizer.isTypable("---") == false)
        #expect(tokenizer.isTypable("12 34") == false)
        #expect(tokenizer.isTypable("") == false)
        #expect(tokenizer.isTypable("a") == true)
    }

    // MARK: - Kayıt zinciriyle bağ

    /// Validator kaydedilen diziyi **yeniden türetip** karşılaştırıyor.
    ///
    /// Kural iki yerde yaşarken (UI'da bir kopya, kayıt zincirinde başka bir
    /// kural) ikisi ayrışabiliyordu ve kayıt, kullanıcının **görmediği** bir
    /// hedefe göre hizalanmış görünürdü.
    @Test("Kanonik olmayan hedef dizisi bulgu")
    func nonCanonicalPromptTokensAreAFinding() {
        var s = session(text: "Wi-Fi şifresi", tokens: ["Wi-Fi", "şifresi"])
        let findings = SessionValidator.validate(
            s, layout: RecordingTestSupport.layout)
        #expect(findings.contains { $0.kind == .promptTokensNotCanonical })

        // Kanonik dizi temiz.
        s.promptTokens = .known(["wi", "fi", "şifresi"])
        #expect(!SessionValidator.validate(s, layout: RecordingTestSupport.layout)
            .contains { $0.kind == .promptTokensNotCanonical })
    }

    /// Layout verilmezse kontrol **atlanıyor**.
    ///
    /// Yanlış bir layout'la doğrulamak, doğru bir kaydı bozuk göstermekten
    /// beterdir: kayıt hangi layout'la alındığını `geometry`'de taşıyor ve
    /// çağıran onu bilmiyorsa susmak zorunda.
    @Test("Layout olmadan kanoniklik sınanmıyor")
    func withoutALayoutTheCheckIsSkipped() {
        let s = session(text: "Wi-Fi şifresi", tokens: ["Wi-Fi", "şifresi"])
        #expect(!SessionValidator.validate(s)
            .contains { $0.kind == .promptTokensNotCanonical })
    }

    @Test("Boş hedef dizisi bulgu")
    func emptyPromptTokensAreAFinding() {
        let s = session(text: "---", tokens: [])
        #expect(SessionValidator.validate(s).contains {
            $0.kind == .promptTokensNotCanonical && $0.detail.contains("boş")
        })
    }

    // MARK: - Yardımcı

    private func session(text: String, tokens: [String]) -> CanonicalSession {
        CanonicalSession(
            attemptID: "tok", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, status: .recording,
            promptID: "p", promptText: text, promptSource: .builtin,
            split: "train", promptTokens: .known(tokens),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: RecordingTestSupport.unconfigured(policy: .calibration),
            geometry: .init(layoutID: RecordingTestSupport.layout.id,
                            layoutFingerprint:
                                .known(RecordingTestSupport.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }
}
