import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import KBSpatial
import KBLexicon
import KBDecoder
import KBAssembly

/// Uygulama içi klavye tezgahı.
///
/// Uzantıyla **aynı** `KeyboardView`'ı ve **aynı** decoder'ı kullanır; farkı
/// metni `UITextDocumentProxy` yerine kendi etiketine yazmasıdır. Amacı:
/// uzamsal dokunma → normalize koordinat → kod çözme yolunu gerçek UIKit
/// dokunma olaylarıyla, XCUITest'ten sürülebilir biçimde sınamak.
final class HarnessViewController: UIViewController {

    private var settings: KeyboardSettings
    private var layout: KeyLayout
    private var decoder: Decoder?
    private var touches: [TouchSample] = []
    private var incremental: IncrementalDecoder?
    private var literal = ""

    private let literalLabel = UILabel()
    private let topLabel = UILabel()
    private let allLabel = UILabel()
    private let statusLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private var keyboardView: KeyboardView!
    private var keyboardHeight: NSLayoutConstraint!
    private var settingsPanel: KeyboardSettingsPanel?

    /// Uzantıyla aynı satır yüksekliği — tezgahta ölçülen geometri cihazdakiyle
    /// aynı olmalı, yoksa burada doğrulanan bir şey orada geçerli olmaz.

    init() {
        // Tek okuma: `settings.metrics` ile `layout`un **aynı** snapshot'tan
        // geldiği kodla garanti ediliyor, iki ayrı `load()` çağrısıyla değil.
        let s = KeyboardSettingsStore.load()
        self.settings = s
        self.layout = TurkishQ.layout(metrics: s.metrics)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

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

        keyboardView = KeyboardView(layout: layout, metrics: settings.metrics)
        keyboardView.cadence = settings.cadence
        keyboardView.accessibilityIdentifier = "harness.keyboard"
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        // Tezgahta iki etkinleştirme türü ayırt edilmiyor: burada öğrenilen
        // hiçbir şey diske yazılmıyor ve kayıt tutulmuyor, dolayısıyla
        // türetilmiş kanıtın kalıcı zarar verebileceği bir yer yok. Ayrımın
        // gerçek yeri uzantı.
        keyboardView.onKeyCommit = { [weak self] hit, _ in self?.handle(hit) }
        keyboardView.onPeriodLongPress = { [weak self] in self?.handle(.symbol(",")) }
        view.addSubview(keyboardView)

        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.accessibilityIdentifier = "harness.settings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.addAction(UIAction { [weak self] _ in self?.toggleSettingsPanel() },
                                 for: .touchUpInside)
        view.addSubview(settingsButton)

        keyboardHeight = keyboardView.heightAnchor.constraint(
            equalToConstant: KeyboardView.height(for: settings.metrics))
        // Zorunlu değil (999): sayı sırası + uzun boşluk satırı en fazla
        // 5.75 satır istiyor ve dar bir yatay ekranda sistem bu kadar yer
        // vermeyebilir. Zorunlu bırakmak constraint kırılması demekti; 999 ile
        // kısıt esniyor ve klavye sığdığı kadarını alıyor.
        //
        // Geometri bundan zarar görmüyor: `KeyboardView` her şeyi **kendi
        // bounds'una** göre normalize ediyor, yani çizim ve dokunma hizalı
        // kalıyor — yalnız tuşlar kısalıyor.
        keyboardHeight.priority = .required - 1

        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

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
            keyboardHeight,
        ])

        // Katmanlara `cgColor` yazıldığı için dinamik renk çözülmüyor.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (vc: HarnessViewController, _: UITraitCollection) in vc.applyTheme()
        }
        applyTheme()

        loadPack()
    }

    // MARK: - Tema ve ayarlar

    private var resolvedTheme: KeyboardTheme {
        settings.theme.resolved(for: traitCollection)
    }

    private func applyTheme() {
        let t = resolvedTheme
        keyboardView.theme = t
        settingsPanel?.apply(theme: t)
        // Tezgahın kendi yüzeyi de seçilen kipe geçiyor: koyu klavyeyi beyaz
        // bir sayfanın üstünde görmek temanın nasıl duracağını göstermiyor.
        // (`systemBackground`/`label` böylece doğru tarafa çözülüyor.)
        view.overrideUserInterfaceStyle = t.userInterfaceStyle
    }

    /// Ekran görüntüsü için: `-openPanel` ile ⚙︎ paneli açık başlar.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ProcessInfo.processInfo.arguments.contains("-openPanel"), settingsPanel == nil {
            toggleSettingsPanel()
        }
    }

    private func toggleSettingsPanel() {
        if let p = settingsPanel {
            p.removeFromSuperview()
            settingsPanel = nil
            rebuildModel()   // panel kapanır kapanmaz yazılabiliyor
            return
        }
        // Panel klavyenin üstünü kaplasa da zaten basılı parmaklar olaylarını
        // almaya devam ediyor.
        keyboardView.cancelInteraction()
        // Tezgahta globe çizilmiyor (uzantı değiliz); boşluk aralığı da o
        // varsayımla hesaplanmalı.
        let p = KeyboardSettingsPanel(settings: settings, theme: resolvedTheme,
                                      showsGlobe: keyboardView.showsGlobeKey)
        p.onChange = { [weak self] s in self?.apply(settings: s) }
        p.onClose = { [weak self] in self?.toggleSettingsPanel() }
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            p.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            p.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        settingsPanel = p
    }

    private func apply(settings new: KeyboardSettings) {
        let old = settings
        settings = new
        KeyboardSettingsStore.save(new)
        if new.theme != old.theme { applyTheme() }
        if new.cadence != old.cadence { keyboardView.cadence = new.cadence }
        guard new.metrics != old.metrics else { return }

        keyboardHeight.constant = KeyboardView.height(for: new.metrics)
        // Çizim anında; ağır kısım sürükleme durana kadar erteleniyor
        // (uzantıyla aynı gerekçe, bkz. `KeyboardViewController`).
        keyboardView.apply(layout: layout, metrics: new.metrics)
        guard !new.metrics.sharesLetterGeometry(with: old.metrics) else { return }

        // Eski decoder **hemen** düşürülüyor: yeniden yükleme beklenirken
        // basılan tuşlar eski geometrinin uzamsal modeline gitmemeli.
        decoder = nil; incremental = nil
        literal = ""; touches = []
        literalLabel.text = ""; topLabel.text = ""; allLabel.text = ""
        statusLabel.text = "yeniden yükleniyor…"
        scheduleModelRebuild()
    }

    private var modelRebuild: Timer?

    private func scheduleModelRebuild() {
        modelRebuild?.invalidate()
        let t = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.rebuildModel()
        }
        RunLoop.main.add(t, forMode: .common)
        modelRebuild = t
    }

    /// Temizse no-op — "kirli" bilgisi `layout.id` farkında, zamanlayıcıda değil.
    private func rebuildModel() {
        modelRebuild?.invalidate(); modelRebuild = nil
        guard layout.id != TurkishQ.layout(metrics: settings.metrics).id else { return }
        // Harf geometrisi değişti: decoder'ın uzamsal modeli de yeni tuş
        // merkezlerinden kurulmalı, yoksa çizilen ile skorlanan ayrışır.
        layout = TurkishQ.layout(metrics: settings.metrics)
        keyboardView.apply(layout: layout, metrics: settings.metrics)
        loadPack()
    }

    /// Yükleme kuşağı — uzantıyla aynı gerekçe: ölçü değişimi yeni bir yükleme
    /// başlatıyor ve eskisi iptal edilemiyor. Kuşak kontrolü olmadan geç biten
    /// eski yükleme, yeni geometriyle kurulmuş decoder'ı eskisiyle ezerdi.
    private var loadGeneration = 0

    private func loadPack() {
        loadGeneration += 1
        let generation = loadGeneration
        let layout = self.layout          // arka planda `self.layout` okumak yarış olurdu
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let loaded = try? PackLoader.load(layout: layout, bundle: .main) else {
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    self.statusLabel.text = "paket yüklenemedi"
                }
                return
            }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.decoder = loaded.decoder
                // Yükleme sürerken basılmış tuşlar varsa beam onlarla kurulmalı;
                // boş bir `IncrementalDecoder` `touches` ile ayrışırdı.
                self.rebuildIncremental()
                self.statusLabel.text = "hazır — " + loaded.report
                if !self.touches.isEmpty { self.decode() }
            }
        }
    }

    private func handle(_ hit: KeyboardView.KeyHit) {
        switch hit {
        case let .letter(index, point):
            literal.append(layout.keys[index].char)
            let sample = TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent())
            touches.append(sample)
            incremental?.append(sample)     // §11.C.1 artımlı
            decode()
        case let .symbol(ch), let .digit(ch):
            // Tezgah kod çözmeyi gösteriyor; sembol modele girmediği için
            // yalnız literal'e ekleniyor ve token sınırı sayılıyor.
            literal.append(ch)
            literalLabel.text = "literal: \(literal)"
        case let .function(fk):
            switch fk {
            case .backspace:
                if !literal.isEmpty { literal.removeLast(); touches.removeLast() }
                rebuildIncremental()
                decode()
            case .space, .ret:
                literal = ""; touches = []
                rebuildIncremental()
                literalLabel.text = ""; topLabel.text = ""; allLabel.text = ""

            // Düzlem ve shift **tezgahta da çalışıyor**.
            //
            // Eskiden `default: break` idi: `123`'e basan kullanıcı hiçbir şey
            // olmadığını görüyordu ve bunun bir tezgah eksiği mi yoksa klavye
            // hatası mı olduğu anlaşılmıyordu. Tezgahın işi klavyeyi göstermek;
            // sessizce yutulan bir tuş o işi bozuyor.
            //
            // **Kod çözmeye etkisi yok.** Shift yalnız görünen etiketi
            // değiştiriyor, `literal`'e küçük harf giriyor — uzantıdaki kuralın
            // aynısı: uzamsal kanıt küçük harf tuşuna ait (§8.9'daki
            // `insertShiftedLetter` gerekçesi).
            case .shift:
                keyboardView.isUppercase.toggle()
            case .numbers:
                keyboardView.plane = .numbers
            case .symbols:
                keyboardView.plane = .symbols
            case .letters:
                keyboardView.plane = .letters
            case .globe:
                break          // tezgahta sistem klavyesine geçiş yok

            // Nokta sembol gibi davranıyor — uzantıda da öyle.
            case .period:
                handle(.symbol("."))
            }
        }
    }

    private func rebuildIncremental() {
        guard let d = decoder else { return }
        var inc = IncrementalDecoder(decoder: d)
        for t in touches { inc.append(t) }
        incremental = inc
    }

    private func decode() {
        literalLabel.text = "literal: \(literal)"
        guard let inc = incremental, !touches.isEmpty else {
            topLabel.text = ""; allLabel.text = ""
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
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
