import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder

/// Uygulama içi klavye tezgahı.
///
/// Uzantıyla **aynı** `KeyboardView`'ı ve **aynı** decoder'ı kullanır; farkı
/// metni `UITextDocumentProxy` yerine kendi etiketine yazmasıdır. Amacı:
/// uzamsal dokunma → normalize koordinat → kod çözme yolunu gerçek UIKit
/// dokunma olaylarıyla, XCUITest'ten sürülebilir biçimde sınamak.
final class HarnessViewController: UIViewController {

    private let layout = TurkishQ.layout()
    private var decoder: Decoder?
    private var touches: [TouchSample] = []
    private var literal = ""

    private let literalLabel = UILabel()
    private let topLabel = UILabel()
    private let allLabel = UILabel()
    private let statusLabel = UILabel()
    private var keyboardView: KeyboardView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        for (l, size, id) in [(literalLabel, 20.0, "harness.literal"),
                              (topLabel, 26.0, "harness.top"),
                              (allLabel, 13.0, "harness.all"),
                              (statusLabel, 11.0, "harness.status")] {
            l.font = .monospacedSystemFont(ofSize: size, weight: id == "harness.top" ? .bold : .regular)
            l.textAlignment = .center
            l.numberOfLines = 0
            l.accessibilityIdentifier = id
            l.isAccessibilityElement = true
            l.text = ""
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
        }
        literalLabel.textColor = .secondaryLabel
        statusLabel.textColor = .tertiaryLabel

        keyboardView = KeyboardView(layout: layout)
        keyboardView.accessibilityIdentifier = "harness.keyboard"
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.onKeyDown = { [weak self] hit in self?.handle(hit) }
        view.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            literalLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            literalLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            literalLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            topLabel.topAnchor.constraint(equalTo: literalLabel.bottomAnchor, constant: 10),
            topLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            allLabel.topAnchor.constraint(equalTo: topLabel.bottomAnchor, constant: 10),
            allLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            allLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: allLabel.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            keyboardView.heightAnchor.constraint(equalToConstant: 216),
        ])

        loadPack()
    }

    private func loadPack() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let url = Bundle.main.url(forResource: "tr-TR", withExtension: "bkt"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let trie = try? FormTrie(bytes: [UInt8](data)) else {
                DispatchQueue.main.async { self.statusLabel.text = "paket yüklenemedi" }
                return
            }
            let d = Decoder(layout: self.layout,
                            spatial: SpatialModel(layout: self.layout),
                            trie: trie, beamWidth: 128)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                self.decoder = d
                self.statusLabel.text = String(format: "paket hazır · %d düğüm · %.0f ms", trie.nodeCount, ms)
            }
        }
    }

    private func handle(_ hit: KeyboardView.KeyHit) {
        switch hit {
        case let .letter(index, point):
            literal.append(layout.keys[index].char)
            touches.append(TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent()))
            decode()
        case let .function(fk):
            switch fk {
            case .backspace:
                if !literal.isEmpty { literal.removeLast(); touches.removeLast() }
                decode()
            case .space, .ret:
                literal = ""; touches = []
                literalLabel.text = ""; topLabel.text = ""; allLabel.text = ""
            default: break
            }
        }
    }

    private func decode() {
        literalLabel.text = "literal: \(literal)"
        guard let d = decoder, !touches.isEmpty else {
            topLabel.text = ""; allLabel.text = ""
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        var inc = IncrementalDecoder(decoder: d)
        for t in touches { inc.append(t) }
        let r = inc.results(topK: 3)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        topLabel.text = r.first?.word ?? "—"
        allLabel.text = r.map { String(format: "%@ %.2f", $0.word, $0.cost) }.joined(separator: "   ")
        statusLabel.text = String(format: "%.2f ms · %d dokunma", ms, touches.count)
    }
}

struct HarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HarnessViewController { HarnessViewController() }
    func updateUIViewController(_ vc: HarnessViewController, context: Context) {}
}
