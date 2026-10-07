import UIKit
import CoreText

/// Kullanıcının seçtiği tema — kalıcı **kimlik**.
///
/// `.system` cihazın açık/koyu kipini izler — üçüncü taraf klavyeler için tek
/// doğru varsayılan bu: host uygulama koyu kipteyken beyaz bir klavye açmak
/// göz kamaştırıyor. Diğer değerler hazır temaların kimliği.
///
/// Bir dönem `system/light/dark` üç durumlu bir enum'du; kayıtlı değer
/// (`kb.theme`) aynı ham dizgi olarak kaldı, `light` ve `dark` hazır temaların
/// kimliği olarak yaşıyor — eski ayarı olan kullanıcı temasını kaybetmiyor.
struct ThemeChoice: RawRepresentable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let system = ThemeChoice(rawValue: "system")
    static let light = ThemeChoice(rawValue: "light")
    static let dark = ThemeChoice(rawValue: "dark")

    /// Seçilebilir her şey: önce `.system`, sonra kullanıcının temaları,
    /// sonra hazır temalar.
    static var allCases: [ThemeChoice] {
        [.system] + CustomThemeStore.load().map { ThemeChoice(rawValue: $0.id) }
            + ThemeSpec.presets.map { ThemeChoice(rawValue: $0.id) }
    }

    /// Tanınmayan bir kimlik (silinmiş tema, başka sürüm) `.system`'e düşüyor.
    var isKnown: Bool { self == .system || ThemeSpec.find(id: rawValue) != nil }

    var title: String {
        self == .system ? "Sistem" : (ThemeSpec.find(id: rawValue)?.name ?? "Sistem")
    }

    /// Seçimi somut bir temaya indirger.
    ///
    /// `.system`'de karar `UITraitCollection`'dan geliyor; klavye uzantısı
    /// host'un görünüm kipini trait üzerinden alıyor.
    func resolved(for traits: UITraitCollection) -> KeyboardTheme {
        if self != .system, let spec = ThemeSpec.find(id: rawValue) {
            return spec.resolved(loadImage: spec.isCustom ? CustomThemeStore.image : ThemeSpec.bundleImage)
        }
        return traits.userInterfaceStyle == .dark ? .dark : .light
    }
}

/// Bir temanın **tarifi** — hazır temalar ve kullanıcının düzenlediği temalar
/// aynı biçimde.
///
/// `Codable`: uygulamadaki düzenleyici temayı JSON olarak yazacak ve klavye
/// okuyacak. Renkler `#RRGGBB` dizgisi; saydamlık ayrı alan, çünkü
/// düzenleyici onu ayrı bir sürgüyle veriyor ve renk seçici saydamlığı
/// taşımıyor.
struct ThemeSpec: Codable, Equatable {
    enum Background: Codable, Equatable {
        case solid(String)
        /// Üstten alta (hafif çapraz) iki renk.
        case gradient(String, String)
        /// `file`: hazır temada paket kaynağının adı, özel temada ortak
        /// klasördeki dosya. `dim`: üstüne binen siyahın opaklığı (0…0.7).
        case photo(file: String, dim: Double)
    }

    var id: String
    var name: String
    var background: Background
    var key: String
    var keyAlpha: Double = 1
    var keyText: String
    var function: String
    var functionAlpha: Double = 1
    var functionText: String
    /// `⏎` ve basılı vurgu.
    var accent: String
    var accentText: String
    /// Öneri çubuğu ve paneller koyu kipte mi — yazı rengi açıksa evet.
    var isDark: Bool
    var border: Bool = false
    var shadow: Bool = true
    var cornerRadius: Double = 7
    /// Tuş yazı tipi (tasarım 25): `nil` sistem, "rounded" yuvarlak,
    /// "serif" klasik, "mono" daktilo, "condensed" dar. İsteğe bağlı —
    /// eski kayıtlı temalar bu alan olmadan da okunuyor.
    var keyFont: String? = nil
    /// "light" / "regular" / "bold"; `nil` = normal.
    var keyWeight: String? = nil

    /// Tuş harflerinin yazı tipi; boyutu katman veriyor.
    func keyCTFont() -> CTFont? {
        guard keyFont != nil || keyWeight != nil else { return nil }
        let weight: UIFont.Weight = keyWeight == "light" ? .regular : keyWeight == "bold" ? .bold : .medium
        if keyFont == "condensed" {
            let name = keyWeight == "bold" ? "AvenirNextCondensed-Bold" : "AvenirNextCondensed-Medium"
            return (UIFont(name: name, size: 20) ?? .systemFont(ofSize: 20, weight: weight)) as CTFont
        }
        let base = UIFont.systemFont(ofSize: 20, weight: weight)
        let design: UIFontDescriptor.SystemDesign? = switch keyFont {
            case "rounded": .rounded
            case "serif": .serif
            case "mono": .monospaced
            default: nil
        }
        guard let design, let d = base.fontDescriptor.withDesign(design) else { return base as CTFont }
        return UIFont(descriptor: d, size: 20) as CTFont
    }

    /// Çizime hazır tema. Fotoğraf `loadImage` ile yükleniyor; hazır temada
    /// paket kaynağı, özel temada ortak klasör.
    func resolved(loadImage: (String) -> UIImage? = ThemeSpec.bundleImage) -> KeyboardTheme {
        let keyText = UIColor(hex: keyText)
        let fnText = UIColor(hex: functionText)
        let backdrop: KeyboardTheme.Backdrop
        let base: UIColor
        switch background {
        case let .solid(c):
            base = UIColor(hex: c); backdrop = .solid(base)
        case let .gradient(a, b):
            base = UIColor(hex: a); backdrop = .gradient(UIColor(hex: a), UIColor(hex: b))
        case let .photo(file, dim):
            base = isDark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.82, alpha: 1)
            backdrop = .photo(loadImage(file), dim: CGFloat(min(max(dim, 0), 0.7)))
        }
        let accent = UIColor(hex: accent)
        return KeyboardTheme(
            background: base,
            backdrop: backdrop,
            keyFace: UIColor(hex: key, alpha: keyAlpha),
            keyText: keyText,
            functionFace: UIColor(hex: function, alpha: functionAlpha),
            functionText: fnText,
            returnFace: accent,
            returnText: UIColor(hex: accentText),
            pressedFace: accent.withAlphaComponent(0.85),
            pressedText: UIColor(hex: accentText),
            barFace: .clear,
            barText: keyText,
            barSecondaryText: keyText.withAlphaComponent(0.72),
            panelFace: isDark ? UIColor(white: 0.15, alpha: 1) : UIColor(white: 0.95, alpha: 1),
            panelText: isDark ? .white : .black,
            accent: isDark ? UIColor(red: 0.25, green: 0.62, blue: 1.0, alpha: 1)
                           : UIColor(red: 0.0, green: 0.42, blue: 0.86, alpha: 1),
            separator: isDark ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 0.72, alpha: 1),
            keyBorder: border ? (isDark ? UIColor(white: 1, alpha: 0.22)
                                        : UIColor(white: 0, alpha: 0.22)) : nil,
            keyShadow: shadow,
            cornerRadius: CGFloat(cornerRadius),
            userInterfaceStyle: isDark ? .dark : .light,
            keyFont: keyCTFont())
    }

    static func bundleImage(_ name: String) -> UIImage? {
        // Klavye boyutuna yakın tutulmuş bir kaynak; uzantının bellek
        // bütçesi dar, büyük bir fotoğrafı açmak paket yükleme tepesinin
        // üstüne binerdi.
        Bundle(for: ThemeBackdropView.self).path(forResource: name, ofType: nil)
            .flatMap(UIImage.init(contentsOfFile:))
    }

    static func preset(id: String) -> ThemeSpec? { presets.first { $0.id == id } }

    /// Hazır ya da kullanıcının teması.
    static func find(id: String) -> ThemeSpec? {
        preset(id: id) ?? CustomThemeStore.load().first { $0.id == id }
    }

    /// Kullanıcının düzenleyicide yaptığı tema — kimliği `custom-` ile başlıyor.
    var isCustom: Bool { id.hasPrefix("custom-") }

    /// Hazır temalar — tasarım tuvalindeki galeriyle aynı değerler.
    /// Her etiket kendi zeminine karşı en az 4.5:1.
    static let presets: [ThemeSpec] = [
        ThemeSpec(id: "light", name: "Klasik Açık", background: .solid("#D1D3D9"),
                  key: "#FFFFFF", keyText: "#111214", function: "#ADB3BC", functionText: "#111214",
                  accent: "#0A66D6", accentText: "#FFFFFF", isDark: false),
        ThemeSpec(id: "dark", name: "Klasik Koyu", background: .solid("#1E1F22"),
                  key: "#4A4B50", keyText: "#FFFFFF", function: "#2F3034", functionText: "#FFFFFF",
                  accent: "#2F7DF6", accentText: "#FFFFFF", isDark: true),
        ThemeSpec(id: "manzara", name: "Manzara", background: .photo(file: "manzara.jpg", dim: 0.25),
                  key: "#FFFFFF", keyAlpha: 0.22, keyText: "#FFFFFF",
                  function: "#000000", functionAlpha: 0.28, functionText: "#FFFFFF",
                  accent: "#FFB38A", accentText: "#111214", isDark: true,
                  shadow: false, cornerRadius: 9),
        ThemeSpec(id: "gece", name: "Gece", background: .solid("#000000"),
                  key: "#1C1C1E", keyText: "#F5F5F7", function: "#0E0E10", functionText: "#C7C7CC",
                  accent: "#FF9F0A", accentText: "#1A1000", isDark: true,
                  border: true, shadow: false),
        ThemeSpec(id: "kontrast", name: "Yüksek Kontrast", background: .solid("#000000"),
                  key: "#FFFFFF", keyText: "#000000", function: "#FFD60A", functionText: "#000000",
                  accent: "#FFD60A", accentText: "#000000", isDark: true, shadow: false),
        ThemeSpec(id: "okyanus", name: "Okyanus", background: .gradient("#0B3D6B", "#0E6E8C"),
                  key: "#FFFFFF", keyAlpha: 0.18, keyText: "#FFFFFF",
                  function: "#00142A", functionAlpha: 0.30, functionText: "#E6F4FF",
                  accent: "#3FD0C9", accentText: "#04263A", isDark: true, shadow: false),
        ThemeSpec(id: "orman", name: "Orman", background: .solid("#1B3326"),
                  key: "#2E5240", keyText: "#F1FAF3", function: "#142A1F", functionText: "#CFE6D6",
                  accent: "#7BD389", accentText: "#0E2418", isDark: true),
        ThemeSpec(id: "lavanta", name: "Lavanta", background: .solid("#E3DDF4"),
                  key: "#FFFFFF", keyText: "#2A2140", function: "#C7BDE6", functionText: "#2A2140",
                  accent: "#5B3FD0", accentText: "#FFFFFF", isDark: false),
        ThemeSpec(id: "gunbatimi", name: "Gün Batımı", background: .gradient("#FF8A5B", "#E5487A"),
                  key: "#FFFFFF", keyAlpha: 0.92, keyText: "#3A1020",
                  function: "#FFFFFF", functionAlpha: 0.55, functionText: "#3A1020",
                  accent: "#4A1426", accentText: "#FFFFFF", isDark: false),
        ThemeSpec(id: "kum", name: "Kum", background: .solid("#E7DCCB"),
                  key: "#FBF7F0", keyText: "#3B2F22", function: "#D3C3AA", functionText: "#3B2F22",
                  accent: "#9C4F1C", accentText: "#FFFFFF", isDark: false),
        ThemeSpec(id: "grafit", name: "Grafit", background: .solid("#34373C"),
                  key: "#575B62", keyText: "#FFFFFF", function: "#26292D", functionText: "#D9DCE0",
                  accent: "#5BE0B0", accentText: "#0D2A20", isDark: true),
    ]
}

/// Klavye yüzeyinin çizime hazır teması.
///
/// ## Neden `UIColor(dynamicProvider:)` değil
///
/// Katmanlara `cgColor` yazıyoruz (§11.B: tuş başına `UIView` yok). `CALayer`
/// dinamik `UIColor`'ı çözemez — `cgColor`'a çevrildiği andaki kipte donar ve
/// kip değişince katman eski rengiyle kalır. Bu yüzden tema **açıkça** çözülüp
/// `traitCollectionDidChange`'de yeniden uygulanıyor.
struct KeyboardTheme: Equatable {
    enum Backdrop: Equatable {
        case solid(UIColor)
        case gradient(UIColor, UIColor)
        /// Görsel yüklenemezse `nil`: zemin rengi kalıyor, klavye boş kalmıyor.
        case photo(UIImage?, dim: CGFloat)
    }

    /// Tuşların arasında görünen zemin — düz renk ya da gradyan/fotoğrafın
    /// yedeği (panel kapanırken, görsel yüklenmeden).
    let background: UIColor
    /// Klavyenin **tamamının** arkası: öneri çubuğu dahil.
    var backdrop: Backdrop
    /// Harf/rakam tuşu ve boşluk.
    let keyFace: UIColor
    let keyText: UIColor
    /// İşlev tuşu (⇧, ⌫, 123, nokta) — harften ayırt edilebilmeli.
    let functionFace: UIColor
    let functionText: UIColor
    /// `⏎` — temanın vurgu rengi.
    let returnFace: UIColor
    let returnText: UIColor
    /// Basılı vurgu. Karar decoder'ı beklemiyor, `touchesBegan`'de basılıyor.
    let pressedFace: UIColor
    let pressedText: UIColor
    /// Öneri çubuğu.
    let barFace: UIColor
    let barText: UIColor
    let barSecondaryText: UIColor
    /// Ayar paneli.
    let panelFace: UIColor
    let panelText: UIColor
    let accent: UIColor
    /// Panelin ve çubuğun ayırıcı çizgisi.
    let separator: UIColor
    /// `nil`: kenarlık yok.
    let keyBorder: UIColor?
    /// Tuşun altındaki 1 pt'lik gölge (Apple klavyesinin "çıkıntısı").
    let keyShadow: Bool
    let cornerRadius: CGFloat
    /// Klavyenin barındırıcı görünümü için — panel açıkken host'a sızmasın.
    let userInterfaceStyle: UIUserInterfaceStyle
    /// Tuş harfleri (`nil` = katmanın varsayılanı).
    var keyFont: CTFont? = nil

    static let light = ThemeSpec.preset(id: "light")!.resolved()

    /// Koyu tema, iOS'un koyu klavyesiyle aynı mantıkta: zemin en koyu, harf
    /// tuşu zeminden **açık**, işlev tuşu arada. Harf tuşunu zeminden koyu
    /// yapmak (bazı temaların yaptığı gibi) basılacak yeri gölge gibi
    /// gösteriyor — hedefin çıkıntı gibi durması gerekiyor.
    static let dark = ThemeSpec.preset(id: "dark")!.resolved()
}

/// Temanın arka planı: düz renk, gradyan ya da fotoğraf + karartma.
///
/// Klavye uzantısında öneri çubuğunun ve tuş ızgarasının **ortak** arkası;
/// ikisi ayrı ayrı boyansaydı gradyan ve fotoğraf çubukla ızgara arasında
/// kırılırdı. Etkileşim almıyor.
final class ThemeBackdropView: UIView {
    private let gradient = CAGradientLayer()
    private let imageView = UIImageView()
    private let dimView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        gradient.startPoint = CGPoint(x: 0.3, y: 0)
        gradient.endPoint = CGPoint(x: 0.7, y: 1)
        layer.addSublayer(gradient)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        dimView.backgroundColor = .black
        addSubview(dimView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: KeyboardTheme) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backgroundColor = theme.background
        gradient.isHidden = true
        imageView.isHidden = true
        dimView.isHidden = true
        switch theme.backdrop {
        case .solid:
            break
        case let .gradient(a, b):
            gradient.colors = [a.cgColor, b.cgColor]
            gradient.isHidden = false
        case let .photo(image, dim):
            imageView.image = image
            imageView.isHidden = image == nil
            dimView.alpha = dim
            dimView.isHidden = image == nil || dim <= 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        imageView.frame = bounds
        dimView.frame = bounds
    }
}

extension UIScrollView {
    /// iOS 26'nın kaydırma kenarı efektini kapatır.
    ///
    /// iOS 26 her kaydırma görünümünün kenarlarına yumuşak bir bulanıklık
    /// koyuyor. 40 pt'lik emoji kategori çubuğunda içeriğin tamamı o bandın
    /// içinde kalıyordu ve sekmeler okunmaz lekelere dönüşmüştü (cihazda
    /// görüldü). Klavyenin küçük şeritlerinde bu efektin işlevi yok.
    func disableEdgeEffects() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
            leftEdgeEffect.isHidden = true
            rightEdgeEffect.isHidden = true
        }
    }
}

extension UIColor {
    /// `#RRGGBB` — geçersiz dizgi magenta veriyor ki tasarım hatası göze
    /// batsın, sessizce siyaha dönmesin.
    convenience init(hex: String, alpha: Double = 1) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(red: 1, green: 0, blue: 1, alpha: 1); return
        }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: CGFloat(alpha))
    }
}


/// Kullanıcının temaları — **ortak klasörde** (App Group): uygulamadaki
/// düzenleyici yazıyor, klavye okuyor. Klavye ortak klasöre yalnız Tam
/// Erişimle ulaşabiliyor; ulaşamazsa liste boş ve seçili özel tema
/// `.system`'e düşüyor (`ThemeChoice.isKnown`).
///
/// Fotoğraf uygulamada klavye boyutuna küçültülüp JPEG olarak yazılıyor —
/// uzantının dar bellek bütçesinde büyük bir fotoğraf açmamak için.
enum CustomThemeStore {
    static var directory: URL? {
        AppGroup.container?.appendingPathComponent(AppGroup.File.customThemes, isDirectory: true)
    }

    private static var cache: (stamp: Date, specs: [ThemeSpec])?

    static func load() -> [ThemeSpec] {
        guard let url = directory?.appendingPathComponent("custom.json") else { return [] }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let c = cache, c.stamp == stamp { return c.specs }
        let specs = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ThemeSpec].self, from: $0) } ?? []
        cache = (stamp, specs)
        return specs
    }

    static func save(_ specs: [ThemeSpec]) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(specs) {
            try? data.write(to: dir.appendingPathComponent("custom.json"), options: .atomic)
        }
        cache = nil
    }

    static func upsert(_ spec: ThemeSpec) {
        var all = load().filter { $0.id != spec.id }
        all.insert(spec, at: 0)
        save(all)
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
        if let dir = directory { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg")) }
    }

    static func image(_ file: String) -> UIImage? {
        directory.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent(file).path) }
    }

    /// Fotoğrafı klavye boyutuna (en uzun kenar 1200 px) küçültüp yazar.
    @discardableResult
    static func writePhoto(_ image: UIImage, for id: String) -> String? {
        guard let dir = directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let longest = max(image.size.width, image.size.height)
        let k = min(1, 1200 / max(longest, 1))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let name = "\(id).jpg"
        guard let data = scaled.jpegData(compressionQuality: 0.85),
              (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }
}

extension UIView {
    /// Paneller tuşların **üstünü** örtüyor; düz bir renk koymak temanın
    /// fotoğrafını/renk geçişini siliyordu (panel teması tutmuyordu). Panelin
    /// en altına temanın kendi arka planının bir kopyası konuyor.
    func applyPanelBackdrop(_ theme: KeyboardTheme) {
        let tag = 0x7EBD
        let b: ThemeBackdropView
        if let existing = viewWithTag(tag) as? ThemeBackdropView {
            b = existing
        } else {
            b = ThemeBackdropView(frame: bounds)
            b.tag = tag
            b.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            b.isUserInteractionEnabled = false
            insertSubview(b, at: 0)
        }
        backgroundColor = theme.background
        b.apply(theme)
    }
}
