import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
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
        keyboardView.onKeyDown = { [weak self] hit in self?.handle(hit) }

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
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                guard let url = Bundle(for: Self.self).url(forResource: "tr-TR", withExtension: "bkt") else {
                    throw NSError(domain: "pack", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "tr-TR.bkt bundle'da yok"])
                }
                // mmap — paket ayrıştırılmaz, eşlenir (§11.A/D).
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let trie = try FormTrie(bytes: [UInt8](data))
                let spatial = SpatialModel(layout: self.layout)
                let decoder = Decoder(layout: self.layout, spatial: spatial, trie: trie, beamWidth: 128)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

                DispatchQueue.main.async {
                    self.trie = trie
                    self.decoder = decoder
                    self.incremental = IncrementalDecoder(decoder: decoder)
                    self.loadReport = String(format: "%d kelime · %.0f ms", trie.nodeCount, ms)
                    self.suggestionBar.setStatus("hazır — \(self.loadReport)")
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
            composingTouches.append(TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent()))
            updateSuggestions()

        case let .function(fk):
            switch fk {
            case .space:
                autocorrectAndCommitSpace()
            case .backspace:
                textDocumentProxy.deleteBackward()
                if !composingLiteral.isEmpty {
                    composingLiteral.removeLast()
                    composingTouches.removeLast()
                    rebuildIncremental()
                    updateSuggestions()
                }
            case .ret:
                resetComposing()
                textDocumentProxy.insertText("\n")
            case .globe:
                advanceToNextInputMode()
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

    private func updateSuggestions() {
        guard let d = decoder, !composingTouches.isEmpty else {
            suggestionBar.setCandidates([])
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        var inc = IncrementalDecoder(decoder: d)
        for t in composingTouches { inc.append(t) }
        incremental = inc
        let results = inc.results(topK: 3)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // Marj politikası: kazanandan çok geride kalan aday gösterilmez.
        var shown = results
        if let best = results.first {
            shown = results.filter { $0.cost - best.cost <= 3.0 }
        }
        suggestionBar.setCandidates(shown.map(\.word))
        suggestionBar.setStatus(String(format: "%.1f ms · %@", ms, loadReport))
    }

    /// Boşluk: commit politikası (§8) — basitleştirilmiş.
    /// Literal leksikonda varsa **asla değiştirilmez**; yoksa en iyi aday marjı
    /// aşıyorsa uygulanır.
    private func autocorrectAndCommitSpace() {
        defer {
            textDocumentProxy.insertText(" ")
            resetComposing()
        }
        guard let d = decoder, !composingTouches.isEmpty else { return }
        var inc = IncrementalDecoder(decoder: d)
        for t in composingTouches { inc.append(t) }
        let results = inc.results(topK: 2)
        guard let best = results.first else { return }

        // Literal bilinen bir kelimeyse dokunma.
        if trie?.lookup(composingLiteral) != nil { return }
        // Marj yetersizse dokunma.
        if results.count >= 2, results[1].cost - best.cost < 1.5 { return }
        guard best.word != composingLiteral else { return }

        for _ in 0..<composingLiteral.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(best.word)
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
