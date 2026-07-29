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

    /// `nil` iken klavye yazar ama öneri üretmez ve düzeltme yapmaz.
    public private(set) var engine: Engine?
    private var incremental: IncrementalDecoder?

    public let layout: KeyLayout

    /// Sözlük dışı literal için commit eşiği (§8.1.1).
    ///
    /// `kbdiag --theta` gerçekçi dokunmalarla ölçtü: bu değerde typo'ların
    /// %82'si düzeliyor, doğru yazılmış sözlük dışı kelimelerin **%0'ı**
    /// bozuluyor. Muhafazakâr uç bilinçli (§5c asimetrisi).
    public var oovTheta = 17.0

    /// Öneri çubuğunda gösterim penceresi — **UI politikası**, skor
    /// sözleşmesinin parçası değil.
    public var suggestionWindow = 3.0

    /// Kaç örnekte bir kalıcılaştırma istenir.
    public var saveEvery = 60
    public private(set) var samplesSinceSave = 0
    /// Çağıranın kalibrasyonu diske yazması gerektiğini bildirir.
    public private(set) var wantsCalibrationSave = false

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

        var fresh = Decoder(layout: layout, spatial: model,
                            lexicon: old.decoder.lexicon,
                            weights: old.decoder.weights,
                            beamWidth: old.decoder.beamWidth)
        fresh.languageModel = old.decoder.languageModel   // dil durumu korunur
        engine?.decoder = fresh
        rebuildIncremental()
        return true
    }

    // MARK: - Girdi

    public mutating func insertLetter(_ ch: Character, touch: TouchSample,
                                      into editor: DocumentEditor) {
        apply(session.insertLetter(ch, touch: touch, into: editor))
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
                                               into editor: DocumentEditor) {
        apply(session.insertShiftedLetter(lower, display: uppercase,
                                          touch: touch, into: editor))
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
            let literalText = session.literal
            let committedText = session.display
            let language = engine?.literalChannel.score(session.literal).language
            // Kimlik `finishToken`'dan **önce** okunuyor: token kapandıktan
            // sonra `pendingTokenID` artık bir sonrakini gösteriyor.
            let tokenID = session.pendingTokenID

            // Ayırıcı **eklenmez**: sembolün kendisi sınırı oluşturuyor.
            apply(session.finishToken(separator: "", into: editor))
            remember(language: language)
            learn(touches: touches, literal: literalText, committed: committedText,
                  confidence: .weak)

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
    public mutating func backspaceTap(into editor: DocumentEditor) -> DestructiveEffect {
        let d = session.backspaceTap(into: editor)
        apply(d.outcome)
        return d.effect
    }

    @discardableResult
    public mutating func backspaceRepeat(into editor: DocumentEditor) -> DestructiveEffect {
        let d = session.backspaceRepeat(into: editor)
        apply(d.outcome)
        return d.effect
    }

    @discardableResult
    public mutating func deleteWord(into editor: DocumentEditor) -> DestructiveEffect {
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
            /// Kullanıcı öneri çubuğundan seçti.
            case suggestion
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
        // Otomatik commit **zayıf** etikettir: kullanıcı düzeltmeye üşenmiş
        // olabilir, "değiştirmedi" doğruluk kanıtı değildir (plan §3).
        learn(touches: touches, literal: literalText, committed: committedText,
              confidence: .weak)

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
    public mutating func pickSuggestion(_ word: String,
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
        // Kullanıcı öneriye **açıkça dokundu** — hedef kesin biliniyor.
        // Hizalama ancak seçilen kelime literal'e EŞİTSE kayda dayanır;
        // farklıysa `observe` hiçbir şey toplamaz (döngüsellik koruması).
        learn(touches: touches, literal: literalText, committed: word,
              confidence: .strong)

        return TokenCommitReport(
            kind: .suggestion, literal: literalText,
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
                                  bestCost: best.cost, bestWord: best.word)
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
        // `w_lex · F_lex + F_lang` — decoder'ın aday maliyetiyle aynı terimler.
        return spatial + engine.literalChannel.totalLexicalCost(score)
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

    /// Commit edilen token'dan kalibrasyon örneği toplar.
    ///
    /// **Seçim düzenlemesi bu yoldan geçmez**: o token'ın dokunmaları ilk
    /// yazıldığında zaten öğrenildi, tekrar eklemek aynı kanıtı iki kez saymak
    /// olurdu. Türetilmiş kanıt da asla buraya ulaşmaz — gerçek gözlem değil.
    private mutating func learn(touches: [TouchSample], literal: String,
                                committed: String,
                                confidence: CalibrationLearner.Confidence) {
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
