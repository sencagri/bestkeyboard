import Foundation

/// Kısayol: bir şey yazınca öneri çubuğunda çıkan hazır çıktı.
///
/// **Hiçbir zaman kendiliğinden uygulanmıyor** — yalnız öneri; dokununca
/// tetikleyici silinip çıktı yazılıyor. Gerekçe "de" gibi iki harfli
/// tetikleyiciler: Türkçede hem ülke kodu hem sık kelime ve kendiliğinden
/// değiştirmek yazılanı bozardı.
struct TextShortcut: Codable, Hashable {
    enum Kind: String, Codable { case emoji, text, gif }
    var trigger: String
    var output: String
    var kind: Kind = .emoji

    /// Tetikleyici karşılaştırması Türkçe küçük harfle — `TR` de `tr` de tutar.
    var key: String { Self.normalize(trigger) }

    static func normalize(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr")).precomposedStringWithCanonicalMapping
    }
}

struct ShortcutGroup {
    let id: String
    let title: String
    let subtitle: String
    let items: [TextShortcut]
    let defaultOn: Bool
}

enum ShortcutLibrary {
    private static func e(_ t: String, _ o: String) -> TextShortcut { TextShortcut(trigger: t, output: o) }

    /// Hazır gruplar. Türkçe yazışmada sık görülenlerden derlendi; liste
    /// kullanıcının kendi kısayollarıyla genişliyor.
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(id: "flag-tr", title: "Türk bayrağı", subtitle: "tr → 🇹🇷",
                      items: [e("tr", "🇹🇷"), e("türkiye", "🇹🇷")], defaultOn: true),
        ShortcutGroup(id: "laugh", title: "Gülme", subtitle: "Yazdığın kahkaha emojiye dönsün",
                      items: [e("lol", "😂"), e("hahaha", "🤣"), e("hahah", "🤣"), e("ahahah", "🤣"),
                              e("ahaha", "😂"), e("sjsjsj", "😭"), e("skdjsk", "😭"), e(":d", "😄"),
                              e("xd", "😆"), e(":)", "🙂"), e(";)", "😉"), e(":p", "😛"),
                              e(":(", "🙁"), e(":'(", "😢"), e(":o", "😮")],
                      defaultOn: true),
        ShortcutGroup(id: "love", title: "Sevgi ve teşekkür", subtitle: "Gündelik ifadeler",
                      items: [e("<3", "❤️"), e("aşk", "😍"), e("tşk", "🙏"), e("teşekkürler", "🙏"),
                              e("tamam", "👍"), e("ok", "👌"), e("tebrikler", "🎉"),
                              e("iyi ki doğdun", "🎂"), e("çay", "🍵"), e("kahve", "☕"),
                              e("uyku", "😴"), e("of", "😩")],
                      defaultOn: true),
        ShortcutGroup(id: "flags-world", title: "Diğer ülke bayrakları",
                      subtitle: "Kapalı: \"de\", \"ne\" gibi kodlar Türkçe kelime",
                      items: [e("de", "🇩🇪"), e("us", "🇺🇸"), e("uk", "🇬🇧"), e("fr", "🇫🇷"),
                              e("az", "🇦🇿"), e("nl", "🇳🇱"), e("it", "🇮🇹"), e("es", "🇪🇸")],
                      defaultOn: false),
    ]

    static var defaultEnabled: Set<String> { Set(groups.filter(\.defaultOn).map(\.id)) }

    /// Hazır liste — kullanıcının **düzenlediği** listenin başlangıcı.
    ///
    /// Bir dönem gruplar açılıp kapanan ayarlardı; kullanıcı "her insan farklı
    /// yazar, hazır liste gelsin, ekleyip çıkarayım" dedi. Gruplar artık
    /// yalnız bu listeyi kurmak ve eski ayarı taşımak için var.
    static var defaultList: [TextShortcut] { groups.filter(\.defaultOn).flatMap(\.items) }

    /// Tetikleyiciyle tam eşleşen çıktılar, listedeki sırayla.
    static func matches(token: String, list: [TextShortcut]) -> [TextShortcut] {
        let k = TextShortcut.normalize(token)
        guard !k.isEmpty else { return [] }
        var seen = Set<String>()
        return list.filter { $0.key == k && seen.insert($0.output).inserted }
    }

    /// İmleçten önceki son token: boşlukla ayrılmış son parça. `:D` gibi
    /// sembollü tetikleyiciler de kapsansın diye harf tamponuna değil
    /// belgeye bakılıyor. "iyi ki doğdun" gibi çok kelimeli tetikleyiciler
    /// için son üç kelime de deneniyor.
    static func candidates(before context: String) -> [String] {
        let words = context.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let last = words.last, !context.hasSuffix(" "), !context.hasSuffix("\n") else { return [] }
        var out = [String(last)]
        if words.count >= 2 { out.append(words.suffix(2).joined(separator: " ")) }
        if words.count >= 3 { out.append(words.suffix(3).joined(separator: " ")) }
        return out
    }
}

/// Öneri çubuğundan açılan uygulama.
///
/// Metin adresle taşınıyor: ChatGPT, Claude ve Perplexity sohbeti `q`
/// parametresiyle başlatıyor. Adres evrensel bağlantı; uygulama yüklüyse
/// iOS onu açıyor, değilse tarayıcı. Resim adresle gönderilemiyor — panoda
/// kalıyor ve kullanıcı yapıştırıyor. `q` almayanlarda metin de panoya
/// konuyor.
///
/// Simgeler her uygulamanın App Store'daki resmi simgesi (180 px), yalnız o
/// servisi açan düğmede kullanılıyor.
struct AIApp {
    let id: String
    let name: String
    /// `Resources/AppIcons/<icon>.png`
    let icon: String
    let base: String
    let queryParam: String?

    func url(text: String?) -> URL? {
        guard let text, !text.isEmpty, let q = queryParam,
              var c = URLComponents(string: base) else { return URL(string: base) }
        c.queryItems = [URLQueryItem(name: q, value: String(text.prefix(4000)))]
        return c.url
    }

    var takesText: Bool { queryParam != nil }

    static let all: [AIApp] = [
        AIApp(id: "chatgpt", name: "ChatGPT", icon: "chatgpt",
              base: "https://chatgpt.com/", queryParam: "q"),
        AIApp(id: "claude", name: "Claude", icon: "claude",
              base: "https://claude.ai/new", queryParam: "q"),
        AIApp(id: "gemini", name: "Gemini", icon: "gemini",
              base: "https://gemini.google.com/app", queryParam: nil),
        AIApp(id: "codex", name: "Codex", icon: "chatgpt",
              base: "https://chatgpt.com/codex", queryParam: nil),
        AIApp(id: "perplexity", name: "Perplexity", icon: "perplexity",
              base: "https://www.perplexity.ai/search", queryParam: "q"),
        AIApp(id: "deepseek", name: "DeepSeek", icon: "deepseek",
              base: "https://chat.deepseek.com/", queryParam: nil),
    ]
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let defaultIDs = ["chatgpt", "claude", "gemini"]
}
