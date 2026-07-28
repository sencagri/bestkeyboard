import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder

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

    /// Composing buffer **spekülatif önbellektir** — metnin sahibi host'tur (§8).
    /// Bu fazda henüz uzlaştırma yok; `-1A₁` kapsamı render + decode.
    private var composingTouches: [TouchSample] = []
    private var composingLiteral: String = ""

    private let layout = TurkishQ.layout()

    private var loadReport = "yükleniyor…"

    override func viewDidLoad() {
        super.viewDidLoad()

        suggestionBar = SuggestionBar()
        suggestionBar.onPick = { [weak self] word in self?.commit(word: word) }

        keyboardView = KeyboardView(layout: layout)
        // Eylem `touchesEnded`'de kesinleşir (sürükleme/iptal karakter üretmez).
        keyboardView.onKeyCommit = { [weak self] hit in self?.handle(hit) }
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
            // Literal ANINDA yazılır — yazma hissi decoder'ı beklemez.
            textDocumentProxy.insertText(String(ch))
            composingLiteral.append(ch)
            let sample = TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent())
            composingTouches.append(sample)
            // §11.C.1: ARTIMLI — beam'i saklayıp bir dokunma uzatırız.
            // Her tuşta sıfırdan kurmak kelime boyunca karesel maliyet demekti.
            incremental?.append(sample)
            refreshSuggestions()

        case let .function(fk):
            switch fk {
            case .space:
                commitOnSpace()
            case .backspace:
                textDocumentProxy.deleteBackward()
                if !composingLiteral.isEmpty {
                    composingLiteral.removeLast()
                    composingTouches.removeLast()
                    // Silme artımlı olarak geri alınamaz (beam yığını henüz yok);
                    // yalnız burada yeniden kurulur.
                    rebuildIncremental()
                    refreshSuggestions()
                }
            case .ret:
                resetComposing()
                textDocumentProxy.insertText("\n")
            case .globe:
                advanceToNextInputMode()   // kısa dokunma; uzun basma view'da ele alınır
            case .shift, .numbers:
                break   // `-1A₁` kapsamı dışı
            }
        }
    }

    private func rebuildIncremental() {
        guard let d = decoder else { return }
        var inc = IncrementalDecoder(decoder: d)
        for t in composingTouches { inc.append(t) }
        incremental = inc
    }

    /// Mevcut artımlı beam'den öneri okur — yeniden decode etmez.
    private func refreshSuggestions() {
        guard let inc = incremental, !composingTouches.isEmpty else {
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
    /// Akış açıkça sıralı: **değiştir → boşluk → sıfırla** (`defer` kontrol
    /// akışını gizlediği için kaldırıldı).
    private func commitOnSpace() {
        applyAutocorrectIfWarranted()
        textDocumentProxy.insertText(" ")
        resetComposing()
    }

    private func applyAutocorrectIfWarranted() {
        guard let inc = incremental, !composingTouches.isEmpty,
              let best = inc.results(topK: 1).first,
              best.word != composingLiteral else { return }

        let literalCost = costOfLiteral()
        let delta = literalCost - best.cost
        guard delta > theta() else { return }

        for _ in 0..<composingLiteral.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(best.word)
    }

    /// `cost(literal)`.
    ///
    /// **Eksik:** açık-vocabulary literal kanalı (§0/§7: `c_unk + F_char_ngram`)
    /// henüz uygulanmadı — paket bir karakter n-gram modeli taşımıyor. Şimdilik
    /// literal leksikondaysa gerçek maliyeti, değilse sabit bir OOV maliyeti
    /// kullanılıyor. Kanal eklenene kadar bu bir **yaklaşımdır** ve `θ`
    /// kalibrasyonu buna göre okunmalıdır.
    private func costOfLiteral() -> Double {
        guard let d = decoder else { return .infinity }
        let spatial = composingTouches.enumerated().reduce(0.0) { acc, pair in
            let (i, t) = pair
            let ch = Array(composingLiteral)[i]
            guard let k = layout.keyIndex(for: ch) else { return acc }
            return acc + d.spatial.negLogP(t, keyIndex: k)
        }
        let lex: Double
        if let raw = trie?.lookup(composingLiteral) {
            lex = d.weights.wLex * raw
        } else {
            lex = d.weights.wLex * Self.cUnkPlaceholder
        }
        return spatial + lex + d.weights.wLen * Double(composingLiteral.count)
    }

    /// Yer tutucu `c_unk`. Gerçek değer paket üretiminde hesaplanacak (§7).
    private static let cUnkPlaceholder = 14.0

    /// `θ(literal, ctx)` — artan koruma eşiği (§8).
    private func theta() -> Double {
        // Literal bilinen bir kelimeyse asla değiştirme.
        if trie?.lookup(composingLiteral) != nil { return .infinity }
        // Kod/literal token koruma kuralları (§5c A/B).
        if Self.isProtectedToken(composingLiteral) { return .infinity }
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

    private func commit(word: String) {
        for _ in 0..<composingLiteral.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(word + " ")
        resetComposing()
    }

    private func resetComposing() {
        composingLiteral = ""
        composingTouches.removeAll(keepingCapacity: true)
        if let d = decoder { incremental = IncrementalDecoder(decoder: d) }
        suggestionBar.setCandidates([])
    }
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
