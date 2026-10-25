import KBDecoder
import KBLearning
import KBMorphology
import KBFoundation

// MARK: - Kişisel sözlük (§8.7)

extension InputCoordinator {

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
    /// Açık literal seçimi de tek kullanım kanıtıdır; tek dokunuş kalıcı
    /// kabul anlamına gelmez. Kabul için bağımsız tekrarlar gerekir.
    mutating func observePersonal(literal: String, corrected: Bool,
                                  tokenID: TokenID,
                                  decision: CorrectionPolicy.Decision) {
        // Parola alanında hiçbir şey öğrenilmez.
        guard !fieldIsSecure else { return }
        // Düzeltme uygulandıysa kullanıcının yüzeyi zaten belgede değil.
        guard !corrected, decision.literalIsOOV else { return }
        guard let th = decision.theta, th.isFinite else { return }
        guard let key = PersonalLexicon.canonical(literal) else { return }
        recordPersonalOccurrence(key, tokenID: tokenID)
    }

    /// Choosing the literal preserves this occurrence. It is not a request to
    /// teach a spelling permanently: require the normal repeated-use threshold.
    mutating func acceptPersonalSurface(_ surface: String, tokenID: TokenID? = nil) {
        guard !fieldIsSecure, let key = PersonalLexicon.canonical(surface),
              engine?.literalChannel.score(key).isInVocabulary != true else { return }
        // Confirming existing host text has no independently typed occurrence
        // identity. It may introduce one weak spelling, but cannot increase an
        // existing entry, even after an extension restart or document change.
        // Persisted entries already provide this guard; no host text is stored.
        if tokenID == nil, personal.entries[key] != nil { return }
        recordPersonalOccurrence(key, tokenID: tokenID)
    }

    private mutating func recordPersonalOccurrence(_ key: String, tokenID: TokenID?) {
        if let tokenID, weakPersonalObservations[tokenID]?.word == key { return }
        // A new boundary/token ID may come from adopting existing host text.
        // Only actual new letter input resets this bounded deduplication set.
        guard recentPersonalObservationWords.count < ComposingSession.maxHistoryDepth,
              recentPersonalObservationWords.insert(key).inserted else { return }
        let previousPoints = personal.entries[key]?.points ?? 0
        let changed = personal.observe(key, confidence: .weak)
        if let tokenID, let entry = personal.entries[key],
           entry.points == previousPoints + PersonalLexicon.weakPoints {
            weakPersonalObservations[tokenID] = .init(word: key, entry: entry)
            if weakPersonalObservations.count > ComposingSession.maxHistoryDepth,
               let oldest = weakPersonalObservations.keys.min(by: { $0.raw < $1.raw }) {
                weakPersonalObservations.removeValue(forKey: oldest)
            }
        }
        wantsPersonalSave = true
        if changed { applyPersonalLexicon() }
    }

    /// Çağıran kişisel sözlüğü diske yazdıktan sonra bunu çağırır.
    public mutating func personalSaved() { wantsPersonalSave = false }

    /// Depodan yüklenen sözlüğü yürürlüğe koyar.
    public mutating func replacePersonalLexicon(_ p: PersonalLexicon) {
        weakPersonalObservations.removeAll()
        personal = p
        wantsPersonalSave = false
        applyPersonalLexicon()
    }

    /// Kullanıcının kendi metninden kelime öğrenir (§8.7 korpus içe aktarımı).
    ///
    /// Bölme çağıranda `PersonalLexicon.importTokens` ile yapılmalı; `V`
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
        if report.candidates > 0 { weakPersonalObservations.removeAll() }
        if report.changed { applyPersonalLexicon() }
        return report
    }

    /// Kullanıcı yanlışlıkla öğretilmiş bir yüzeyi siler.
    @discardableResult
    public mutating func forgetPersonal(_ surface: String) -> Bool {
        if let key = PersonalLexicon.canonical(surface) {
            weakPersonalObservations = weakPersonalObservations.filter { $0.value.word != key }
        }
        let changed = personal.forget(surface)
        wantsPersonalSave = true
        if changed { applyPersonalLexicon() }
        return changed
    }

    mutating func retractWeakPersonalObservation(_ tokenID: TokenID) {
        guard let receipt = weakPersonalObservations.removeValue(forKey: tokenID) else { return }
        let admitted = personal.isAdmitted(receipt.word)
        guard personal.retractWeakObservation(receipt.word, matching: receipt.entry) else { return }
        wantsPersonalSave = true
        if admitted != personal.isAdmitted(receipt.word) { applyPersonalLexicon() }
    }

    mutating func reconcilePersonalDeletion(_ outcome: Epistemic<DestructiveEffect>, pending: TokenID) {
        guard let effect = outcome.value else {
            weakPersonalObservations.removeAll()
            return
        }
        if let restored = effect.restoredToken,
           let receipt = weakPersonalObservations.removeValue(forKey: restored) {
            // Mere reopen/recommit is not a rejection. Transfer the receipt to
            // the new token identity and retract only if its letters change.
            weakPersonalObservations[session.pendingTokenID] = receipt
        }
        if effect.pending == .dropLast || effect.pending == .dropAll {
            retractWeakPersonalObservation(pending)
        }
        for span in effect.deleted {
            switch span {
            case let .editedToken(id), let .removedToken(id): retractWeakPersonalObservation(id)
            case .unattributed: weakPersonalObservations.removeAll()
            case .separator: break
            }
        }
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
        // Learned words have no proven verb/alternation class. Regular nominal
        // continuations only protect what the user actually types; they never
        // become automatic replacement candidates or synthetic dictionary rows.
        let nominalRoots = personal.admitted.filter { $0.allSatisfy(\.isLetter) && !base.containsSurface($0) }
            .map { Root($0, pos: .noun, lexCost: PersonalLexicon.lexCost) }
        personalInflections = nominalRoots.isEmpty ? nil : MorphologyAutomaton(roots: nominalRoots)

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

    func isKnownPersonalInflection(_ surface: String) -> Bool {
        guard let morphology = personalInflections, surface.count <= PersonalLexicon.maxLength else { return false }
        var states = Set(morphology.startStates())
        for ch in TurkishText.key(surface) {
            states = Set(states.flatMap { morphology.arcs(from: $0).filter { $0.symbol == ch }.map(\.target) })
            guard !states.isEmpty, states.count <= 128 else { return false }
        }
        return states.contains { morphology.isAccepting($0) }
    }
}
