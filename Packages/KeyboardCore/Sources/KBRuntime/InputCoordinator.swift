import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder
import KBLearning

/// Girdi motorunun cephe tipi — plan §Depo yapısı: *"KBRuntime/ InputEngine
/// facade + host senkronizasyonu"*.
///
/// ## Neden var
///
/// Bütün karar mantığı `UIInputViewController` içindeydi ve **hiç test
/// edilemiyordu**: commit kararı (`Δ > θ`), kalibrasyon öğrenmesinin hangi
/// yollarda çalıştığı, seçim kipinin diğerleriyle etkileşimi. Codex'in
/// istediği uçtan uca testi yazamamamın sebebi buydu.
///
/// Uzantı artık ince bir adaptör: dokunmayı iletiyor, sonucu çiziyor. Karar
/// burada ve `swift test` altında koşuyor.
///
/// ## Neyi kapsamaz
///
/// UIKit'e ait olan hiçbir şey: görünüm, zamanlayıcı, `UIInputViewController`
/// yaşam döngüsü, dosya sistemi. Kalibrasyonun **kalıcılığı** da dışarıda —
/// koordinatör öğrenir, saklamayı çağıran yapar.
public struct InputCoordinator {

    /// Kod çözme yeteneği. Protokol olmasının sebebi test değil: paket henüz
    /// yüklenmemişken de klavyenin yazabilmesi gerekiyor (§11.A iki aşamalı
    /// init), yani "decoder yok" meşru bir durum.
    public struct Engine {
        public var decoder: Decoder
        public var literalChannel: LiteralChannel
        /// Genişletme haritası (§4.D) — **opsiyonel**, yoksa ek öneri çıkmaz.
        public var expansions: ExpansionMap?

        public init(decoder: Decoder, literalChannel: LiteralChannel,
                    expansions: ExpansionMap? = nil) {
            self.decoder = decoder
            self.literalChannel = literalChannel
            self.expansions = expansions
        }
    }

    public private(set) var session = ComposingSession()
    public var calibration = CalibrationLearner()

    /// Kullanıcının kendi kelimeleri (§8.7). Koordinatör **öğrenir**; diske
    /// yazmayı çağıran yapar — kalibrasyonla aynı iş bölümü.
    public private(set) var personal = PersonalLexicon()

    /// Motora **fiilen** kurulmuş kişisel kaynağın kimliği; yoksa `nil`.
    ///
    /// Kayda giriyor: kaynak `LexiconSet`'in bir üyesi ve onu yazmamak, kaydın
    /// kendi motorunu eksik anlatması olurdu (§12.7).
    ///
    /// `personal`'dan **çıkarılamaz**: kabul edilmiş yüzeylerin bir kısmı §7
    /// süzgecine takılıp trie'ye girmemiş olabilir.
    public private(set) var personalSourceRef: PersonalSourceRef?

    public struct PersonalSourceRef: Equatable, Sendable {
        /// Trie'ye **fiilen** giren yüzey sayısı.
        public let wordCount: Int
        public let byteCount: Int
        public let sha256: String
        public let sourceOrder: Int
        public let language: UInt8
    }

    /// Leksikon her yeniden kurulduğunda artan sayaç.
    ///
    /// Kaydedici bunu okuyor: kişisel bir kelimenin kabulü **kayıt dışı bir
    /// motor değişikliğidir** ve `engineConfigured` snapshot'ı o andan sonra
    /// motoru anlatmıyor. `applyCalibration` ile aynı durum, aynı çözüm —
    /// deneme işaretlenir ve çağıran yenisine geçer.
    public private(set) var personalVersion = 0

    /// Aktif alan parola alanı mı.
    ///
    /// Üretimde parola alanında tampon zaten düşürülüyor (uzantı `perform`
    /// içinde). Ama yedek yol (`recorder == nil`) doğrudan bu koordinatörü
    /// kullanıyor ve başka bir katmanın davranışına dayanan koruma, koruma
    /// değildir: kişisel sözlük burada da kanıt toplamıyor.
    public var fieldIsSecure = false

    /// `nil` iken klavye yazar ama öneri üretmez ve düzeltme yapmaz.
    public private(set) var engine: Engine?
    private var incremental: IncrementalDecoder?

    public let layout: KeyLayout

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

    /// Öneri çubuğunda gösterim penceresi — **UI politikası**, skor
    /// sözleşmesinin parçası değil.
    public var suggestionWindow = 3.0

    /// Kaç örnekte bir kalıcılaştırma istenir.
    public var saveEvery = 60
    public private(set) var samplesSinceSave = 0
    /// Çağıranın kalibrasyonu diske yazması gerektiğini bildirir.
    public private(set) var wantsCalibrationSave = false

    /// Çağıranın kişisel sözlüğü diske yazması gerektiğini bildirir.
    ///
    /// Kalibrasyondan farklı olarak **her değişimde** açılıyor, sayaçla değil:
    /// bir kelimenin kabul edilmesi ender bir olay ve kaybedilirse kullanıcı
    /// aynı kelimeyi baştan öğretmek zorunda kalır.
    public private(set) var wantsPersonalSave = false

    public init(layout: KeyLayout) {
        self.layout = layout
    }

    // MARK: - Motor yaşam döngüsü

    public mutating func setEngine(_ e: Engine?) {
        engine = e
        rebuildIncremental()
    }

    /// Öğrenilen sapmayı uzamsal modele işler ve decoder'ı yeniden kurar.
    ///
    /// **Token sınırında** çağrılmalı: uzamsal model değişmesi `modelVersion`
    /// değişmesidir (§5b) ve artımlı beam yalnız model sabitken doğrudur.
    ///
    /// Uygulanan model **hiyerarşik** (Faz 3, sözleşme §8.6): `b_c = g + r_row + d_c`.
    /// Faz 1'in global tahmini (`calibration.apply`) kaldırılmadı ama ürün
    /// yolunda değil — ölçüm kolu olarak `kbbench --calibration`'da duruyor.
    ///
    /// Hiyerarşinin global'e indiği durum ayrı bir dal gerektirmiyor: ampirik
    /// Bayes tuş/satır yapısı bulamazsa `τ² = 0` çıkarır, ince katmanlar
    /// sıfırlanır ve sonuç aynen Faz 1'dir.
    @discardableResult
    public mutating func applyCalibration() -> Bool {
        guard let old = engine else { return false }
        var model = SpatialModel(layout: layout)
        calibration.applyHierarchical(to: &model)

        // Dil durumu, bigram paketi ve bağlam **taşınıyor** (`with(spatial:)`).
        // Taşınmasaydı kalibrasyonun her uygulanışı `F_ctx`'i sessizce
        // kapatırdı: motor kurulumdan sonra yeniden kurulan her decoder,
        // paketi olmayan bir decoder olurdu.
        engine?.decoder = old.decoder.with(spatial: model)
        rebuildIncremental()
        return true
    }

    /// Belgede duran yarım bir token'ı **kanıtsız** devralır.
    ///
    /// Klavyenin yedek koordinatörü, kaydedici kelime ortasında bırakıldığında
    /// bunu çağırıyor: yüzey belgede duruyor ve boş başlamak yüzeyin yalnız
    /// yeni kısmını token sanmak olurdu. Gerekçenin tamamı
    /// `ComposingSession.adoptDetachedSurface`'ta.
    public mutating func adoptDetachedSurface(_ surface: String) {
        apply(session.adoptDetachedSurface(surface))
        // Bağlam da düşüyor: devraldığımız yüzeyin önünde hangi kelimenin
        // durduğunu bilmiyoruz ve eski koordinatörün bağlamı bize taşınmadı.
        forgetContext()
    }

    /// Yazılmakta olan token'ı atar; geri dönüş yığınını korur.
    ///
    /// **Geometri değiştiğinde zorunlu.** Tampondaki dokunmalar eski normalize
    /// uzayda kaydedildi; yeni tuş merkezlerine göre skorlamak sistematik bir
    /// sapma uygulamak olurdu. Belgeye yazılmış harfler yerinde kalıyor —
    /// düşen tek şey o token'ın düzeltilebilirliği.
    public mutating func invalidateComposing() {
        apply(session.invalidateComposing())
        // Bağlam da düşüyor: kanıt koptuysa imlecin nerede olduğunu ve önünde
        // hangi kelimenin durduğunu bilmiyoruz. Eski bağlamı taşımak, artık
        // orada olmayan bir kelimeyle puanlamak olurdu.
        forgetContext()
    }

    // MARK: - Girdi

    /// - Parameter synthetic: dokunma **gözlem değil**, seçilen tuşun
    ///   merkezinden türetilmiş (erişilebilirlik etkinleştirmesi — §8.9).
    ///   Token'ı lekeliyor: o token ne otomatik düzeltiliyor ne de kalibrasyon
    ///   örneği üretiyor.
    public mutating func insertLetter(_ ch: Character, touch: TouchSample,
                                      synthetic: Bool = false,
                                      into editor: DocumentEditor) {
        apply(session.insertLetter(ch, touch: touch, synthetic: synthetic,
                                   into: editor))
    }

    /// **Büyük harfli** harf girişi.
    ///
    /// Uzamsal kanıt küçük harf tuşuna aittir — kullanıcı `A` yazarken `a`
    /// tuşuna basar. Bu yüzden `session` küçük harfi kanıt olarak alır, belgeye
    /// büyüğü yazılır ve token **kanıtı kopmuş** sayılmaz: eşleme bozulmuyor,
    /// yalnız görünen yüzey farklı.
    ///
    /// Ama düzeltme yine de yapılmaz: büyük harfle başlayan token'lar §5c
    /// kurallarına ya da özel ad olma ihtimaline giriyor. `display` ile
    /// `literal` ayrıştığı için `warrantedCorrection` zaten devreye girmez.
    public mutating func insertUppercaseLetter(_ lower: Character,
                                               uppercase: String,
                                               touch: TouchSample,
                                               synthetic: Bool = false,
                                               into editor: DocumentEditor) {
        apply(session.insertShiftedLetter(lower, display: uppercase,
                                          touch: touch, synthetic: synthetic,
                                          into: editor))
    }

    /// Rakam, noktalama, sembol — **kod çözmeye girmez**.
    ///
    /// Bu karakterlerin leksikonu yok ve komşuluk düzeltmesi istenmez: `3`
    /// yazmak isteyene `4` vermek düpedüz hatadır. Aktif token varsa önce
    /// kapatılır — sembol bir kelime sınırıdır.
    @discardableResult
    public mutating func insertSymbol(_ ch: Character,
                                      into editor: DocumentEditor) -> TokenCommitReport {
        if session.isEditingSelection {
            // Host `insertText`'i seçimin YERİNE koyar: seçili kelime sembolle
            // değişir. Oturum bunu bir commit sanmamalı — kelime silindi,
            // geçmişe yazılacak bir şey yok.
            apply(session.endEditingSelection())
            session.insertSeparator(String(ch), into: editor)
            return .empty()
        }
        var report = TokenCommitReport.empty()
        if session.isComposing {
            // Sembol token'ı bitirir. **Düzeltme yapılmaz** (kullanıcı kelimeyi
            // noktalamayla kapattı, boşlukla değil — niyet daha kesin), ama dil
            // durumu ve kalibrasyon öğrenmesi normal commit ile aynı.
            //
            // Bunu atlamak `kelime.` biçimindeki her kullanımda kalıcı öğrenme
            // ve dil bağlamı kaybı demekti.
            let touches = session.touches
            let syntheticEvidence = session.evidenceIsSynthetic
            let literalText = session.literal
            let committedText = session.display
            let language = engine?.literalChannel.score(session.literal).language
            // Kimlik `finishToken`'dan **önce** okunuyor: token kapandıktan
            // sonra `pendingTokenID` artık bir sonrakini gösteriyor.
            let tokenID = session.pendingTokenID

            // Ayırıcı **eklenmez**: sembolün kendisi sınırı oluşturuyor.
            apply(session.finishToken(separator: "", into: editor))
            remember(language: language)
            // Cümle sonlandırıcı bağlamı **kesiyor**: `.`'dan sonraki kelime
            // öncekinin devamı değil, ve bigram tam da devam olasılığını
            // ölçüyor. Virgül/tire kesmiyor — orada cümle sürüyor.
            if Self.endsSentence(ch) { forgetContext() }
            else { remember(context: committedText) }
            learn(touches: touches, literal: literalText, committed: committedText,
                  confidence: .weak, synthetic: syntheticEvidence)

            // Sembolde düzeltme **hiç denenmiyor** (kullanıcı kelimeyi
            // noktalamayla kapattı, niyet daha kesin) — `kind` bu yüzden daima
            // `.literal`, `Δ`/`θ` daima `nil`.
            report = TokenCommitReport(
                kind: .literal, literal: literalText,
                displayBefore: committedText, committed: committedText,
                delta: nil, theta: nil, bestCost: nil, bestWord: nil,
                language: language, touchCount: touches.count,
                casingApplied: committedText.lowercased() == literalText.lowercased()
                    && committedText != literalText,
                tokenID: tokenID, effect: .boundary)
        }
        // Sembol **defter üzerinden** yazılıyor: doğrudan editöre yazmak
        // defteri belgeyle ayrıştırıyor ve sonraki her silmenin atfını
        // `.unattributed`'a düşürüyordu.
        session.insertSeparator(String(ch), into: editor)
        return report
    }

    /// Yıkıcı işlemler **olgu döndürüyor** — sözleşme §6.2.
    ///
    /// Geri açma ve kanıt kopması kararları `ComposingSession`'ın: belge
    /// bağlamına bakıyorlar (`contextBeforeInput`, `hasSuffix(" ")`, tam token
    /// eşitliği) ve saf bir katlayıcı bunları **türetemez**. Türetmeye çalışmak
    /// §6.2'nin yasakladığı çıkarım olurdu; karar burada verilir, olgu olarak
    /// kayda yazılır.
    @discardableResult
    public mutating func backspaceTap(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        let d = session.backspaceTap(into: editor)
        apply(d.outcome)
        return d.effect
    }

    @discardableResult
    public mutating func backspaceRepeat(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        let d = session.backspaceRepeat(into: editor)
        apply(d.outcome)
        return d.effect
    }

    @discardableResult
    public mutating func deleteWord(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        let d = session.deleteWordBackward(into: editor)
        apply(d.outcome)
        return d.effect
    }

    /// Satır sonu — **token sınırı**, ama v2'de commit kaydı yazılmıyordu.
    ///
    /// A1 baseline testi bunun sonucunu gösteriyor: canlı taraf token'ı
    /// kapatıyor (`finishToken` + `invalidate`) ama kayda commit yazılmadığı
    /// için importer bekleyen dokunmaları biriktirmeye devam ediyor ve
    /// `bir\niki` yazımında `bir`in üç dokunması `iki`ye sızıyordu.
    @discardableResult
    public mutating func newline(into editor: DocumentEditor) -> TokenCommitReport {
        // Satır sonunda düzeltme yok: literal doğrudan commit ediliyor,
        // dolayısıyla kaydedilecek dil literal'in dilidir.
        guard !session.display.isEmpty else {
            _ = session.finishToken(separator: "\n", into: editor)
            apply(session.invalidate())
            return .empty()
        }
        let language = engine?.literalChannel.score(session.literal).language
        let touches = session.touches
        let literalText = session.literal
        let committedText = session.display
        let tokenID = session.pendingTokenID

        _ = session.finishToken(separator: "\n", into: editor)
        apply(session.invalidate())        // satır sonunu geçen geri dönüş yok
        remember(language: language)
        // Satır sonu bağlamı kesiyor — cümle sonlandırıcıyla aynı gerekçe.
        forgetContext()

        return TokenCommitReport(
            kind: .literal, literal: literalText,
            displayBefore: committedText, committed: committedText,
            // Satır sonunda eşik kararı **hiç sorulmadı**; `Δ`/`θ` yazmak
            // verilmemiş bir kararı verilmiş göstermek olurdu.
            delta: nil, theta: nil, bestCost: nil, bestWord: nil,
            language: language, touchCount: touches.count,
            casingApplied: committedText.lowercased() != literalText.lowercased()
                ? false : committedText != literalText,
            tokenID: tokenID, effect: .boundary)
    }

    /// Boşluk — skor sözleşmesi §8'in tek karar fonksiyonu:
    ///
    ///     Δ = cost(literal) − cost(bestCandidate)
    ///     değiştir  ⟺  Δ > θ(literal, ctx)
    /// Token sınırında **fiilen ne olduğu** — teşhis ve tekrarlanabilir test için.
    ///
    /// ## Neden döndürülüyor
    ///
    /// Bu alanların hepsi `space()` içinde **zaten hesaplanıyordu ve atılıyordu**.
    /// Sözleşme §12.1 iki şey istiyor: klavyenin hangi kararı neden verdiğini
    /// görebilmek, ve kaydedilen gerçek yazımı sonraki değişikliklere karşı
    /// yeniden oynatabilmek. İkisi de bu bilgi olmadan kurulamıyor.
    ///
    /// ## Neden dışarıda yeniden hesaplanmıyor
    ///
    /// `warrantedCorrection` ve `theta` `private` ve öyle kalmalı. Kararı
    /// çağıranın yeniden hesaplaması **tek karar noktası** disiplinini bozar:
    /// iki yerde hesaplanan bir eşik sessizce ayrışır ve §8.1'de bu hatanın
    /// bedeli zaten kayıtlı.
    ///
    /// ## Neden `committed != literal` yetmez
    ///
    /// Büyük harf de farkı üretir: `Ali` yazılırken literal `ali`, display `Ali`
    /// olur ama **hiçbir düzeltme yoktur**. `kind` bu ikisini ayırır.
    public struct TokenCommitReport: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// Kullanıcının bastığı harfler aynen commit edildi.
            case literal
            /// `Δ > θ` — otomatik düzeltme uygulandı.
            case autocorrect
            /// Kullanıcı öneri çubuğundan bir **aday** seçti.
            case suggestion
            /// Kullanıcı bir **genişletme** seçti (§4.D): `slm → selam`.
            ///
            /// Adaydan ayrı: sıralama kararı değil, kısaltma açılımı. Şemada
            /// zaten ayrı bir tür vardı ama runtime onu hiç üretmiyordu, yani
            /// kayıt genişletmeyi aday seçimi diye anlatıyordu.
            case expansion
            /// Boş token (art arda boşluk gibi).
            case empty
        }

        public var kind: Kind
        /// Kullanıcının **fiilen bastığı** harfler.
        public var literal: String
        /// Token sınırından hemen önce belgede duran metin.
        public var displayBefore: String
        /// Belgeye yazılan nihai metin.
        public var committed: String
        /// `cost(literal) − cost(best)`; karar verilemediyse `nil`.
        public var delta: Double?
        /// O anki eşik; karar verilemediyse `nil`.
        public var theta: Double?
        /// En iyi adayın maliyeti — `delta`'nın hangi adaydan geldiğini sabitler.
        public var bestCost: Double?
        public var bestWord: String?
        public var language: UInt8?
        /// Bu token'a ait dokunma sayısı (kayıtta dokunmalarla eşlemek için).
        public var touchCount: Int
        /// Büyük harf biçimi uygulandı mı — `kind` ile karıştırılmasın diye ayrı.
        public var casingApplied: Bool
        /// Kapanan token'ın kimliği; boş token'da `nil`.
        ///
        /// Yıkıcı etkiler bu kimliğe atıf yapıyor. "Son token" ifadesi art arda
        /// silmede belirsiz: iki `deleteWord` üst üste geldiğinde ikisi de
        /// sonuncuyu işaretliyordu.
        public var tokenID: TokenID?

        /// Sınır işleminin kanıta **fiilen** ne yaptığı.
        ///
        /// Çağıranın `.boundary` varsayması yanlıştı: kanıtı kopmuş bir
        /// oturumda `pickSuggestion` gerçek bir no-op ve kanıt `detached`
        /// kalıyor. Çağıran `.boundary` yazarsa kayda `evidenceStateAfter:
        /// .cleared` girer ve reducer kopukluktan çıkıldığını sanıp sonraki
        /// harfleri toplamaya başlar; durumu oturumdan **okumaya** çalışırsa da
        /// §6.2'nin yasakladığı çıkarımı yapmış olur.
        public var effect: DestructiveEffect

        public static func empty(literal: String = "") -> TokenCommitReport {
            .init(kind: .empty, literal: literal, displayBefore: "", committed: "",
                  delta: nil, theta: nil, bestCost: nil, bestWord: nil, language: nil,
                  touchCount: 0, casingApplied: false, tokenID: nil,
                  effect: .boundary)
        }

        /// Hiçbir şey olmadı — kanıt durumu **olduğu gibi** kalıyor.
        public static func noOp(evidence: DestructiveEffect.EvidenceState)
            -> TokenCommitReport {
            .init(kind: .empty, literal: "", displayBefore: "", committed: "",
                  delta: nil, theta: nil, bestCost: nil, bestWord: nil, language: nil,
                  touchCount: 0, casingApplied: false, tokenID: nil,
                  effect: .init(pending: .none, deleted: [],
                                evidenceStateAfter: evidence))
        }
    }

    /// Düzeltme kararının **gerekçesiyle birlikte** hâli.
    ///
    /// `warrantedCorrection` yalnız sonucu döndürüyordu; `Δ` ve `θ` yerel
    /// değişkenlerde kalıp atılıyordu. Karar aynı, yalnız hesaplananlar artık
    /// çağırana ulaşıyor.
    struct CorrectionDecision {
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
    }

    @discardableResult
    public mutating func space(into editor: DocumentEditor,
                               fieldProtectsLiteral: Bool = false) -> TokenCommitReport {
        if session.isEditingSelection {
            // Türetilmiş kanıtta **otomatik uygulama yok**: elimizde uzamsal
            // gözlem değil, harflerin tuş merkezleri var. `Δ` gerçek bir parmak
            // kanıtını temsil etmiyor, dolayısıyla `θ` kararı anlamsız.
            // Seçili yüzeyin büyük harf biçimi de korunmalı: `Kalen` seçilip
            // düzeltilirken `kalem`'e düşmemeli.
            let decision = session.selectionHasRealEvidence
                ? correctionDecision(fieldProtectsLiteral: fieldProtectsLiteral)
                : CorrectionDecision()
            let surface = decision.word.map { applyCasing(of: session.display, to: $0) }
            apply(session.commitSelectionEdit(surface, into: editor))
            return .empty()
        }

        // Örnekler `finishToken` durumu temizlemeden ÖNCE alınmalı.
        let touches = session.touches
        let syntheticEvidence = session.evidenceIsSynthetic
        let literalText = session.literal
        let displayBefore = session.display

        let decision = correctionDecision(fieldProtectsLiteral: fieldProtectsLiteral)
        var committedLanguage: UInt8?
        var corrected = false
        if let s = decision.word,
           session.replaceDisplay(with: applyCasing(of: session.display, to: s),
                                  into: editor) {
            committedLanguage = bestCandidate()?.language
            corrected = true
        } else if !session.display.isEmpty {
            committedLanguage = engine?.literalChannel.score(session.literal).language
        }
        let committedText = session.display
        // Kimlik `finishToken`'dan **önce** okunuyor: token kapandıktan sonra
        // `pendingTokenID` artık bir sonrakini gösteriyor.
        let tokenID = session.pendingTokenID
        apply(session.finishToken(separator: " ", into: editor))

        remember(language: committedLanguage)
        // Boş token bağlamı **değiştirmiyor**: art arda boşluk, önceki
        // kelimenin bağlam olmaktan çıkması demek değil.
        if !committedText.isEmpty { remember(context: committedText) }
        // Otomatik commit **zayıf** etikettir: kullanıcı düzeltmeye üşenmiş
        // olabilir, "değiştirmedi" doğruluk kanıtı değildir (plan §3).
        learn(touches: touches, literal: literalText, committed: committedText,
              confidence: .weak, synthetic: syntheticEvidence)
        observePersonal(literal: literalText, corrected: corrected, decision: decision)

        return TokenCommitReport(
            kind: displayBefore.isEmpty ? .empty : (corrected ? .autocorrect : .literal),
            literal: literalText,
            displayBefore: displayBefore,
            committed: committedText,
            delta: decision.delta, theta: decision.theta,
            bestCost: decision.bestCost, bestWord: decision.bestWord,
            language: committedLanguage,
            touchCount: touches.count,
            // Büyük harf düzeltmeden bağımsız: `Ali` yazarken literal `ali`,
            // display `Ali` — fark var ama düzeltme yok.
            casingApplied: committedText.lowercased() == literalText.lowercased()
                && committedText != literalText,
            // Boş token gerçek bir token değil — art arda boşlukta kimlik
            // tüketmek, kayıtta var olmayan token'lar için delik açardı.
            tokenID: displayBefore.isEmpty ? nil : tokenID, effect: .boundary)
    }

    /// Kullanıcının yazdığı **büyük harf biçimini** adaya taşır.
    ///
    /// Olmadan `Kslem` boşlukta `kalem`'e çevriliyor ve büyük harf sessizce
    /// kayboluyordu. Kullanıcı shift'e basmışsa bu bir niyet beyanıdır; düzeltme
    /// onu ezmemeli.
    ///
    /// Üç biçim ayırt ediliyor, hepsi `display` ile `literal` karşılaştırılarak
    /// çıkarılıyor — ayrı bir durum tutmaya gerek yok:
    /// tamamı büyük (caps-lock), yalnız ilk harf büyük, hiçbiri.
    ///
    /// Türkçeye duyarlı: `i → İ`.
    func applyCasing(of shown: String, to candidate: String) -> String {
        guard !shown.isEmpty, !candidate.isEmpty, shown != session.literal else {
            return candidate
        }
        let tr = Locale(identifier: "tr")
        // Tamamı büyük ve en az iki harf → caps-lock ile yazılmış.
        if shown.count > 1, shown == shown.uppercased(with: tr),
           shown != shown.lowercased(with: tr) {
            return candidate.uppercased(with: tr)
        }
        // Yalnız ilk harf büyük.
        if let f = shown.first, String(f) == String(f).uppercased(with: tr),
           String(f) != String(f).lowercased(with: tr) {
            let head = String(candidate.first!).uppercased(with: tr)
            return head + String(candidate.dropFirst())
        }
        return candidate
    }

    /// Kullanıcı öneri çubuğundan bir adaya dokundu.
    @discardableResult
    /// - Parameter isExpansion: seçilen yüzey bir **genişletme** mi (§4.D).
    ///   Şemada ayrı bir commit türü var (`.expansion`) ve onu `.suggestion`
    ///   diye yazmak, kullanıcının sözlükten bir aday seçtiğini söylemek olurdu
    ///   — oysa `slm → selam` sıralama kararı değil, kısaltma açılımı.
    public mutating func pickSuggestion(_ word: String,
                                        isExpansion: Bool = false,
                                        into editor: DocumentEditor) -> TokenCommitReport {
        // Kanıtı kopmuş oturumda öneri seçimi gerçek bir **no-op**: yüzeyin
        // hangi kısmının hangi dokunmadan geldiği bilinmediği için token'a
        // dokunulmuyor. Kanıt `detached` kalıyor ve rapor bunu söylüyor.
        guard !session.isDetached else { return .noOp(evidence: .detached) }
        if session.isEditingSelection {
            apply(session.commitSelectionEdit(applyCasing(of: session.display, to: word),
                                              into: editor))
            return .empty()
        }
        let touches = session.touches
        let syntheticEvidence = session.evidenceIsSynthetic
        let literalText = session.literal
        let displayBefore = session.display
        let best = candidates().first { $0.word == word }
        let language = best?.language
        let tokenID = session.pendingTokenID

        session.replaceDisplay(with: applyCasing(of: session.display, to: word),
                               into: editor)
        let committedText = session.display
        apply(session.finishToken(separator: " ", into: editor))

        remember(language: language)
        remember(context: committedText)
        // Kullanıcı öneriye **açıkça dokundu** — hedef kesin biliniyor.
        // Hizalama ancak seçilen kelime literal'e EŞİTSE kayda dayanır;
        // farklıysa `observe` hiçbir şey toplamaz (döngüsellik koruması).
        //
        // Hedefin kesin bilinmesi kanıtı gerçek yapmıyor: sentetik token'da
        // "kullanıcı bu kelimeyi kastetti" doğru, "parmağı şuraya düştü" ise
        // hâlâ uydurma. Güçlü etiket yalnız **hizalamayı** güçlendirir,
        // gözlemin kendisini değil.
        learn(touches: touches, literal: literalText, committed: word,
              confidence: .strong, synthetic: syntheticEvidence)

        return TokenCommitReport(
            kind: isExpansion ? .expansion : .suggestion, literal: literalText,
            displayBefore: displayBefore, committed: committedText,
            // Öneri seçiminde eşik kararı **hiç sorulmadı** — kullanıcı doğrudan
            // söyledi. `Δ`/`θ` yazmak, verilmemiş bir kararı verilmiş göstermek
            // olurdu.
            delta: nil, theta: nil,
            bestCost: best?.cost, bestWord: best?.word,
            language: language, touchCount: touches.count,
            casingApplied: committedText != word, tokenID: tokenID,
            effect: .boundary)
    }

    // MARK: - Seçim

    /// Host'ta bir metin seçildi (ya da seçim kalktı).
    ///
    /// Önce **gerçek** kanıt aranır: kelimeyi bu oturumda biz yazdıysak ve
    /// konumu doğrulanıyorsa kullanıcının kendi dokunmaları kullanılır.
    /// Bulunamazsa yüzeyden **türetilmiş** kanıtla yine öneri üretilir.
    ///
    /// - Returns: seçim düzenleme kipine girildiyse seçilen yüzey.
    @discardableResult
    public mutating func handleSelection(_ selected: String?,
                                         into editor: DocumentEditor) -> String? {
        // Bu geri çağrı **imlecin oynamış olabileceği** her durumda geliyor
        // (seçim, dokunmayla imleç taşıma, host müdahalesi). Defter belgenin
        // **sonu** hakkında konuşuyor; imleç başka bir yere gittiyse cümlesi
        // yanlış bir yer hakkında olur.
        //
        // `agreesWithHost`'un yeterli olmadığı somut durum: belgede zaten
        // `"a "` varken klavye ikinci bir `"a "` yazıyor ve imleç **ilk**
        // `"a "`nın sonuna taşınıyor. Sonek kontrolü geçiyor, uyum kontrolü
        // geçiyor, ama defter yabancı metni kendi token'ı sanıyor.
        session.invalidatePositionalAttribution()
        // İmleç oynamış olabilir: önündeki kelime artık bizim kapattığımız
        // token olmayabilir. Bağlam **bilinmiyor**a düşüyor.
        forgetContext()
        let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let sel = selected, !trimmed.isEmpty {
            apply(session.beginEditingSelection(sel, into: editor))

            // Türetilmiş yol yalnız seçimin **kendisi** tek kelimeyse açılır:
            // kırpılmışla açmak, aday uygulanırken `insertText`'in host'un tüm
            // seçimini (kenar boşlukları dahil) değiştirmesine yol açardı.
            if !session.isEditingSelection, sel == trimmed,
               let ts = syntheticTouches(for: sel) {
                apply(session.beginEditingSelectionSynthetic(sel, touches: ts))
            }
            return session.isEditingSelection ? sel : nil
        }

        if session.isEditingSelection {
            apply(session.endEditingSelection())
            return nil
        }

        // İmleç taşındıysa hangi karakterlerin bizim token'ımıza ait olduğunu
        // artık bilmiyoruz — ama **ne yazdığımızı** biliyoruz. Geçmiş korunur
        // (§8.4: çift dokunuşun ilk dokunuşu geçmişi siliyordu).
        if !session.agreesWithHost(editor) {
            apply(session.invalidateComposing())
        }
        return nil
    }

    // MARK: - Öneriler

    public func candidates(topK: Int = 3) -> [DecodeResult] {
        guard let inc = incremental, !session.touches.isEmpty else { return [] }
        return inc.results(topK: topK)
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    public func shownCandidates() -> [DecodeResult] {
        let r = candidates()
        guard let best = r.first else { return [] }
        return r.filter { $0.cost - best.cost <= suggestionWindow }
    }

    /// Öneri çubuğunda gösterilecek **yüzeyler** — adaylar + genişletmeler.
    ///
    /// Genişletmeler (§4.D) listenin **sonuna** eklenir ve maliyet
    /// karşılaştırmasına girmez: onlar bir sıralama adayı değil, ayrı bir
    /// teklif. `slm` yazan kullanıcıya `selam` gösterilir ama `slm` kazanan
    /// olarak kalır.
    ///
    /// Otomatik uygulanmaları **imkânsız**: `warrantedCorrection` yalnız
    /// decoder adaylarına bakıyor ve `slm` gayrıresmî sözlükte olduğu için
    /// zaten `θ = ∞` alıyor (§8 bilinen kelime koruması). Yani kural iki
    /// bağımsız yerde tutuluyor.
    /// Gösterilen bir öneri — **kimliği ve kaynağıyla**.
    ///
    /// `suggestionSurfaces` yalnız `[String]` veriyordu ve UI dokunulan yüzey
    /// için `id = surface`, `origin = .candidate` **uyduruyordu**. Oysa ayrım
    /// motorun içinde zaten yapılıyor (`RecordingEngine.snapshotSuggestions`
    /// aynı sınıflandırmayı kuruyor): `slm` yazıp `selam`'a dokunulduğunda
    /// gerçek olgu `id = "expansion:selam"`, origin genişletme ve tetikleyici
    /// `slm`. Kayıt bunun yerine aday kimliği yazıyordu ve metin doğru olduğu
    /// için hiçbir test görmüyordu.
    ///
    /// İki yerde sınıflandırmak zaten aynı hatanın ikinci kopyasıydı; tek
    /// kaynak burası.
    public struct Suggestion: Equatable, Sendable {
        public let surface: String
        public let origin: SuggestionOrigin
        /// Kayda giren kimlik. Aday için `word#source`, genişletme için
        /// `expansion:<yüzey>` — `CandidateSnapshot.id` ile aynı üretim.
        public let id: String

        public init(surface: String, origin: SuggestionOrigin, id: String) {
            self.surface = surface; self.origin = origin; self.id = id
        }
    }

    /// Aday kimliğinin **tek** üretimi.
    public static func candidateID(word: String, source: UInt8) -> String {
        "\(word)#\(source)"
    }

    /// Gösterilen öneriler, kimlik ve kaynaklarıyla.
    public func suggestions(limit: Int = 3) -> [Suggestion] {
        let shown = shownCandidates()
        let byWord = Dictionary(shown.map { ($0.word, $0) },
                                uniquingKeysWith: { a, _ in a })
        let trigger = session.display
        return suggestionSurfaces(limit: limit).map { surface in
            if let c = byWord[surface] {
                let id = Self.candidateID(word: c.word, source: c.source)
                return Suggestion(surface: surface,
                                  origin: .candidate(id: id), id: id)
            }
            // Aday listesinde yoksa **genişletme** (§4.D): ayrı bir teklif,
            // sıralama adayı değil.
            return Suggestion(surface: surface,
                              origin: .expansion(trigger: trigger),
                              id: "expansion:\(surface)")
        }
    }

    /// Kurulan motorun uzamsal modeli — **anlık görüntü için**.
    ///
    /// Kayıt, motorun fiilen taşıdığı kalibrasyonu yazmak zorunda; çağıranın
    /// verdiği görüntüye güvenmek kaydın kendi motorunu yanlış anlatmasına yol
    /// açıyordu.
    public var spatialModel: SpatialModel {
        engine?.decoder.spatial ?? SpatialModel(layout: layout)
    }

    public func suggestionSurfaces(limit: Int = 3) -> [String] {
        let decoded = shownCandidates().map(\.word)
        guard !session.display.isEmpty, let e = engine else {
            return Array(decoded.prefix(limit))
        }

        // Genişletme, kullanıcının **yazdığı** yüzeyden aranır — düzeltilmiş
        // adaydan değil. `slm` yazıp `selam` görmek isteniyor; decoder'ın
        // ürettiği bir şeyin açılımı değil.
        let extras = (e.expansions?.expansions(of: session.display) ?? [])
            .filter { !decoded.contains($0) }
        guard !extras.isEmpty else { return Array(decoded.prefix(limit)) }

        // Genişletmeye **ayrılmış slot**. Sona ekleyip `prefix(limit)`
        // uygulamak, üç decoder adayı pencere içinde kaldığında açılımı
        // tamamen kesiyordu: `.bkx` girdisi var ama kullanıcı hiç görmüyordu.
        let reserved = min(extras.count, max(0, limit - 1))
        return Array(decoded.prefix(limit - reserved)) + Array(extras.prefix(reserved))
    }

    // MARK: - Commit kararı

    private func bestCandidate() -> DecodeResult? { candidates(topK: 1).first }

    /// Uygulanması gereken düzeltme, yoksa `nil` — **gerekçesiyle birlikte**.
    ///
    /// Karar mantığı değişmedi; `Δ` ve `θ` eskiden yerel değişkende kalıp
    /// atılıyordu, artık çağırana ulaşıyor (§12.1: klavyenin hangi kararı neden
    /// verdiğini kaydedebilmek için).
    private func correctionDecision(fieldProtectsLiteral: Bool) -> CorrectionDecision {
        // Türetilmiş kanıtta karar **sorulmuyor** — seçim kipindeki kuralın
        // (§8.4) yazma yolundaki karşılığı. `Δ` gerçek bir parmak gözlemi değil:
        // her harf kendi tuşunun merkezinde olduğu için `cost(literal)`'in
        // uzamsal terimi yapay olarak en iyi değerde, aday tarafındaki fark ise
        // tamamen leksikal. Böyle bir `Δ`'yı `θ` ile karşılaştırmak, kullanıcının
        // **duyarak seçtiği** harfleri fat-finger düzeltmesine açmak olurdu.
        //
        // `θ = ∞` yazmak yerine kararın hiç verilmemesi bilinçli: `theta`'nın
        // `nil` kalması kişisel sözlük kanıtını da doğru yerden kapatıyor
        // (§8.7 — kanıt yalnız **reddedilmiş** düzeltmedir; burada düzeltme hiç
        // denenmedi).
        guard !session.evidenceIsSynthetic else { return CorrectionDecision() }
        // Kanıtı kopmuş token'a dokunulmaz: elde yüzeyin tamamını değil yalnız
        // bir parçasını açıklayan dokunmalar var.
        guard !session.isDetached, !session.display.isEmpty,
              let engine, let best = bestCandidate(),
              best.word != session.display else { return CorrectionDecision() }

        // Kanal bir kez sorgulanır: `matches(ofSurface:)` morfoloji üzerinde
        // yüzey yürüyüşü yapıyor, iki kez çağırmak o işi boşuna tekrarlardı.
        let literal = engine.literalChannel.score(session.literal)
        let delta = costOfLiteral(literal, engine: engine) - best.cost
        let th = theta(literal, fieldProtectsLiteral: fieldProtectsLiteral)
        return CorrectionDecision(word: delta > th ? best.word : nil,
                                  delta: delta, theta: th,
                                  bestCost: best.cost, bestWord: best.word,
                                  literalIsOOV: !literal.isInVocabulary)
    }

    /// `cost(literal)` — §0 açık-vocabulary literal kanalı üzerinden.
    private func costOfLiteral(_ score: LiteralChannel.Score, engine: Engine) -> Double {
        let literal = Array(session.literal)
        // `ComposingSession` değişmezi: dokunma `i`, literal karakter `i`'nin
        // kanıtıdır.
        assert(session.touches.count == literal.count)
        let spatial = zip(session.touches, literal).reduce(0.0) { acc, pair in
            let (t, ch) = pair
            guard let k = layout.keyIndex(for: ch) else { return acc }
            return acc + engine.decoder.spatial.negLogP(t, keyIndex: k)
        }
        // `w_lex · F_lex + F_lang + w_ctx · F_ctx` — decoder'ın aday
        // maliyetiyle **aynı** terimler. Bağlam terimini yalnız bir tarafa
        // eklemek `Δ`'yı sessizce kaydırırdı (§2 öznitelik 13).
        return spatial + engine.literalChannel.totalLexicalCost(score,
                                                                token: session.literal)
            + engine.decoder.weights.wLen * Double(literal.count)
    }

    /// `θ(literal, ctx)` — artan koruma eşiği (§8).
    private func theta(_ score: LiteralChannel.Score,
                       fieldProtectsLiteral: Bool) -> Double {
        // Bilinen kelime bozulmaz; uzunluk sınırını aşan token literal korumaya
        // düşer; kalibre edilmemiş OOV de korunur. Üçü de kanalın kendi kararı.
        if score.demandsProtection { return .infinity }
        // Kod/literal token koruma kuralları (§5c A/B).
        if Self.isProtectedToken(session.literal) { return .infinity }
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

    // MARK: - Dil ve öğrenme

    private mutating func remember(language: UInt8?) {
        guard let language else { return }
        engine?.decoder.languageModel.previous = language
        engine?.literalChannel.languageModel.previous = language
        rebuildIncremental()
    }

    /// Kapanan token bir sonrakinin **bağlamı** olur (§2 öznitelik 13).
    ///
    /// Yüzey kanonikleştiriliyor: paket küçük harfli yüzeyler taşıyor ve
    /// `Ali` ile `ali` aynı bağlam. `nil` = bağlam bilinmiyor; bağlamı
    /// "bilinmiyor" saymak, yanlış bir bağlamla puanlamaktan iyidir.
    ///
    /// **Token sınırında** uygulanıyor ve `IncrementalDecoder` kurulurken
    /// snapshot'lanıyor — token ortasında bağlam değişmez (§3 prefix-causality).
    private mutating func remember(context word: String?) {
        guard engine?.decoder.bigrams != nil else { return }
        let ctx = word.flatMap { w -> String? in
            let c = TurkishText.key(w)
            return c.isEmpty ? nil : c
        }
        engine?.decoder.contextWord = ctx
        engine?.literalChannel.contextWord = ctx
        rebuildIncremental()
    }

    /// Cümleyi bitiren noktalama.
    ///
    /// Liste dar tutuldu: virgül, tire, kesme işareti cümleyi bitirmiyor ve
    /// oralarda bağlam gerçekten devam ediyor. Şüphede kalınan her karakteri
    /// "bitirir" saymak, bağlamı çoğu yerde kapatıp özelliği işlevsiz kılardı.
    static func endsSentence(_ ch: Character) -> Bool {
        Punctuation.contextBreakers.contains(ch)
    }

    /// Bağlamı **bilinmiyor** yapar: imleç oynadı, seçim değişti ya da belge
    /// bizim bilmediğimiz bir şekilde değişti. Eski bağlamı taşımak, artık
    /// orada olmayan bir kelimeyle puanlamak olurdu.
    private mutating func forgetContext() {
        guard engine?.decoder.contextWord != nil else { return }
        engine?.decoder.contextWord = nil
        engine?.literalChannel.contextWord = nil
        rebuildIncremental()
    }

    /// Commit edilen token'dan kalibrasyon örneği toplar.
    ///
    /// **Seçim düzenlemesi bu yoldan geçmez**: o token'ın dokunmaları ilk
    /// yazıldığında zaten öğrenildi, tekrar eklemek aynı kanıtı iki kez saymak
    /// olurdu.
    ///
    /// - Parameter synthetic: token'ın kanıtı türetilmişse **hiçbir örnek
    ///   toplanmıyor**. Bayrak çağırandan geliyor çünkü `learn` daima
    ///   `finishToken`'dan sonra çağrılıyor ve oturum o noktada temizlenmiş
    ///   oluyor — `session.evidenceIsSynthetic`'i burada okumak daima `false`
    ///   görürdü. `touches` ile aynı anda, aynı yerden alınmalı.
    ///
    ///   Sebep §8.1.1'de zaten ölçülü: tam tuş merkezine konan dokunmalar
    ///   uzamsal sinyali silen şeyin ta kendisi. Sentetik dokunmaların sapması
    ///   tanım gereği sıfır; onları öğrenmek, kullanıcının gerçek parmak
    ///   sapmasını **sistematik olarak sıfıra çeken** bir örneklem eklemek olurdu
    ///   ve dosya diskte durduğu için kayıp "kalibrasyon bozuldu" diye de
    ///   görünmezdi (§8.6 devretme hatasıyla aynı sinsilik).
    private mutating func learn(touches: [TouchSample], literal: String,
                                committed: String,
                                confidence: CalibrationLearner.Confidence,
                                synthetic: Bool = false) {
        guard !synthetic else { return }
        let added = calibration.observe(touches: touches, literal: literal,
                                        committed: committed, layout: layout,
                                        confidence: confidence)
        guard added > 0 else { return }
        samplesSinceSave += added
        guard samplesSinceSave >= saveEvery else { return }
        wantsCalibrationSave = true
    }

    /// Çağıran kalibrasyonu diske yazdıktan sonra bunu çağırır.
    public mutating func calibrationSaved() {
        wantsCalibrationSave = false
        samplesSinceSave = 0
        applyCalibration()      // yeni tahmini yürürlüğe al
    }

    /// Profil değişiminde yeni learner yüklenir.
    public mutating func replaceCalibration(_ c: CalibrationLearner) {
        calibration = c
        samplesSinceSave = 0
        wantsCalibrationSave = false
        applyCalibration()
    }

    // MARK: - Kişisel sözlük (§8.7)

    /// Boşlukla kapanan bir token'dan kişisel sözlük kanıtı toplar.
    ///
    /// ## Kanıt yalnız **reddedilmiş** düzeltmedir
    ///
    /// Koşul `θ`'nın sonlu olması: klavye token'ı gerçekten yargıladı ve
    /// literal'i bıraktı. `θ = ∞` olan hiçbir yol kanıt üretmez — e-posta/URL
    /// alanı, korumalı token (`@ali`, `x1`), uzunluk taşması, kapalı OOV kapısı.
    /// Oralarda karar hiç sorulmadı; "değiştirmedi" bir olgu değil, sorunun
    /// sorulmamış olmasıdır.
    ///
    /// Aynı gerekçeyle sembol ve satır sonu yolları da kanıt üretmiyor:
    /// ikisinde de düzeltme **hiç denenmiyor** (kullanıcı kelimeyi noktalamayla
    /// kapattı). Türetilmiş kanıtla yazılan token da (§8.9) aynı kapıdan
    /// düşüyor — `correctionDecision` orada `θ` üretmiyor. Ayrı bir kontrol
    /// gerekmiyor ve **eklenmemeli**: kuralı ikinci bir yerde tekrarlamak,
    /// birinin değişip diğerinin kalmasına açık kapı bırakır.
    ///
    /// ## Güçlü kanıtın üreticisi henüz yok
    ///
    /// `PersonalLexicon.Confidence.strong`'un doğal kaynağı *"kullanıcı kendi
    /// yazdığı yüzeyi öneri çubuğundan seçti"* olurdu. Ama çubuk yalnız decoder
    /// adaylarını ve genişletmeleri gösteriyor; sözlük **dışı** bir literal
    /// hiçbir kaynakta olmadığı için orada belirmiyor, dolayısıyla seçilemiyor.
    /// Çubuğa eklemek yeni bir `SuggestionOrigin` gerektiriyor ve o, kayıt
    /// şemasına dokunmak demek (§12.6.1) — bilerek ertelendi. Bugün tek üretici
    /// zayıf kanal: üç ayrı literal commit.
    private mutating func observePersonal(literal: String, corrected: Bool,
                                          decision: CorrectionDecision) {
        // Parola alanında hiçbir şey öğrenilmez.
        guard !fieldIsSecure else { return }
        // Düzeltme uygulandıysa kullanıcının yüzeyi zaten belgede değil.
        guard !corrected, decision.literalIsOOV else { return }
        guard let th = decision.theta, th.isFinite else { return }
        guard personal.observe(literal, confidence: .weak) else { return }
        wantsPersonalSave = true
        applyPersonalLexicon()
    }

    /// Çağıran kişisel sözlüğü diske yazdıktan sonra bunu çağırır.
    public mutating func personalSaved() { wantsPersonalSave = false }

    /// Depodan yüklenen sözlüğü yürürlüğe koyar.
    public mutating func replacePersonalLexicon(_ p: PersonalLexicon) {
        personal = p
        wantsPersonalSave = false
        applyPersonalLexicon()
    }

    /// Kullanıcının kendi metninden kelime öğrenir (§8.7 korpus içe aktarımı).
    ///
    /// Bölme çağıranda ve **tek** tokenizer'la (§2.3) yapılmalı; burada `V`
    /// üyeliği motorun kendi leksikonundan soruluyor, yani içe aktarım da
    /// decoder'ın bildiği kelimeleri atlıyor.
    ///
    /// Parola alanında **çağrılmamalı** — koordinatör yine de reddediyor.
    @discardableResult
    public mutating func ingestPersonal(tokens: [String])
        -> PersonalLexicon.IngestReport {
        guard !fieldIsSecure, let engine else {
            return .init(tokens: 0, candidates: 0, admitted: [])
        }
        let lexicon = engine.decoder.lexicon
        let report = personal.ingest(tokens: tokens) { surface in
            lexicon.containsSurface(surface)
        }
        // Puan biriktiren ama eşiği geçmeyen bir içe aktarım da kalıcı olmalı:
        // kullanıcı metni iki parça hâlinde verdiyse ikinci parça birincinin
        // üstüne binmeli.
        if report.candidates > 0 { wantsPersonalSave = true }
        if report.changed { applyPersonalLexicon() }
        return report
    }

    /// Kullanıcı yanlışlıkla öğretilmiş bir yüzeyi siler.
    @discardableResult
    public mutating func forgetPersonal(_ surface: String) -> Bool {
        let changed = personal.forget(surface)
        wantsPersonalSave = true
        if changed { applyPersonalLexicon() }
        return changed
    }

    /// Kabul edilmiş kelimeleri decoder'a ve literal kanalına işler.
    ///
    /// **İkisi birlikte** değişiyor. Ayrı bırakılsalardı `Δ = cost(literal) −
    /// cost(best)` iki farklı sözlüğün farkı olurdu: decoder kişisel kelimeyi
    /// aday üretirken kanal onu hâlâ OOV sayar, `Δ` şişer ve kelime tam da
    /// korumaya alındığı anda düzeltilmeye açık kalır.
    ///
    /// **Token sınırında** çağrılmalı — `applyCalibration` ile aynı gerekçe:
    /// leksikon değişmesi model sürümünün değişmesidir (§5b) ve artımlı beam
    /// yalnız model sabitken doğrudur. `observePersonal` yalnız commit'ten
    /// sonra çağırıyor, yani zaten sınırda.
    ///
    /// Bedeli ölçüldü (release, 210 yüzey, gerçek paket + 30k kök): kaynak
    /// kurulumu 2.1 ms + leksikon/decoder 2.1 ms. Yalnız **kabul anında**
    /// ödeniyor; puan biriktiren gözlem hiçbir şey kurmuyor.
    ///
    /// Paket kaynakları `kind != .personal` ile ayrılıyor: eskisini süzmeden
    /// eklemek her kabulde bir öncekini de taşıyıp yüzeyi iki kaynaktan
    /// üretirdi.
    @discardableResult
    public mutating func applyPersonalLexicon() -> Bool {
        guard let old = engine else { return false }
        let packSources = old.decoder.lexicon.sources.filter { $0.kind != .personal }
        let base = LexiconSet(sources: packSources)

        var sources = packSources
        if let built = PersonalLexiconSource.build(words: personal.admitted,
                                                   base: base) {
            sources.append(built.source)
            personalSourceRef = PersonalSourceRef(
                wordCount: built.words.count, byteCount: built.byteCount,
                sha256: built.sha256, sourceOrder: sources.count - 1,
                language: built.source.language)
        } else {
            personalSourceRef = nil
        }
        let lexicon = LexiconSet(sources: sources)
        personalVersion &+= 1

        engine?.decoder = old.decoder.with(lexicon: lexicon)
        engine?.literalChannel.setVocabulary(lexicon)
        rebuildIncremental()
        return true
    }

    // MARK: - İç

    /// Oturumun sonucunu decoder'a çevirir.
    ///
    /// Artımlı kod çözme yalnız `.appended`'de korunur (§11.C.1); dokunma
    /// dizisi başka türlü değiştiyse beam bayat kalacağı için yeniden kurulur.
    private mutating func apply(_ outcome: ComposingSession.Outcome) {
        switch outcome {
        case .unchanged:
            break
        case .appended:
            if let last = session.touches.last { incremental?.append(last) }
        case .rebuilt, .cleared:
            rebuildIncremental()
        }
    }

    private mutating func rebuildIncremental() {
        guard let e = engine else { incremental = nil; return }
        var inc = IncrementalDecoder(decoder: e.decoder)
        for t in session.touches { inc.append(t) }
        incremental = inc
    }

    /// Türkçeye duyarlı büyük harf.
    ///
    /// `i → İ` ve `ı → I`. Swift'in locale'siz `uppercased()`'i `i`'yi `I`
    /// yapar; Türkçe Q layout'unda bu yanlıştır ve iki ayrı harfi birbirine
    /// karıştırır.
    ///
    /// **Bilinen sınır:** kullanıcı İngilizce yazarken `i` tuşuna basıp shift
    /// yaparsa `İ` çıkar. Layout Türkçe olduğu için Türkçe kural uygulanıyor;
    /// gerçek çözüm §5b'nin dil-duyarlı casing'i, o da kelimenin dili
    /// çözüldükten SONRA uygulanabilir (Faz 5). Fiziksel Türkçe klavyelerin
    /// davranışı da budur.
    public static func uppercase(_ ch: Character, locale: String) -> String {
        String(ch).uppercased(with: Locale(identifier: locale))
    }

    /// Bir yüzeyden **türetilmiş** dokunma dizisi: her harf kendi tuşunun
    /// merkezinde. Gerçek gözlem değil (§8.4).
    private func syntheticTouches(for word: String) -> [TouchSample]? {
        var out: [TouchSample] = []
        out.reserveCapacity(word.count)
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { return nil }
            out.append(TouchSample(down: layout.keys[k].center, timestamp: 0))
        }
        return out
    }
}
