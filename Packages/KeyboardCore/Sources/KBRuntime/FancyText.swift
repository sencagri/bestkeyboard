import Foundation

/// "Fontlu" yazı — harfleri Unicode'un **matematiksel harf** bloklarındaki
/// benzerleriyle değiştirir (𝐤𝐚𝐥ı𝐧, 𝓮𝓵 𝔂𝓪𝔃ı𝓼ı, 𝔉𝔯𝔞𝔨𝔱𝔲𝔯, ⓑⓤⓑⓞⓛ).
///
/// ## Neden gerçek font değil
///
/// Klavye karşı uygulamanın yazı tipini değiştiremiyor; gönderebildiği tek
/// şey karakter. Bu karakterler her uygulamada ve her telefonda aynı görünür.
///
/// ## Türkçe harfler
///
/// Bloklarda ç ğ ö ş ü yok. Stilli taban harfe **birleşen işaret** ekleniyor
/// (c + U+0327 → ç). Çoğu telefonda düzgün görünüyor; ı için yalnız italikte
/// karşılık var (𝚤), diğer stillerde ı olduğu gibi kalıyor.
public enum FancyText {

    public enum Style: String, CaseIterable, Codable, Sendable {
        case bold, italic, boldItalic, script, boldScript, fraktur, doubleStruck,
             sans, sansBold, mono, circled

        public var title: String {
            switch self {
            case .bold: return "Kalın"
            case .italic: return "İtalik"
            case .boldItalic: return "Kalın italik"
            case .script: return "El yazısı"
            case .boldScript: return "Kalın el yazısı"
            case .fraktur: return "Gotik"
            case .doubleStruck: return "Çift çizgi"
            case .sans: return "Sade"
            case .sansBold: return "Sade kalın"
            case .mono: return "Daktilo"
            case .circled: return "Yuvarlak"
            }
        }

        /// (büyük A, küçük a, 0) başlangıç kod noktaları; `nil` = rakam yok.
        fileprivate var bases: (UInt32, UInt32, UInt32?) {
            switch self {
            case .bold: return (0x1D400, 0x1D41A, 0x1D7CE)
            case .italic: return (0x1D434, 0x1D44E, nil)
            case .boldItalic: return (0x1D468, 0x1D482, nil)
            case .script: return (0x1D49C, 0x1D4B6, nil)
            case .boldScript: return (0x1D4D0, 0x1D4EA, nil)
            case .fraktur: return (0x1D504, 0x1D51E, nil)
            case .doubleStruck: return (0x1D538, 0x1D552, 0x1D7D8)
            case .sans: return (0x1D5A0, 0x1D5BA, 0x1D7E2)
            case .sansBold: return (0x1D5D4, 0x1D5EE, 0x1D7EC)
            case .mono: return (0x1D670, 0x1D68A, 0x1D7F6)
            case .circled: return (0x24B6, 0x24D0, nil)
            }
        }

        /// Bloktaki boşluklar: bu harfler Unicode'a daha önce "Harfli
        /// Semboller" bloğunda girmiş, matematik bloğunda yerleri boş.
        fileprivate var holes: [Character: Character] {
            switch self {
            case .italic: return ["h": "ℎ"]
            case .script: return ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ",
                                  "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ"]
            case .fraktur: return ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"]
            case .doubleStruck: return ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            default: return [:]
            }
        }
    }

    /// Türkçe harf → (taban harf, birleşen işaret).
    private static let turkish: [Character: (Character, Character)] = [
        "ç": ("c", "\u{0327}"), "Ç": ("C", "\u{0327}"),
        "ş": ("s", "\u{0327}"), "Ş": ("S", "\u{0327}"),
        "ğ": ("g", "\u{0306}"), "Ğ": ("G", "\u{0306}"),
        "ö": ("o", "\u{0308}"), "Ö": ("O", "\u{0308}"),
        "ü": ("u", "\u{0308}"), "Ü": ("U", "\u{0308}"),
        "İ": ("I", "\u{0307}"),
    ]

    public static func apply(_ style: Style, to text: String) -> String {
        var out = ""
        for ch in text { out += convert(ch, style) }
        return out
    }

    /// Tek karakter. Karşılığı olmayan (noktalama, emoji, ı) olduğu gibi döner.
    public static func convert(_ ch: Character, _ style: Style) -> String {
        if let (base, mark) = turkish[ch] { return convert(base, style) + String(mark) }
        if ch == "ı" { return style == .italic ? "𝚤" : "ı" }
        if let h = style.holes[ch] { return String(h) }
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return String(ch) }
        let (upper, lower, digit) = style.bases
        let code: UInt32?
        switch v {
        case 0x41...0x5A: code = upper + (v - 0x41)
        case 0x61...0x7A: code = lower + (v - 0x61)
        case 0x30...0x39:
            if let digit { code = digit + (v - 0x30) }
            else if style == .circled { code = v == 0x30 ? 0x24EA : 0x2460 + (v - 0x31) }
            else { code = nil }
        default: code = nil
        }
        return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(ch)
    }
}
