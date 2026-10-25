import KBFoundation
import KBGeometry
import KBSpatial
import KBDecoder
import KBLearning

// MARK: - Token sınırları

extension InputCoordinator {

    /// Kapanmak üzere olan token'ın **kanıtı** — `finishToken`'dan önce okunur.
    ///
    /// `finishToken` oturumu temizliyor; dokunmalar, leke ve kimlik ondan
    /// **önce** alınmalı. Dört sınır yolu (boşluk, sembol, satır sonu, öneri
    /// seçimi) bu okumayı ayrı ayrı yapıyordu ve kimliğin `finishToken`'dan
    /// sonra okunması gibi bir hata dördünde ayrı ayrı yapılabilirdi.
    struct PendingToken {
        let wasReopened: Bool
        let touches: [TouchSample]
        /// Kanıt türetilmiş mi — `learn` bunu oturumdan okuyamaz, çünkü o
        /// noktada oturum temizlenmiş oluyor.
        let evidenceIsSynthetic: Bool
        let literal: String
        /// Sınırdan hemen önce belgede duran yüzey (düzeltmeden **önce**).
        let displayBefore: String
        /// Kimlik `finishToken`'dan **önce** okunuyor: token kapandıktan sonra
        /// `pendingTokenID` artık bir sonrakini gösteriyor.
        let tokenID: TokenID

        init(_ session: ComposingSession) {
            wasReopened = session.isReopened
            touches = session.touches
            evidenceIsSynthetic = session.evidenceIsSynthetic
            literal = session.literal
            displayBefore = session.display
            tokenID = session.pendingTokenID
        }
    }

    /// Kapanan token'ın bir sonrakinin **bağlamına** ne yaptığı (§2 öznitelik 13).
    enum ContextUpdate {
        /// Bağlam değişmiyor (art arda boşluk: önceki kelime hâlâ bağlam).
        case keep
        /// Kapanan yüzey bağlam olur.
        case remember
        /// Bağlam kesiliyor (cümle sonu, satır sonu).
        case forget
    }

    /// Token sınırının **tek** kapanış sırası:
    /// `finishToken → dil → bağlam → öğrenme → rapor`.
    ///
    /// Dört yol bu sırayı ayrı ayrı yazıyordu ve ayrışmışlardı: satır sonu
    /// öğrenmeyi hiç çağırmıyordu, öneri seçimi büyük harf olgusunu başka bir
    /// kuralla hesaplıyordu. Yolların gerçekten farklı olan kısmı (hangi
    /// ayırıcı, hangi dil, bağlama ne olur, hangi etiket gücüyle öğrenilir)
    /// parametre; geri kalanı burada.
    ///
    /// - Parameter learnAs: öğrenilecek hedef ve etiket gücü. Hedef, öneri
    ///   seçiminde belgeye yazılan yüzeyden **farklı** olabilir: büyük harf
    ///   biçimi kullanıcının kastettiği kelimenin parçası değil.
    mutating func closeToken(_ token: PendingToken,
                             kind: TokenCommitReport.Kind,
                             separator: String,
                             language: UInt8?,
                             context: ContextUpdate,
                             learnAs confidence: CalibrationLearner.Confidence?,
                             target: String? = nil,
                             decision: CorrectionPolicy.Decision = .notAsked,
                             into editor: DocumentEditor) -> TokenCommitReport {
        let committed = session.display
        if let receipt = weakPersonalObservations[token.tokenID],
           PersonalLexicon.canonical(committed) != receipt.word {
            retractWeakPersonalObservation(token.tokenID)
        }
        apply(session.finishToken(separator: separator,
                                  wasAutocorrected: kind == .autocorrect ||
                                    (kind == .literal && session.reopenedAutocorrection),
                                  into: editor))

        remember(language: language)
        switch context {
        case .keep:     break
        case .remember: remember(context: committed)
        case .forget:   forgetContext()
        }
        if let confidence, !token.wasReopened {
            learn(touches: token.touches, literal: token.literal,
                  committed: target ?? committed, confidence: confidence,
                  synthetic: token.evidenceIsSynthetic)
        }

        return TokenCommitReport(
            kind: kind, literal: token.literal,
            displayBefore: token.displayBefore, committed: committed,
            delta: decision.delta, theta: decision.theta,
            bestCost: decision.bestCost, bestWord: decision.bestWord,
            language: language, touchCount: token.touches.count,
            // Büyük harf düzeltmeden bağımsız: `Ali` yazarken literal `ali`,
            // display `Ali` — fark var ama düzeltme yok.
            casingApplied: Self.casingApplied(committed: committed,
                                              literal: token.literal),
            // Boş token gerçek bir token değil — art arda boşlukta kimlik
            // tüketmek, kayıtta var olmayan token'lar için delik açardı.
            // `finishToken` kimliği tam da yüzey boş değilken tüketiyor.
            tokenID: committed.isEmpty ? nil : token.tokenID,
            effect: .boundary)
    }

    /// Rakam, noktalama, sembol — **kod çözmeye girmez**.
    ///
    /// Bu karakterlerin leksikonu yok ve komşuluk düzeltmesi istenmez: `3`
    /// yazmak isteyene `4` vermek düpedüz hatadır. Aktif token varsa önce
    /// kapatılır — sembol bir kelime sınırıdır.
    @discardableResult
    public mutating func insertSymbol(_ ch: Character,
                                      into editor: DocumentEditor) -> TokenCommitReport {
        // Cümle sonlandırıcı bağlamı **kesiyor**: `.`'dan sonraki kelime
        // öncekinin devamı değil, ve bigram tam da devam olasılığını ölçüyor.
        // Virgül/tire kesmiyor — orada cümle sürüyor.
        let before = editor.contextBeforeInput
        let report = insertAtBoundary(String(ch),
                                      context: Self.endsSentence(ch) ? .forget : .remember,
                                      into: editor)
        // â/î/û arrive through the symbol plane but are genuine letter input.
        if ch.isLetter, editor.contextBeforeInput != before {
            recentPersonalObservationWords.removeAll()
        }
        return report
    }

    /// Token sınırında **hazır metin** — pano, dikte, metin kısayolu, tahmin.
    ///
    /// Sembolle aynı yol: açık token düzeltmesiz kapanır ve metin hiçbir
    /// token'a ait değil. Metnin kendisi **dokunma kanıtı değil**: kullanıcı
    /// onu tuşlara basarak yazmadı, dolayısıyla ne decoder'a ne kalibrasyona
    /// giriyor.
    ///
    /// Tek fark bağlamda: bir sonraki kelimenin önünde artık metnin **son**
    /// kelimesi duruyor ve onu tokenizer'dan geçirmeden bilmiyoruz. Kapanan
    /// token'ı bağlam yapmak yanlış bir kelimeyle puanlamak olurdu; bağlam
    /// **bilinmiyor**a düşüyor. Tek grapheme'lik metin tam olarak bir
    /// semboldür ve sembol kuralını alıyor.
    @discardableResult
    public mutating func insertText(_ text: String,
                                    into editor: DocumentEditor) -> TokenCommitReport {
        if text.count == 1, let ch = text.first {
            if ch.isNewline { return newline(into: editor) }
            return insertSymbol(ch, into: editor)
        }
        return insertAtBoundary(text, context: .forget, into: editor)
    }

    /// Sembolün ve hazır metnin ortak yolu: açık token'ı kapatır, metni
    /// **defter üzerinden** yazar.
    ///
    /// - Parameter context: kapanan token bir sonrakinin bağlamı olur mu.
    private mutating func insertAtBoundary(_ text: String, context: ContextUpdate,
                                           into editor: DocumentEditor)
        -> TokenCommitReport {
        if session.isEditingSelection {
            // Host `insertText`'i seçimin YERİNE koyar: seçili kelime metinle
            // değişir. Oturum bunu bir commit sanmamalı — kelime silindi,
            // geçmişe yazılacak bir şey yok.
            apply(session.endEditingSelection())
            session.insertSeparator(text, into: editor)
            return .empty()
        }
        var report = TokenCommitReport.empty()
        if session.isComposing {
            // Sembol token'ı bitirir. **Düzeltme yapılmaz** (kullanıcı kelimeyi
            // noktalamayla kapattı, boşlukla değil — niyet daha kesin), ama dil
            // durumu ve kalibrasyon öğrenmesi normal commit ile aynı.
            //
            // Bunu atlamak `kelime.` biçimindeki her kullanımda kalıcı öğrenme
            // ve dil bağlamı kaybı demekti. `kind` bu yüzden daima `.literal`,
            // `Δ`/`θ` daima `nil`. Öğrenilen kapanan **token**'ın dokunmaları;
            // eklenen metin değil.
            report = closeToken(
                PendingToken(session), kind: .literal,
                // Ayırıcı **eklenmez**: metnin kendisi sınırı oluşturuyor.
                separator: "",
                language: literalLanguage(),
                context: context,
                learnAs: .weak, into: editor)
        } else if context == .forget {
            // Açık token yokken de metin bağlamı değiştiriyor: önceki kelime
            // artık imlecin önünde değil.
            forgetContext()
        }
        // Metin **defter üzerinden** yazılıyor: doğrudan editöre yazmak
        // defteri belgeyle ayrıştırıyor ve sonraki her silmenin atfını
        // `.unattributed`'a düşürüyordu.
        session.insertSeparator(text, into: editor)
        return report
    }

    /// Satır sonu — **token sınırı**, ama v2'de commit kaydı yazılmıyordu.
    ///
    /// A1 baseline testi bunun sonucunu gösteriyor: canlı taraf token'ı
    /// kapatıyor (`finishToken` + `invalidate`) ama kayda commit yazılmadığı
    /// için importer bekleyen dokunmaları biriktirmeye devam ediyor ve
    /// `bir\niki` yazımında `bir`in üç dokunması `iki`ye sızıyordu.
    ///
    /// Öğrenme sembolle **aynı**: satır sonu da kelimeyi düzeltme denemeden
    /// kapatıyor ve `kelime⏎` biçimindeki her kullanımda örnek kaybetmek için
    /// bir gerekçe yok. Eskiden çağrılmıyordu ve bunu açıklayan bir karar
    /// kaydı da yoktu — sınır yolları arasındaki tek ayrışmaydı.
    @discardableResult
    public mutating func newline(into editor: DocumentEditor) -> TokenCommitReport {
        guard !session.display.isEmpty else {
            _ = session.finishToken(separator: "\n", into: editor)
            // An extra newline after a committed word is still a reversible
            // separator. Keep its verified history so deleting SPACE+ENTER
            // can restore the original token and retract cancelled learning.
            // restorePreviousWord checks the ledger, token ID and host text;
            // language context is still reset at the line boundary.
            forgetContext()
            return .empty()
        }
        return closeToken(
            PendingToken(session), kind: .literal, separator: "\n",
            // Satır sonunda düzeltme yok: literal doğrudan commit ediliyor,
            // dolayısıyla kaydedilecek dil literal'in dilidir. Eşik kararı da
            // **hiç sorulmadı**; `Δ`/`θ` yazmak verilmemiş bir kararı verilmiş
            // göstermek olurdu.
            language: literalLanguage(),
            // Satır sonu bağlamı kesiyor — cümle sonlandırıcıyla aynı gerekçe.
            context: .forget,
            learnAs: .weak,
            // Keep verified token/touch history, just as for SPACE+ENTER.
            // Deleting this newline can reopen the word for correction;
            // restorePreviousWord still verifies its ledger ID and host text.
            into: editor)
    }

    /// Boşluk — skor sözleşmesi §8'in tek karar fonksiyonu (`CorrectionPolicy`):
    ///
    ///     Δ = cost(literal) − cost(bestCandidate)
    ///     değiştir  ⟺  Δ > θ(literal, ctx)
    @discardableResult
    public mutating func space(into editor: DocumentEditor,
                               fieldProtectsLiteral: Bool = false) -> TokenCommitReport {
        if session.isEditingSelection {
            guard editor.selectedText == session.display else {
                apply(session.invalidateComposing())
                return .empty()
            }
            // Türetilmiş kanıtta **otomatik uygulama yok**: elimizde uzamsal
            // gözlem değil, harflerin tuş merkezleri var. `Δ` gerçek bir parmak
            // kanıtını temsil etmiyor, dolayısıyla `θ` kararı anlamsız.
            // Seçili yüzeyin büyük harf biçimi de korunmalı: `Kalen` seçilip
            // düzeltilirken `kalem`'e düşmemeli.
            let decision = session.selectionHasRealEvidence
                ? correctionDecision(fieldProtectsLiteral: fieldProtectsLiteral,
                                     contextBefore: editor.contextBeforeInput.map { $0 + session.display })
                : .notAsked
            let surface = decision.word.map { applyCasing(of: session.display, to: $0) }
            apply(session.commitSelectionEdit(surface, into: editor))
            return .empty()
        }

        // Örnekler `finishToken` durumu temizlemeden ÖNCE alınmalı.
        let token = PendingToken(session)
        let decision = correctionDecision(fieldProtectsLiteral: fieldProtectsLiteral,
                                          contextBefore: editor.contextBeforeInput)
        var language: UInt8?
        var corrected = false
        if let s = decision.word,
           session.replaceDisplay(with: applyCasing(of: session.display, to: s),
                                  into: editor) {
            language = bestCandidate()?.language
            corrected = true
        } else if !session.display.isEmpty {
            language = literalLanguage()
        }

        let report = closeToken(
            token,
            kind: token.displayBefore.isEmpty ? .empty
                : (corrected ? .autocorrect : .literal),
            separator: " ", language: language,
            // Boş token bağlamı **değiştirmiyor**: art arda boşluk, önceki
            // kelimenin bağlam olmaktan çıkması demek değil.
            context: session.display.isEmpty ? .keep : .remember,
            // Otomatik commit **zayıf** etikettir: kullanıcı düzeltmeye üşenmiş
            // olabilir, "değiştirmedi" doğruluk kanıtı değildir (plan §3).
            learnAs: .weak,
            decision: decision, into: editor)
        if !token.wasReopened {
            observePersonal(literal: token.literal, corrected: corrected, tokenID: token.tokenID, decision: decision)
        }
        return report
    }

    /// Kullanıcı öneri çubuğundan bir adaya dokundu.
    ///
    /// - Parameter isExpansion: seçilen yüzey bir **genişletme** mi (§4.D).
    ///   Şemada ayrı bir commit türü var (`.expansion`) ve onu `.suggestion`
    ///   diye yazmak, kullanıcının sözlükten bir aday seçtiğini söylemek olurdu
    ///   — oysa `slm → selam` sıralama kararı değil, kısaltma açılımı.
    @discardableResult
    public mutating func pickSuggestion(_ word: String,
                                        isExpansion: Bool = false,
                                        confirmsLiteral: Bool = false,
                                        into editor: DocumentEditor) -> TokenCommitReport {
        // Kanıtı kopmuş oturumda öneri seçimi gerçek bir **no-op**: yüzeyin
        // hangi kısmının hangi dokunmadan geldiği bilinmediği için token'a
        // dokunulmuyor. Kanıt `detached` kalıyor ve rapor bunu söylüyor.
        if session.isDetached {
            guard confirmsLiteral, !word.isEmpty, word == session.display,
                  session.agreesWithHost(editor), editor.selectedText == nil else {
                return .noOp(evidence: .detached)
            }
            // Explicitly accepting the unchanged visible text needs no invented
            // touches. Commit the boundary, but collect no calibration sample.
            return closeToken(PendingToken(session), kind: .suggestion, separator: " ",
                              language: nil, context: .remember, learnAs: nil, into: editor)
        }
        if session.isEditingSelection {
            guard editor.selectedText == session.display else {
                apply(session.invalidateComposing())
                return .empty()
            }
            let confirmsOriginal = word == session.literalSuggestionSurface && !isExpansion
            let surface = applyCasing(of: session.display, to: word)
            apply(session.commitSelectionEdit(surface, into: editor))
            // Selection edits have no new typing-token identity. Keep their
            // recording contract, but do not discard explicit learning intent.
            if confirmsOriginal { acceptPersonalSurface(surface) }
            return .empty()
        }
        guard session.display.isEmpty || session.agreesWithHost(editor) else {
            apply(session.invalidateComposing())
            return .empty()
        }
        let token = PendingToken(session)
        let best = candidates().first { $0.word == word }

        session.replaceDisplay(with: applyCasing(of: session.display, to: word),
                               into: editor)
        // Öneri seçiminde eşik kararı **hiç sorulmadı** — kullanıcı doğrudan
        // söyledi. `Δ`/`θ` yazmak, verilmemiş bir kararı verilmiş göstermek
        // olurdu; maliyet yalnız seçilen adayın kendisi.
        var decision = CorrectionPolicy.Decision.notAsked
        decision.bestCost = best?.cost
        decision.bestWord = best?.word
        return closeToken(
            token, kind: isExpansion ? .expansion : .suggestion,
            separator: " ", language: best?.language, context: .remember,
            // Kullanıcı öneriye **açıkça dokundu** — hedef kesin biliniyor.
            // Hizalama ancak seçilen kelime literal'e EŞİTSE kayda dayanır;
            // farklıysa `observe` hiçbir şey toplamaz (döngüsellik koruması).
            //
            // Hedefin kesin bilinmesi kanıtı gerçek yapmıyor: sentetik token'da
            // "kullanıcı bu kelimeyi kastetti" doğru, "parmağı şuraya düştü" ise
            // hâlâ uydurma. Güçlü etiket yalnız **hizalamayı** güçlendirir,
            // gözlemin kendisini değil.
            learnAs: .strong, target: word,
            decision: decision, into: editor)
    }

    // MARK: - Commit kararı

    func bestCandidate() -> DecodeResult? { candidates(topK: 1).first }

    /// Literal'in kanaldaki dili — düzeltme yapılmadan commit edilen token'ın
    /// kaydedilecek dili.
    func literalLanguage() -> UInt8? {
        engine?.literalChannel.score(session.literal).language
    }

    /// Kullanıcının yazdığı **büyük harf biçimini** adaya taşır.
    ///
    /// Olmadan `Kslem` boşlukta `kalem`'e çevriliyor ve büyük harf sessizce
    /// kayboluyordu. Kullanıcı shift'e basmışsa bu bir niyet beyanıdır; düzeltme
    /// onu ezmemeli.
    ///
    /// Biçim `display` ile `literal` ayrıştığında okunuyor — ayrı bir durum
    /// tutmaya gerek yok. Kural (`TurkishText.casing`) Türkçeye duyarlı: `i → İ`.
    func applyCasing(of shown: String, to candidate: String) -> String {
        guard shown != session.literal else { return candidate }
        return TurkishText.applying(TurkishText.casing(of: shown), to: candidate)
    }

    /// Uygulanması gereken düzeltme, yoksa `nil` — **gerekçesiyle birlikte**.
    ///
    /// Burada yalnız token'ın **yargılanabilir** olup olmadığına bakılıyor;
    /// yargının kendisi `CorrectionPolicy.decide`'da.
    func correctionDecision(fieldProtectsLiteral: Bool, contextBefore: String?) -> CorrectionPolicy.Decision {
        guard !session.isReopened else { return .notAsked }
        // A plausible two-word repair must not be silently replaced by an
        // unrelated single word when the user presses space instead of picking.
        guard boundaryRepairs().isEmpty else { return .notAsked }
        guard !isKnownPersonalInflection(session.literal) else { return .notAsked }
        let context = CorrectionContext(display: session.display, before: contextBefore)
        guard context.hostAgrees, !context.protectsLiteral else { return .notAsked }

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
        guard !session.evidenceIsSynthetic else { return .notAsked }
        // Kanıtı kopmuş token'a dokunulmaz: elde yüzeyin tamamını değil yalnız
        // bir parçasını açıklayan dokunmalar var.
        guard !session.isDetached, !session.display.isEmpty,
              let engine, let best = bestCandidate(),
              best.word != session.display else { return .notAsked }
        // A near-scoring candidate that removes exactly one repeated key is
        // credible evidence of a double tap. If the winner changes something
        // else (çocuklarımızzı → çocuklarımızdı), require an explicit choice.
        // A winning duplicate repair still follows the normal Δ/θ policy.
        if shownCandidates().contains(where: {
            $0.word != best.word &&
                SuggestionPresenter.removesDuplicate($0.word, from: session.literal)
        }) || lexicalDuplicateRepairs().contains(where: {
            TurkishText.key($0) != TurkishText.key(best.word)
        }) { return .notAsked }
        return correction.decide(literal: session.literal,
                                 touches: session.touches, best: best,
                                 engine: engine, layout: layout,
                                 fieldProtectsLiteral: fieldProtectsLiteral)
    }
}
