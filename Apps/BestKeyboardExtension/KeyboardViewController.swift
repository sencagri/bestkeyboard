import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBRuntime

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

    private var loadReport = "yükleniyor…"

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
                    self.incremental = IncrementalDecoder(decoder: loaded.decoder)
                    self.loadReport = loaded.report
                    self.suggestionBar.setStatus("hazır — \(loaded.report)")
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
                apply(withOwnEdit { () -> ComposingSession.Outcome in
                    _ = self.session.finishToken(separator: "\n", into: self)
                    return self.session.invalidate()   // satır sonunu geçen geri dönüş yok
                })
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

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !isEditingDocument else { return }
        // Host metni bizim bilmediğimiz bir şekilde değiştirdi (alan değişimi,
        // otomatik biçimlendirme, donanım klavyesi). Tampon spekülatiftir; atılır.
        if !session.agreesWithHost(self) { apply(session.invalidate()) }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isEditingDocument else { return }
        // İmleç taşındıysa hangi karakterlerin bizim token'ımıza ait olduğunu
        // artık bilmiyoruz.
        if !session.agreesWithHost(self) { apply(session.invalidate()) }
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
        suggestionBar.setStatus(String(format: "%.1f ms · %@", ms, loadReport))
    }

    /// Commit kararı — skor sözleşmesi §8'in tek karar fonksiyonu:
    ///
    ///     Δ = cost(literal) − cost(bestCandidate)
    ///     değiştir  ⟺  Δ > θ(literal, ctx)
    ///
    /// Akış açıkça sıralı: **değiştir → boşluk → geçmişe yaz** (`defer` kontrol
    /// akışını gizlediği için kaldırıldı). Kelime geçmişe yazıldığı için
    /// kullanıcı boşluğu silip geri gelirse buradan devam edebilir.
    private func commitOnSpace() {
        apply(withOwnEdit { () -> ComposingSession.Outcome in
            self.applyAutocorrectIfWarranted()
            return self.session.finishToken(separator: " ", into: self)
        })
    }

    private func applyAutocorrectIfWarranted() {
        // Kanıtı kopmuş token'a dokunulmaz: elde yüzeyin tamamını değil yalnız
        // bir parçasını açıklayan dokunmalar var, düzeltmek kullanıcının
        // yazdığını bozmak olurdu.
        guard !session.isDetached else { return }
        guard let inc = incremental, !session.touches.isEmpty,
              let best = inc.results(topK: 1).first,
              best.word != session.display else { return }

        // Kanal bir kez sorgulanır: `lexCost(ofSurface:)` morfoloji üzerinde
        // yüzey yürüyüşü yapıyor, iki kez çağırmak o işi boşuna tekrarlardı.
        let literal = literalChannel.score(session.literal)
        let delta = costOfLiteral(literal) - best.cost
        guard delta > theta(literal) else { return }

        session.replaceDisplay(with: best.word, into: self)
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
        let lex = d.weights.wLex * literalScore.lexCost
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
        return 1.5
    }

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
        apply(withOwnEdit { () -> ComposingSession.Outcome in
            self.session.replaceDisplay(with: word, into: self)
            return self.session.finishToken(separator: " ", into: self)
        })
    }
}

/// `ComposingSession`'ın belgeye açılan penceresi.
extension KeyboardViewController: DocumentEditor {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
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
