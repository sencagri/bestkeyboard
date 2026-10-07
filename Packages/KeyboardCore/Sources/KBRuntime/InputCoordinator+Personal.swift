import KBDecoder
import KBLearning

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
    /// ## Güçlü kanıtın üreticisi henüz yok
    ///
    /// `PersonalLexicon.Confidence.strong`'un doğal kaynağı *"kullanıcı kendi
    /// yazdığı yüzeyi öneri çubuğundan seçti"* olurdu. Ama çubuk yalnız decoder
    /// adaylarını ve genişletmeleri gösteriyor; sözlük **dışı** bir literal
    /// hiçbir kaynakta olmadığı için orada belirmiyor, dolayısıyla seçilemiyor.
    /// Çubuğa eklemek yeni bir `SuggestionOrigin` gerektiriyor ve o, kayıt
    /// şemasına dokunmak demek (§12.6.1) — bilerek ertelendi. Bugün tek üretici
    /// zayıf kanal: üç ayrı literal commit.
    mutating func observePersonal(literal: String, corrected: Bool,
                                  decision: CorrectionPolicy.Decision) {
        // Parola alanında hiçbir şey öğrenilmez.
        guard !fieldIsSecure else { return }
        // Düzeltme uygulandıysa kullanıcının yüzeyi zaten belgede değil.
        guard !corrected, decision.literalIsOOV else { return }
        guard let th = decision.theta, th.isFinite else { return }
        let admittedSetChanged = personal.observe(literal, confidence: .weak)
        // Puan kabul eşiğinin **altında** da birikiyor ve kalıcı olmalı: önce
        // yalnız kabulde kaydediliyordu ve ayrı oturumlarda yazılan bir kelime
        // her açılışta sıfırdan başlıyordu.
        wantsPersonalSave = true
        // Decoder yalnız kabul edilmiş küme değişince yeniden kuruluyor.
        guard admittedSetChanged else { return }
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
}
