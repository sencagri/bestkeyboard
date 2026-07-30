import UIKit

/// Kullanıcının seçtiği tema.
///
/// `.system` cihazın açık/koyu kipini izler — üçüncü taraf klavyeler için tek
/// doğru varsayılan bu: host uygulama koyu kipteyken beyaz bir klavye açmak
/// göz kamaştırıyor.
enum ThemeChoice: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "Sistem"
        case .light:  return "Açık"
        case .dark:   return "Koyu"
        }
    }

    /// Seçimi somut bir temaya indirger.
    ///
    /// `.system`'de karar `UITraitCollection`'dan geliyor; klavye uzantısı
    /// host'un görünüm kipini trait üzerinden alıyor.
    func resolved(for traits: UITraitCollection) -> KeyboardTheme {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .system: return traits.userInterfaceStyle == .dark ? .dark : .light
        }
    }
}

/// Klavye yüzeyinin renkleri.
///
/// ## Neden `UIColor(dynamicProvider:)` değil
///
/// Katmanlara `cgColor` yazıyoruz (§11.B: tuş başına `UIView` yok). `CALayer`
/// dinamik `UIColor`'ı çözemez — `cgColor`'a çevrildiği andaki kipte donar ve
/// kip değişince katman eski rengiyle kalır. Bu yüzden tema **açıkça** çözülüp
/// `traitCollectionDidChange`'de yeniden uygulanıyor.
struct KeyboardTheme: Equatable {
    /// Tuşların arasında görünen zemin.
    let background: UIColor
    /// Harf/rakam tuşu.
    let keyFace: UIColor
    let keyText: UIColor
    /// İşlev tuşu (⇧, ⌫, 123, boşluk, ⏎) — harften ayırt edilebilmeli.
    let functionFace: UIColor
    let functionText: UIColor
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
    /// Klavyenin barındırıcı görünümü için — panel açıkken host'a sızmasın.
    let userInterfaceStyle: UIUserInterfaceStyle

    static let light = KeyboardTheme(
        background: UIColor(white: 0.82, alpha: 1),
        keyFace: .white,
        keyText: .black,
        functionFace: UIColor(white: 0.70, alpha: 1),
        functionText: .black,
        pressedFace: UIColor(red: 0.62, green: 0.78, blue: 1.0, alpha: 1),
        pressedText: .black,
        barFace: UIColor(white: 0.90, alpha: 1),
        barText: .black,
        barSecondaryText: UIColor(white: 0.35, alpha: 1),
        panelFace: UIColor(white: 0.95, alpha: 1),
        panelText: .black,
        accent: UIColor(red: 0.0, green: 0.42, blue: 0.86, alpha: 1),
        separator: UIColor(white: 0.72, alpha: 1),
        userInterfaceStyle: .light)

    /// Koyu tema, iOS'un koyu klavyesiyle aynı mantıkta: zemin en koyu, harf
    /// tuşu zeminden **açık**, işlev tuşu arada. Harf tuşunu zeminden koyu
    /// yapmak (bazı temaların yaptığı gibi) basılacak yeri gölge gibi
    /// gösteriyor — hedefin çıkıntı gibi durması gerekiyor.
    static let dark = KeyboardTheme(
        background: UIColor(white: 0.12, alpha: 1),
        keyFace: UIColor(white: 0.30, alpha: 1),
        keyText: .white,
        functionFace: UIColor(white: 0.20, alpha: 1),
        functionText: .white,
        pressedFace: UIColor(red: 0.24, green: 0.42, blue: 0.70, alpha: 1),
        pressedText: .white,
        barFace: UIColor(white: 0.16, alpha: 1),
        barText: .white,
        barSecondaryText: UIColor(white: 0.62, alpha: 1),
        panelFace: UIColor(white: 0.15, alpha: 1),
        panelText: .white,
        accent: UIColor(red: 0.25, green: 0.62, blue: 1.0, alpha: 1),
        separator: UIColor(white: 0.30, alpha: 1),
        userInterfaceStyle: .dark)
}
