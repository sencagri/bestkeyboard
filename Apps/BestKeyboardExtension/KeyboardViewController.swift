import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBRuntime
import KBLearning

/// Klavye uzantısı — **ince adaptör**.
///
/// Karar mantığının tamamı `KBRuntime.InputCoordinator`'da: commit kararı
/// (`Δ > θ`), kalibrasyon öğrenmesi, dil durumu, seçim kipi. Burada kalanlar
/// yalnız UIKit'e ait olanlar — görünüm, dokunma, yaşam döngüsü, dosya sistemi.
///
/// Ayrım test edilebilirlik içindi: `UIInputViewController` içindeki hiçbir şey
/// `swift test` altında koşmuyor, dolayısıyla uçtan uca doğrulama yazılamıyordu.
final class KeyboardViewController: UIInputViewController {

    private var keyboardView: KeyboardView!
    private var suggestionBar: SuggestionBar!

    private let layout = TurkishQ.layout()
    private lazy var input = InputCoordinator(layout: layout)
    /// Shift durum makinesi — çift dokunuşla kilit, harften sonra düşme,
    /// cümle başı otomatiği. Politika `KBRuntime`'da, burada yalnız bağlanıyor.
    private var shift = ShiftPolicy()

    /// Kendi düzenlemelerimiz sırasında `textDidChange` gelir; o sırada host
    /// uzlaştırmasını çalıştırmak kendi ürettiğimiz ara hâllere bakmak olurdu.
    private var isEditingDocument = false

    private var loadReport = "yükleniyor…"
    /// Seçili kelime düzenleniyorsa yüzeyi — durum satırı için.
    private var selectionNote: String?

    // MARK: Kalibrasyon kalıcılığı
    //
    // Depo **daima uzantı sandbox'ında**: Tam Erişim açılıp kapanabildiği için
    // iki yazılabilir depo split-brain üretir (plan §7). Tek yazar biziz.
    private var calibrationProfile: CalibrationStore.ProfileKey?
    /// Aktif token sürerken profil değişirse beklemeye alınır — eski geometride
    /// toplanan dokunmalar yeni profile yazılmamalı.
    private var pendingProfile: CalibrationStore.ProfileKey?

    private static var calibrationDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("calibration", isDirectory: true)
    }

    // MARK: - Yaşam döngüsü

    override func viewDidLoad() {
        super.viewDidLoad()

        suggestionBar = SuggestionBar()
        suggestionBar.onPick = { [weak self] word in self?.pick(word) }

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

        loadPackAsync()
        updateAutoCapitalization()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshCalibrationProfile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveCalibration()          // biriken örnekler kaybolmasın
    }

    // MARK: - Paket yükleme

    /// İki aşamalı init (§11.A): tuşlar önce çizilir ve anında yazılabilir;
    /// leksikon arka planda yüklenir, öneriler hazır olunca yanar.
    private func loadPackAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let loaded = try PackLoader.load(layout: self.layout,
                                                 bundle: Bundle(for: Self.self))
                DispatchQueue.main.async {
                    var channel = loaded.literalChannel
                    channel.weights = loaded.decoder.weights
                    // §8.1 kapısı AÇIK: ölçüm yenilendi (§8.1.1).
                    channel.autoCorrectsOutOfVocabulary = true
                    self.input.setEngine(.init(decoder: loaded.decoder,
                                               literalChannel: channel))
                    self.loadReport = loaded.report
                    // Profil layout sırasında, motordan ÖNCE kurulmuştu;
                    // kaydedilmiş kalibrasyon ancak burada uygulanabilir.
                    self.input.applyCalibration()
                    self.refreshUI()
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
            let t = TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent())
            selectionNote = nil
            withOwnEdit {
                if shift.isUppercase {
                    // Kanıt küçük harf tuşuna ait — kullanıcı `A` yazarken `a`
                    // tuşuna basıyor.
                    input.insertUppercaseLetter(
                        ch, uppercase: InputCoordinator.uppercase(ch, locale: "tr"),
                        touch: t, into: self)
                } else {
                    input.insertLetter(ch, touch: t, into: self)
                }
            }
            shift.didEmitLetter()
            syncKeyboardState()

        case let .symbol(ch):
            // Rakam/sembol kod çözmeye girmez.
            selectionNote = nil
            withOwnEdit { input.insertSymbol(ch, into: self) }
            shift.didInterruptChain()
            afterTokenBoundary()
            updateAutoCapitalization()

        case let .function(fk):
            switch fk {
            case .space:
                withOwnEdit {
                    input.space(into: self, fieldProtectsLiteral: fieldProtectsLiteral)
                }
                selectionNote = nil
                shift.didInterruptChain()
                afterTokenBoundary()
                updateAutoCapitalization()
            case .backspace:
                withOwnEdit { input.backspaceTap(into: self) }
                shift.didInterruptChain()
                // Metin başına silmek ya da cümle sonlandırıcısını silmek
                // otomatik büyük harfi değiştirir; yeniden okunmalı.
                updateAutoCapitalization()
            case .ret:
                withOwnEdit { input.newline(into: self) }
                selectionNote = nil
                afterTokenBoundary()
                updateAutoCapitalization()
            case .globe:
                advanceToNextInputMode()   // kısa dokunma; uzun basma view'da

            case .shift:
                shift.tapShift(at: CACurrentMediaTime())
                syncKeyboardState()

            // Düzlem geçişleri de çift dokunuş zincirini keser: hızlı
            // `shift → 123 → ABC → shift` yanlışlıkla caps-lock açardı.
            case .numbers:
                shift.didInterruptChain()
                keyboardView.plane = .numbers
            case .symbols:
                shift.didInterruptChain()
                keyboardView.plane = .symbols
            case .letters:
                shift.didInterruptChain()
                keyboardView.plane = .letters
                updateAutoCapitalization()
            }
        }
        refreshUI()
    }

    /// Basılı tutma tekrarı: önce karakter, uzun tutulursa kelime.
    private func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit else { return }
        withOwnEdit {
            switch stage {
            case .character: input.backspaceRepeat(into: self)
            case .word:      input.deleteWord(into: self)
            }
        }
        updateAutoCapitalization()
        refreshUI()
    }

    private func pick(_ word: String) {
        withOwnEdit { input.pickSuggestion(word, into: self) }
        selectionNote = nil
        // Öneri seçimi de token'ı kapatıyor: boşluk yolundaki iki adım burada
        // da gerekli, yoksa cümle başındaki one-shot shift açık kalıp sonraki
        // kelimeyi de büyük başlatırdı.
        shift.didInterruptChain()
        afterTokenBoundary()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Alan türü literal'i koruyor mu (§8 `θ = ∞`).
    private var fieldProtectsLiteral: Bool {
        switch textDocumentProxy.keyboardType {
        case .some(.emailAddress), .some(.URL), .some(.numberPad), .some(.decimalPad):
            return true
        default:
            return false
        }
    }

    /// Shift durumunu görünüme yansıtır.
    private func syncKeyboardState() {
        keyboardView.isUppercase = shift.isUppercase
        keyboardView.isShiftLocked = shift.mode == .locked
    }

    /// Cümle/kelime başı otomatiği — **token sınırında**.
    ///
    /// Karar metinden okunuyor, sayaçtan değil: host metni bizim bilmediğimiz
    /// bir şekilde değiştirmiş olabilir (§8, tampon spekülatiftir).
    private func updateAutoCapitalization() {
        let type: ShiftPolicy.Autocapitalization
        switch textDocumentProxy.autocapitalizationType {
        case .some(.words):         type = .words
        case .some(.sentences):     type = .sentences
        case .some(.allCharacters): type = .allCharacters
        default:                    type = .none
        }
        shift.autoCapitalize(
            ShiftPolicy.shouldCapitalize(context: textDocumentProxy.documentContextBeforeInput,
                                         type: type))
        syncKeyboardState()
    }

    private func withOwnEdit(_ body: () -> Void) {
        isEditingDocument = true
        body()
        isEditingDocument = false
    }

    // MARK: - Host uzlaştırması (§8)

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !isEditingDocument else { return }
        // §8.4: `selectionDidChange` HİÇ çağrılmıyor; seçim değişimi de dahil
        // her şey buradan geliyor. Ayrıca proxy bu anda henüz yeni durumu
        // yansıtmıyor — okuma bir run loop turu ertelenmeli.
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isEditingDocument else { return }
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    private func readSelection() {
        guard !isEditingDocument else { return }
        selectionNote = input.handleSelection(textDocumentProxy.selectedText, into: self)
        afterTokenBoundary()
        // Host metni değiştirmiş ya da imleç taşınmış olabilir; "karar host
        // metninden okunur" garantisi ancak burada da okunursa geçerli.
        updateAutoCapitalization()
        refreshUI()
    }

    // MARK: - Görünüm

    private func refreshUI() {
        suggestionBar.setCandidates(input.shownCandidates().map(\.word))

        if let word = selectionNote {
            // Türetilmiş kanıtta otomatik uygulama yok — kullanıcıya ne yapması
            // gerektiği yazılı.
            suggestionBar.setStatus(input.session.selectionHasRealEvidence
                ? "seçili: \(word)"
                : "seçili: \(word) — öneriye dokunun")
            return
        }

        let e = input.calibration.estimate(layout: layout)
        let cal = e.isApplicable
            ? String(format: " · kal %d örn (%+.3f,%+.3f)",
                     e.strongSamples, e.globalBiasX, e.globalBiasY)
            : (input.calibration.strongCount > 0
               ? " · kal \(input.calibration.strongCount)/\(CalibrationLearner.minStrongSamples)"
               : "")
        suggestionBar.setStatus(loadReport + cal)
    }

    // MARK: - Kalibrasyon kalıcılığı

    /// Token sınırında: bekleyen profil değişimi ve kaydetme isteği burada
    /// karşılanır. Model değişimi **yalnız** burada olur (§5b snapshot swap).
    private func afterTokenBoundary() {
        if input.wantsCalibrationSave {
            saveCalibration()
            input.calibrationSaved()
        }
        if let p = pendingProfile, !input.session.isComposing {
            switchProfile(to: p)
        }
    }

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

        if input.session.isComposing {
            pendingProfile = key
        } else {
            switchProfile(to: key)
        }
    }

    /// Yerleşim tespiti.
    ///
    /// iOS klavye uzantısına floating/split durumunu **bildirmiyor**. Ölçüden
    /// çıkarım güvenilir değil; yalnız emin olduğumuz durumda karar veriyoruz,
    /// gerisi `.unknown` ve kendi kovasında kalıyor.
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
        saveCalibration()                 // ÖNCEKİ profilin verisi önce diske
        calibrationProfile = key
        pendingProfile = nil
        if let dir = Self.calibrationDirectory {
            input.replaceCalibration(CalibrationStore.loadOrEmpty(from: dir, profile: key))
        }
        refreshUI()
    }

    private func saveCalibration() {
        guard let dir = Self.calibrationDirectory, let p = calibrationProfile,
              input.calibration.sampleCount > 0 else { return }
        try? CalibrationStore.save(input.calibration, to: dir, profile: p)
    }
}

/// `InputCoordinator`'ın belgeye açılan penceresi.
extension KeyboardViewController: DocumentEditor {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var contextAfterInput: String? { textDocumentProxy.documentContextAfterInput }
    var selectedText: String? { textDocumentProxy.selectedText }
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
