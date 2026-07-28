import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBRuntime
import KBLearning

/// Klavye uzantısı — Faz -1A₁ cihaz PoC'si.
///
/// Amaç: `lslem → kalem`'in gerçek bir iOS klavyesinde çalıştığını göstermek ve
/// riskli iOS davranışlarını ölçmek (uzantı yaşam döngüsü, mmap, bellek).
///
/// **Kapsam dışı (bilinçli):** App Group salt-okunur tüketim entitlement ve takım
/// kimliği gerektirdiği için paket şimdilik uzantı bundle'ından okunuyor. Yükleme
/// `PackSource` arkasında olduğu için App Group yolu `-1B`'de tek satırla eklenir.
final class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var suggestionBar: SuggestionBar!

    private var decoder: Decoder?
    private var incremental: IncrementalDecoder?
    private var trie: FormTrie?
    /// §0 açık-vocabulary literal kanalı — commit kararının `cost(literal)` tarafı.
    private var literalChannel = LiteralChannel(vocabulary: nil, charModel: nil)

    /// Composing buffer **spekülatif önbellektir** — metnin sahibi host'tur (§8).
    /// Durum makinesi `KBRuntime`'da; burada yalnız decoder'a bağlanıyor.
    private var session = ComposingSession()

    /// Kendi düzenlemelerimiz sırasında `textDidChange` gelir. O sırada host
    /// uzlaştırmasını çalıştırmak durumu kendi ürettiğimiz ara hâllere bakarak
    /// atardı (silme ile ekleme arasında tampon zaten uyuşmaz).
    private var isEditingDocument = false

    private let layout = TurkishQ.layout()

    // MARK: Kalibrasyon (plan §3)
    //
    // Depo **daima uzantı sandbox'ında**: Tam Erişim açılıp kapanabildiği için
    // iki yazılabilir depo split-brain üretir (§7). Tek yazar biziz.
    private var calibration = CalibrationLearner()
    private var calibrationProfile: CalibrationStore.ProfileKey?
    /// Aktif token sürerken profil değişirse **beklemeye alınır**.
    ///
    /// Profili hemen değiştirmek, eski geometride toplanmış dokunmaların yeni
    /// profile yazılmasına yol açıyordu: token bittiğinde `learn(...)` artık
    /// yeni learner'a ekliyordu. Aktif profil token sonuna kadar sabit kalmalı.
    private var pendingProfile: CalibrationStore.ProfileKey?
    /// Son kaydetmeden bu yana biriken örnek — her token'da diske yazmak
    /// gereksiz I/O olurdu.
    private var samplesSinceSave = 0
    private static let saveEvery = 60


    /// Uzantının kendi sandbox'ı. App Group **değil**: oraya yazmak Tam Erişim
    /// ister ve kullanıcı onu kapatabilir.
    private static var calibrationDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("calibration", isDirectory: true)
    }

    private var loadReport = "yükleniyor…"

    // MARK: Seçim durumu
    //
    // Geri çağrı sayaçları (`sel#N txt#M`) hatayı bulmak için eklenmişti ve
    // işini gördü — §8.4'teki bulguların tamamı onlardan çıktı. Sevk edilen
    // sürümde kullanıcıya gösterilecek bir şey değiller; geriye yalnız
    // "seçili kelimeyi düzenliyorsun" bilgisi kalıyor.
    private var selectionNote: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        suggestionBar = SuggestionBar()
        suggestionBar.onPick = { [weak self] word in self?.commit(word: word) }

        keyboardView = KeyboardView(layout: layout)
        // Eylem `touchesEnded`'de kesinleşir (sürükleme/iptal karakter üretmez).
        keyboardView.onKeyCommit = { [weak self] hit in self?.handle(hit) }
        keyboardView.onKeyRepeat = { [weak self] hit, stage in self?.handleRepeat(hit, stage) }
        // Globe sözleşmesi: gösterim `needsInputModeSwitchKey`'e bağlı,
        // uzun basma sistem input-mode listesini açar.
        keyboardView.showsGlobeKey = needsInputModeSwitchKey
        keyboardView.onGlobeLongPress = { [weak self] view, event in
            self?.handleInputModeList(from: view, with: event ?? UIEvent())
        }

        for v in [suggestionBar as UIView, keyboardView as UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Auto Layout yalnız kurulumda; yazma sırasında hiç çalışmaz.
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: view.topAnchor),
            suggestionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionBar.heightAnchor.constraint(equalToConstant: 44),

            keyboardView.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor),
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardView.heightAnchor.constraint(equalToConstant: 216),
        ])

        // İki aşamalı init (§11.A): tuşlar önce çizilir ve anında yazılabilir;
        // leksikon arka planda yüklenir, öneriler hazır olunca yanar.
        loadPackAsync()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Profil ancak geometri bilindiğinde kurulabilir; yönelim değişince
        // yeniden kurulur ve **o profilin** verisi yüklenir.
        refreshCalibrationProfile()
    }

    // MARK: - Kalibrasyon

    private func refreshCalibrationProfile() {
        let size = keyboardView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let key = CalibrationStore.ProfileKey(
            layoutID: "tr-Q",
            idiom: isPad ? "pad" : "phone",
            isLandscape: size.width > size.height,
            height: Double(size.height),
            width: Double(size.width),
            placement: Self.placement(keyboardWidth: size.width,
                                      screenWidth: view.window?.screen.bounds.width,
                                      isPad: isPad),
            oneHanded: "off",     // iOS uzantıya tek el modunu bildirmiyor
            scale: Int(traitCollection.displayScale.rounded()))
        guard key != calibrationProfile else { return }

        if session.isComposing {
            // Aktif token bitene kadar profil DEĞİŞMEZ; yoksa eski geometride
            // toplanan dokunmalar yeni profile yazılır.
            pendingProfile = key
        } else {
            switchProfile(to: key)
        }
    }

    /// Yerleşim tespiti.
    ///
    /// iOS klavye uzantısına floating/split durumunu **bildirmiyor**. Ölçüden
    /// çıkarım yapmak güvenilir değil, o yüzden yalnız emin olduğumuz durumda
    /// karar veriyoruz; gerisi `.unknown` ve kendi kovasında kalıyor. Yanlış
    /// bir profil paylaşımı, bir moddan öğrenileni diğerine uygulamak demek.
    private static func placement(keyboardWidth: CGFloat, screenWidth: CGFloat?,
                                  isPad: Bool) -> CalibrationStore.ProfileKey.Placement {
        guard isPad else { return .docked }        // iPhone'da tek yerleşim
        guard let sw = screenWidth, sw > 0 else { return .unknown }
        let ratio = keyboardWidth / sw
        if ratio > 0.95 { return .docked }
        if ratio < 0.55 { return .floating }
        return .unknown                             // split olabilir, emin değiliz
    }

    private func switchProfile(to key: CalibrationStore.ProfileKey) {
        saveCalibration()          // ÖNCEKİ profilin verisi önce diske
        calibrationProfile = key
        pendingProfile = nil
        if let dir = Self.calibrationDirectory {
            calibration = CalibrationStore.loadOrEmpty(from: dir, profile: key)
        }
        samplesSinceSave = 0
        applyCalibration()
    }

    /// Model değişimini **token sınırına** erteler (§5b snapshot swap).
    ///
    /// Aktif token yoksa hemen uygulanır; varsa bayrak konur ve token bitince
    /// `applyPendingCalibrationChange()` devreye girer.
    /// Token sınırında çağrılır: bekleyen profil değişimini ve kalibrasyon
    /// güncellemesini uygular.
    ///
    /// **Tek nokta.** Boşluk, öneri seçimi, satır sonu ve host invalidasyonu —
    /// hepsi buradan geçer, yoksa bir yol bayrağı tüketmeden geçer ve değişim
    /// süresiz bekler.
    private func applyPendingCalibrationChange() {
        guard let p = pendingProfile else { return }
        // `switchProfile` her koşulda geçişi tamamlar: profil ve learner
        // değişir, `pendingProfile` temizlenir. Decoder henüz yüklenmemişse
        // `applyCalibration()` no-op döner ama bu kayıp değil — paket yükleme
        // bittiğinde güncel `calibration` üzerinden yeniden çağrılıyor.
        switchProfile(to: p)
    }

    /// Öğrenilen sapmayı uzamsal modele işler ve decoder'ı yeniden kurar.
    ///
    /// **Token sınırında** çağrılır: uzamsal model değişmesi `modelVersion`
    /// değişmesidir (§5b) ve artımlı beam yalnız model sabitken doğrudur.
    @discardableResult
    private func applyCalibration() -> Bool {
        guard let old = decoder else { return false }
        var model = SpatialModel(layout: layout)
        calibration.apply(to: &model)

        var fresh = Decoder(layout: layout, spatial: model, lexicon: old.lexicon,
                            weights: old.weights, beamWidth: 128)
        fresh.languageModel = old.languageModel      // dil durumu korunur
        decoder = fresh

        // Token sınırında çağrıldığı için `session.touches` normalde boş; yine
        // de yeniden oynatma yapılıyor ki çağrı yeri değişirse beam sessizce
        // bayat kalmasın.
        rebuildIncremental()
        refreshSuggestions()
        return true
    }

    /// Commit edilen token'dan kalibrasyon örneği toplar.
    ///
    /// Etiket gücü kullanıcının ne yaptığına bağlı (plan §3): öneriye açıkça
    /// dokunmak **güçlü**, otomatik commit'e karışmamak **zayıf**. Zayıf
    /// olanlar rezervuara girer ama tahmine katılmaz.
    private func learn(from touches: [TouchSample], literal: String,
                       committed: String,
                       confidence: CalibrationLearner.Confidence) {
        let added = calibration.observe(touches: touches, literal: literal,
                                        committed: committed, layout: layout,
                                        confidence: confidence)
        guard added > 0 else { return }
        samplesSinceSave += added
        guard samplesSinceSave >= Self.saveEvery else { return }
        saveCalibration()
        samplesSinceSave = 0
        // Token sınırındayız (commit yolundan çağrıldı), doğrudan uygulanabilir.
        applyCalibration()
    }

    private func saveCalibration() {
        guard let dir = Self.calibrationDirectory, let p = calibrationProfile,
              calibration.sampleCount > 0 else { return }
        try? CalibrationStore.save(calibration, to: dir, profile: p)
    }

    // MARK: - Paket yükleme

    private func loadPackAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let loaded = try PackLoader.load(layout: self.layout,
                                                 bundle: Bundle(for: Self.self))
                DispatchQueue.main.async {
                    self.trie = loaded.trie
                    self.decoder = loaded.decoder
                    self.literalChannel = loaded.literalChannel
                    // Literal kanalı decoder ile AYNI ağırlıkları kullanmalı;
                    // ayrışırlarsa `Δ` iki farklı formülün farkı olur.
                    self.literalChannel.weights = loaded.decoder.weights
                    // §8.1 kapısı AÇIK: ölçüm yenilendi (bkz. §8.1.1).
                    self.literalChannel.autoCorrectsOutOfVocabulary = true
                    self.incremental = IncrementalDecoder(decoder: loaded.decoder)
                    self.loadReport = loaded.report
                    self.suggestionBar.setStatus("hazır — \(loaded.report)")
                    // Profil layout sırasında, decoder'dan ÖNCE kurulmuştu:
                    // o anki `applyCalibration()` no-op'tu ve kaydedilmiş
                    // kalibrasyon bu oturumda hiç uygulanmıyordu.
                    self.applyCalibration()
                }
            } catch {
                DispatchQueue.main.async {
                    self.suggestionBar.setStatus("paket yüklenemedi: \(error)")
                }
            }
        }
    }

    // MARK: - Girdi

    private func handle(_ hit: KeyboardView.KeyHit) {
        switch hit {
        case let .letter(index, point):
            let ch = layout.keys[index].char
            let sample = TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent())
            // Literal ANINDA yazılır — yazma hissi decoder'ı beklemez.
            apply(withOwnEdit { self.session.insertLetter(ch, touch: sample, into: self) })

        case let .function(fk):
            switch fk {
            case .space:
                commitOnSpace()
            case .backspace:
                apply(withOwnEdit { self.session.backspaceTap(into: self) })
            case .ret:
                // Satır sonunda düzeltme yok: literal doğrudan commit ediliyor,
                // dolayısıyla kaydedilecek dil literal'in dilidir.
                let language = session.display.isEmpty
                    ? nil : literalChannel.score(session.literal).language
                apply(withOwnEdit { () -> ComposingSession.Outcome in
                    _ = self.session.finishToken(separator: "\n", into: self)
                    return self.session.invalidate()   // satır sonunu geçen geri dönüş yok
                })
                rememberLanguage(language)
                applyPendingCalibrationChange()
            case .globe:
                advanceToNextInputMode()   // kısa dokunma; uzun basma view'da ele alınır
            case .shift, .numbers:
                break   // `-1A₁` kapsamı dışı
            }
        }
    }

    /// Basılı tutma tekrarı: önce karakter, uzun tutulursa kelime.
    private func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit else { return }
        switch stage {
        case .character:
            apply(withOwnEdit { self.session.backspaceRepeat(into: self) })
        case .word:
            apply(withOwnEdit { self.session.deleteWordBackward(into: self) })
        }
    }

    // MARK: - Oturum ↔ decoder köprüsü

    /// Oturumun sonucunu decoder'a çevirir.
    ///
    /// Artımlı kod çözme yalnız `.appended`'de korunur (§11.C.1); dokunma dizisi
    /// başka türlü değiştiyse beam bayat kalacağı için yeniden kurulur.
    private func apply(_ outcome: ComposingSession.Outcome) {
        switch outcome {
        case .unchanged:
            break
        case .appended:
            incremental?.append(session.touches[session.touches.count - 1])
        case .rebuilt:
            rebuildIncremental()
        case .cleared:
            if let d = decoder { incremental = IncrementalDecoder(decoder: d) }
        }
        refreshSuggestions()
    }

    /// Belgeyi biz değiştiriyoruz — bu aralıkta host uzlaştırması çalışmaz.
    private func withOwnEdit<T>(_ body: () -> T) -> T {
        isEditingDocument = true
        defer { isEditingDocument = false }
        return body()
    }

    private func rebuildIncremental() {
        guard let d = decoder else { return }
        var inc = IncrementalDecoder(decoder: d)
        for t in session.touches { inc.append(t) }
        incremental = inc
    }

    // MARK: - Host uzlaştırması (§8)

    // Bu iki geri çağrı bizim kendi düzenlemelerimizde de tetiklenir.
    // `isEditingDocument` onları eleyen **birinci** filtre, ama tek başına
    // güvenilmez: geri çağrıların proxy düzenlemesine göre eşzamanlı geldiği
    // belgelenmiş değil (cihazda doğrulanacak). Bu yüzden ikinci filtre olarak
    // her ikisi de host mutabakatını sınıyor. Bayrak yanılırsa kaybettiğimiz
    // şey öneri durumu olur, metin değil — hata yönü bilinçli seçildi.

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Klavye kapanırken biriken örnekler kaybolmasın.
        saveCalibration()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !isEditingDocument else { return }

        // **Uzlaştırma buraya konmaz.** Cihazda ölçüldü (durum satırı
        // `sel#0 txt#32 seç='anlamdım' ✗geçmişte yok geçmiş=0`):
        //
        //   1. `selectionDidChange` HİÇ çağrılmıyor — seçim değişimi de dahil
        //      her şey `textDidChange`'den geliyor.
        //   2. Kullanıcı bir kelime seçtiğinde `documentContextBeforeInput`
        //      seçimin ÖNCESİNE kayıyor, dolayısıyla `agreesWithHost` düşüyor.
        //   3. Buradaki senkron `invalidate()` geçmişi siliyordu.
        //   4. Ardından çalışan async okuma `selectedText`'i doğru görüyor ama
        //      geçmiş boşaldığı için eşleşme bulamıyordu.
        //
        // Yani uzlaştırma, tam da seçimi ele almamız gereken anda kanıtı yok
        // ediyordu. Karar sırası: önce seçim, sonra uzlaştırma — ikisi de
        // `handleSelectionChange` içinde, tek yerde.
        DispatchQueue.main.async { [weak self] in
            self?.handleSelectionChange()
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isEditingDocument else { return }
        // **Ertelenmiş okuma.** Bu geri çağrı geldiğinde proxy'nin yeni seçimi
        // yansıttığı garanti değil; birçok host'ta bir run loop turu sonra
        // güncelleniyor. Doğrudan okumak `selectedText`'i `nil` gördürüyor ve
        // özellik sessizce hiç tetiklenmiyor.
        DispatchQueue.main.async { [weak self] in
            self?.handleSelectionChange()
        }
    }

    /// Seçim durumunu okur ve gerekiyorsa seçim düzenleme kipine girer.
    ///
    /// `selectionDidChange` **ve** `textDidChange` sonrasında çağrılıyor:
    /// bazı host'larda saf seçim değişimi yalnız ikincisinden duyuluyor.
    private func handleSelectionChange() {
        guard !isEditingDocument else { return }

        let raw = textDocumentProxy.selectedText
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let sel = raw, !trimmed.isEmpty {
            // Önce **gerçek** kanıt: kelimeyi bu oturumda biz yazdıysak ve
            // konumu doğrulanıyorsa kullanıcının kendi dokunmaları kullanılır.
            apply(session.beginEditingSelection(sel, into: self))

            // Türetilmiş yol yalnız seçimin **kendisi** tek kelimeyse açılır.
            // `trimmed` ile açmak, aday uygulanırken host'un kenar boşluklarını
            // da silmesine yol açıyordu (`insertText` seçimin tamamını değiştirir).
            if !session.isEditingSelection, sel == trimmed,
               let ts = syntheticTouches(for: sel) {
                // Gerçek kanıt yok — uygulama yeniden başlamış, kelime
                // geçmişten düşmüş ya da onu biz yazmamışız. Yüzeyden
                // **türetilmiş** kanıtla yine de yararlı öneri üretilebilir:
                // komşu tuş düzeltmeleri ve eşdeğerlik sınıfları.
                apply(session.beginEditingSelectionSynthetic(sel, touches: ts))
            }
            applyPendingCalibrationChange()
            // Durum satırı `refreshSuggestions`'ın erken dönüşünden ETKİLENMEZ:
            // decoder henüz yüklenmemişken de seçim durumu görünmeli.
            selectionNote = session.isEditingSelection ? sel : nil
            showSelectionNote()
            refreshSuggestions()
            return
        }

        // Seçim bitti: "seçili …" mesajı ekranda asılı kalmasın.
        if selectionNote != nil {
            selectionNote = nil
            refreshSuggestions()
        }

        if session.isEditingSelection {
            apply(session.endEditingSelection())
            applyPendingCalibrationChange()
            return
        }

        // İmleç taşındıysa hangi karakterlerin bizim token'ımıza ait olduğunu
        // artık bilmiyoruz — ama **ne yazdığımızı** biliyoruz. Geçmiş korunur.
        //
        // Cihazda ölçüldü: çift dokunuşun İLK dokunuşu imleci taşıyor ve tam
        // `invalidate()` geçmişi siliyordu; ikinci dokunuş seçimi oluşturunca
        // eşleşecek kanıt kalmıyordu (§8.4).
        if !session.agreesWithHost(self) {
            apply(session.invalidateComposing())
            applyPendingCalibrationChange()
        }
    }

    /// Seçim durumunu durum satırına yazar.
    ///
    /// `refreshSuggestions`'dan ayrı: o, decoder yüklenmemişken erken dönüyor
    /// ve seçim bilgisi hiç görünmüyordu.
    private func showSelectionNote() {
        guard let word = selectionNote else { return }
        suggestionBar.setStatus(session.selectionHasRealEvidence
            ? "seçili: \(word)"
            : "seçili: \(word) — öneriye dokunun")
    }

    /// Bir yüzeyden **türetilmiş** dokunma dizisi: her harf kendi tuşunun
    /// merkezinde.
    ///
    /// Gerçek gözlem değil — kullanıcının parmağının nereye düştüğünü değil,
    /// harflerin hangi tuşta olduğunu söyler. Decoder bundan komşu-tuş ve
    /// eşdeğerlik sınıfı adayları üretebilir; otomatik uygulama için
    /// kullanılmaz.
    ///
    /// Layout'ta olmayan tek bir karakter bile varsa `nil` — kısmi türetme
    /// hizalamayı bozardı.
    private func syntheticTouches(for word: String) -> [TouchSample]? {
        var out: [TouchSample] = []
        out.reserveCapacity(word.count)
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { return nil }
            out.append(TouchSample(down: layout.keys[k].center, timestamp: 0))
        }
        return out
    }

    /// Mevcut artımlı beam'den öneri okur — yeniden decode etmez.
    private func refreshSuggestions() {
        guard let inc = incremental, !session.touches.isEmpty else {
            suggestionBar.setCandidates([])
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let results = inc.results(topK: 3)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // Marj politikası: kazanandan çok geride kalan aday gösterilmez.
        // Bu bir **UI politikasıdır**, skor sözleşmesinin parçası değildir.
        var shown = results
        if let best = results.first {
            shown = results.filter { $0.cost - best.cost <= 3.0 }
        }
        suggestionBar.setCandidates(shown.map(\.word))
        if selectionNote != nil { showSelectionNote(); return }
        let e = calibration.estimate(layout: layout)
        let cal = e.isApplicable
            ? String(format: " · kal %d örn (%+.3f,%+.3f)",
                     e.strongSamples, e.globalBiasX, e.globalBiasY)
            : (calibration.strongCount > 0
               ? " · kal \(calibration.strongCount)/\(CalibrationLearner.minStrongSamples)" : "")
        suggestionBar.setStatus(String(format: "%.1f ms · %@%@", ms, loadReport, cal))
    }

    /// Commit kararı — skor sözleşmesi §8'in tek karar fonksiyonu:
    ///
    ///     Δ = cost(literal) − cost(bestCandidate)
    ///     değiştir  ⟺  Δ > θ(literal, ctx)
    ///
    /// Akış açıkça sıralı: **değiştir → boşluk → geçmişe yaz** (`defer` kontrol
    /// akışını gizlediği için kaldırıldı). Kelime geçmişe yazıldığı için
    /// kullanıcı boşluğu silip geri gelirse buradan devam edebilir.
    /// Seçili kelime düzenlenirken boşluk: **ayırıcı eklenmez** (zaten belgede).
    ///
    /// `finishToken` çağırmak iki türlü bozardı: düzeltme uygulandıysa ikinci
    /// bir boşluk eklerdi, uygulanmadıysa `insertText(" ")` seçili kelimenin
    /// tamamını boşlukla değiştirirdi.
    ///
    /// Kalibrasyon ve dil durumu **güncellenmez**: bu token'ın dokunmaları ilk
    /// yazıldığında zaten öğrenildi, tekrar eklemek aynı kanıtı iki kez saymak
    /// olurdu. Dil `previous`'ı da imlecin gerçek sırasını temsil etmiyor —
    /// geçmişteki bir kelimeyi düzeltmek "son yazılan kelime" değil.
    private func commitSelectionEdit(applying surface: String?) {
        apply(withOwnEdit { self.session.commitSelectionEdit(surface, into: self) })
    }

    private func commitOnSpace() {
        if session.isEditingSelection {
            // Türetilmiş kanıtta **otomatik uygulama yok**: elimizde uzamsal
            // gözlem değil, harflerin tuş merkezleri var. `Δ` o durumda gerçek
            // bir parmak kanıtını temsil etmiyor, dolayısıyla `θ` kararı
            // anlamsız. Kullanıcı adaya dokunursa uygulanır.
            guard session.selectionHasRealEvidence else {
                commitSelectionEdit(applying: nil)
                return
            }
            // Düzeltme yalnız kanal onaylarsa uygulanır — normal yoldaki
            // `Δ > θ` kararının aynısı.
            let best = incremental?.results(topK: 1).first
            let literal = literalChannel.score(session.literal)
            let warranted = best.map { costOfLiteral(literal) - $0.cost > theta(literal) } ?? false
            commitSelectionEdit(applying: warranted ? best?.word : nil)
            return
        }
        var committedLanguage: UInt8?
        // Örnekler `finishToken` durumu temizlemeden ÖNCE alınmalı.
        let touches = session.touches
        let literalText = session.literal
        var committedText = session.display
        apply(withOwnEdit { () -> ComposingSession.Outcome in
            committedLanguage = self.applyAutocorrectIfWarranted()
            committedText = self.session.display
            return self.session.finishToken(separator: " ", into: self)
        })
        rememberLanguage(committedLanguage)
        // Otomatik commit **zayıf** etikettir: kullanıcı düzeltmeye üşenmiş
        // olabilir, "değiştirmedi" doğruluk kanıtı değildir (plan §3).
        // `observe` ayrıca `committed != literal` ise hiçbir şey toplamaz.
        learn(from: touches, literal: literalText, committed: committedText,
              confidence: .weak)
        // Öğrenme profil değişiminden ÖNCE: biten token eski geometriye ait,
        // örnekleri yeni profilin learner'ına yazmak onu kirletirdi.
        applyPendingCalibrationChange()
    }

    /// - Returns: belgede **fiilen duran** kelimenin dili.
    ///
    /// Düzeltme uygulanırsa adayın dili, uygulanmazsa literal'in dili. Her
    /// koşulda en iyi adayın dilini kaydetmek yanlıştı: korumalı bir literal
    /// commit edilirken başka bir kelimenin dili yazılıyor ve sonraki token'ın
    /// geçiş cezası yanlış dile göre hesaplanıyordu.
    @discardableResult
    private func applyAutocorrectIfWarranted() -> UInt8? {
        // Kanıtı kopmuş token'a dokunulmaz: elde yüzeyin tamamını değil yalnız
        // bir parçasını açıklayan dokunmalar var, düzeltmek kullanıcının
        // yazdığını bozmak olurdu.
        guard !session.isDetached, !session.display.isEmpty else { return nil }

        // Kanal bir kez sorgulanır: `matches(ofSurface:)` morfoloji üzerinde
        // yüzey yürüyüşü yapıyor, iki kez çağırmak o işi boşuna tekrarlardı.
        let literal = literalChannel.score(session.literal)

        guard let inc = incremental, !session.touches.isEmpty,
              let best = inc.results(topK: 1).first,
              best.word != session.display else { return literal.language }

        let delta = costOfLiteral(literal) - best.cost
        guard delta > theta(literal) else { return literal.language }

        session.replaceDisplay(with: best.word, into: self)
        return best.language
    }

    /// `cost(literal)` — §0 açık-vocabulary literal kanalı üzerinden.
    ///
    /// Literal leksikondaysa kanonik leksikal maliyeti, değilse
    /// `c_unk + F_char-ngram(w | OOV)` alır. İkisi **asla birlikte** uygulanmaz.
    private func costOfLiteral(_ literalScore: LiteralChannel.Score) -> Double {
        guard let d = decoder else { return .infinity }
        let literal = Array(session.literal)
        // `ComposingSession` değişmezi: dokunma `i`, literal karakter `i`'nin
        // kanıtıdır. Eşleşmeyen dokunmayı sessizce düşürmek `F_spa`'yı eksik
        // hesaplayıp commit kararını kaydırırdı — bu yüzden kırpma değil,
        // değişmez.
        assert(session.touches.count == literal.count)
        let spatial = zip(session.touches, literal).reduce(0.0) { acc, pair in
            let (t, ch) = pair
            guard let k = layout.keyIndex(for: ch) else { return acc }
            return acc + d.spatial.negLogP(t, keyIndex: k)
        }
        // `w_lex · F_lex + F_lang` — decoder'ın aday maliyetiyle aynı terimler.
        // Dil terimlerini atlamak, iki dilli kurulumda `Δ`'yı sistematik olarak
        // kaydırırdı.
        let lex = literalChannel.totalLexicalCost(literalScore)
        return spatial + lex + d.weights.wLen * Double(literal.count)
    }

    /// `θ(literal, ctx)` — artan koruma eşiği (§8).
    private func theta(_ literalScore: LiteralChannel.Score) -> Double {
        // Bilinen kelime bozulmaz; uzunluk sınırını aşan token literal korumaya
        // düşer (§0 taşma kuralı); kalibre edilmemiş OOV de korunur (§8.1).
        // Üçü de kanalın kendi kararı — bu fonksiyon onu tekrar etmez.
        if literalScore.demandsProtection { return .infinity }
        // Kod/literal token koruma kuralları (§5c A/B).
        if Self.isProtectedToken(session.literal) { return .infinity }
        // Alan türü koruması.
        switch textDocumentProxy.keyboardType {
        case .some(.emailAddress), .some(.URL), .some(.numberPad), .some(.decimalPad):
            return .infinity
        default: break
        }
        return Self.oovTheta
    }

    /// Sözlük dışı literal için commit eşiği (§8.1.1).
    ///
    /// `kbdiag --theta` gerçekçi dokunmalarla ölçtü: bu değerde typo'ların
    /// %82'si düzeliyor, doğru yazılmış sözlük dışı kelimelerin **%0'ı**
    /// bozuluyor (28 örneklik B ailesinin maksimumu 16.98).
    ///
    /// Muhafazakâr uç bilinçli (§5c asimetrisi): daha düşük bir eşik daha çok
    /// typo yakalar ama isim bozmaya başlar. `θ = 14.6` denemesinde typo %89'a
    /// çıkıyor, buna karşılık doğru kelimelerin %4'ü bozuluyordu.
    ///
    /// **Sentetik ölçüm.** Gerçek dokunma verisiyle yeniden fit edilecek (§9).
    private static let oovTheta = 17.0

    /// §5c A: rakam/`_`/`.`/`/`/`\`/`:`/`-` içeren, karışık büyük-küçük harfli,
    /// kısa TAMAMI BÜYÜK, `@`/`#` ile başlayan token'lar düzeltilmez.
    static func isProtectedToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.hasPrefix("@") || s.hasPrefix("#") { return true }
        if s.contains(where: { "0123456789_./\\:-".contains($0) }) { return true }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        if hasUpper && hasLower { return true }
        if hasUpper && !hasLower && s.count <= 4 { return true }
        return false
    }

    /// Öneri çubuğundan seçim — boşlukla commit ile aynı yol, farkı kararın
    /// `θ`'dan değil kullanıcıdan gelmesi.
    private func commit(word: String) {
        // Kopuk token'da tamamen no-op: yüzey değiştirilemeyeceği için token'ı
        // kapatmak da yanlış olurdu — kullanıcı olmayan bir düzeltmenin ardından
        // boşluk almış olurdu.
        guard !session.isDetached else { return }
        if session.isEditingSelection { commitSelectionEdit(applying: word); return }
        let language = incremental?.results(topK: 3).first { $0.word == word }?.language
        let touches = session.touches
        let literalText = session.literal
        apply(withOwnEdit { () -> ComposingSession.Outcome in
            self.session.replaceDisplay(with: word, into: self)
            return self.session.finishToken(separator: " ", into: self)
        })
        rememberLanguage(language)
        // Kullanıcı öneriye **açıkça dokundu** — hedef kesin biliniyor.
        // Ama hizalama ancak seçilen kelime literal'e EŞİTSE kayda dayanır;
        // farklıysa `observe` hiçbir şey toplamaz (döngüsellik koruması).
        learn(from: touches, literal: literalText, committed: word,
              confidence: .strong)
        applyPendingCalibrationChange()   // öğrenmeden SONRA (bkz. commitOnSpace)
    }

    /// Commit edilen kelimenin dilini oturum durumuna yazar (§5b).
    ///
    /// **Token sınırında** çağrılır, kelime içinde değil: artımlı decode yalnız
    /// model sabitken doğrudur (§11.C.1). `IncrementalDecoder` kurulurken
    /// `Decoder`'ın bir kopyasını alıyor, dolayısıyla buradaki değişiklik aktif
    /// beam'i etkilemez — bir sonraki token'da yürürlüğe girer. Kural budur.
    ///
    /// Sıra önemli: `apply(...)` bu çağrıdan ÖNCE gelmeli. Sonra gelseydi yeni
    /// `IncrementalDecoder` eski dil durumuyla kurulurdu ve geçiş cezası bir
    /// token geç uygulanırdı.
    private func rememberLanguage(_ language: UInt8?) {
        guard let language else { return }
        decoder?.languageModel.previous = language
        literalChannel.languageModel.previous = language
        // `apply(.cleared)` yeni `IncrementalDecoder`'ı zaten kurdu; onu güncel
        // dil durumuyla yeniden kurmak gerekiyor.
        if let d = decoder { incremental = IncrementalDecoder(decoder: d) }
    }
}

/// `ComposingSession`'ın belgeye açılan penceresi.
extension KeyboardViewController: DocumentEditor {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var selectedText: String? { textDocumentProxy.selectedText }
    var contextAfterInput: String? { textDocumentProxy.documentContextAfterInput }
}

/// Üç yuvalı öneri çubuğu + geliştirme HUD'u (§11.E debug HUD).
final class SuggestionBar: UIView {
    var onPick: ((String) -> Void)?
    private let stack = UIStackView()
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.9, alpha: 1)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        status.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        status.textColor = .darkGray
        status.textAlignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 32),
            status.topAnchor.constraint(equalTo: stack.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCandidates(_ words: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in words.prefix(3) {
            let b = UIButton(type: .system)
            b.setTitle(w, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16)
            b.addAction(UIAction { [weak self] _ in self?.onPick?(w) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }

    func setStatus(_ s: String) { status.text = s }
}
