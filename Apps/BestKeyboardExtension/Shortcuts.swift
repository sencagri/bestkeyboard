import Foundation

/// Kısayol: bir şey yazınca öneri çubuğunda çıkan hazır çıktı.
///
/// **Hiçbir zaman kendiliğinden uygulanmıyor** — yalnız öneri; dokununca
/// tetikleyici silinip çıktı yazılıyor. Gerekçe "de" gibi iki harfli
/// tetikleyiciler: Türkçede hem ülke kodu hem sık kelime ve kendiliğinden
/// değiştirmek yazılanı bozardı.
struct TextShortcut: Codable, Hashable {
    enum Kind: String, Codable { case emoji, text, gif, sticker }
    var trigger: String
    /// Emoji/metin: yazılacak şey. GIF/çıkartma: Stüdyo öğesinin kimliği
    /// (`MediaStore.Item.id`) — klavye resmi belgeye koyamıyor, panoya koyuyor.
    var output: String
    var kind: Kind = .emoji

    var isMedia: Bool { kind == .gif || kind == .sticker }

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

// MARK: - Yapay zeka tuşları

/// Kullanıcının tanımladığı bir yapay zeka eylemi: "Çevir", "Resim üret"…
///
/// İstem bir şablon: `{metin}` seçili metin (yoksa imleçten önceki cümle),
/// `{pano}` panodaki metin. Şablonda `{metin}` yoksa metin istemin **altına**
/// ekleniyor — kullanıcının yazdığı en sade istem ("İngilizceye çevir") de
/// doğru çalışsın.
struct AIAction: Codable, Hashable, Identifiable {
    /// `reminder` / `event` / `contact`: mesajdan hatırlatıcı, Takvim etkinliği
    /// ya da kişi kartı çıkarır (tasarım 26, 28, 29). İstemleri yer tutuculu şablon.
    enum Kind: String, Codable, CaseIterable {
        case text, image, reminder, event, contact

        var title: String {
            switch self {
            case .text: return "Metin"
            case .image: return "Resim"
            case .reminder: return "Hatırlatıcı"
            case .event: return "Takvim"
            case .contact: return "Kişi"
            }
        }
        /// Yanıtı yapılandırılmış (JSON) olan, uygulamaya bir şey ekleyen türler.
        var isStructured: Bool { self == .reminder || self == .event || self == .contact }
        /// Yapılandırılmış türlerin varsayılan istemi.
        var defaultTemplate: String {
            switch self {
            case .reminder: return AIService.reminderTemplateDefault
            case .event: return AIService.eventTemplateDefault
            case .contact: return AIService.contactTemplateDefault
            default: return ""
            }
        }
        /// Şablonda kullanılabilen yer tutucular.
        var placeholders: [String] {
            switch self {
            case .reminder: return ["{metin}", "{şimdi}", "{takvim}", "{listeler}"]
            case .event: return ["{metin}", "{şimdi}", "{takvim}", "{takvimler}"]
            case .contact: return ["{metin}"]
            default: return ["{metin}", "{pano}"]
            }
        }
    }
    /// Nerede çalışsın: `here` = klavyedeki kartta (servis anahtarı gerekir),
    /// `shortcut` = kullanıcının Kestirmesi (`shortcutName`), yoksa bir
    /// `AIApp` kimliği — o uygulama istemle açılıyor.
    static let here = "here"
    static let shortcut = "shortcut"

    var id: String = UUID().uuidString
    var name: String
    var icon: String
    var kind: Kind = .text
    var prompt: String
    var target: String = "chatgpt"
    /// Kestirmeler uygulamasındaki ad (`target == shortcut`).
    var shortcutName: String? = nil

    /// Gönderilecek tam metin.
    func render(text: String, clipboard: String?) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = prompt.replacingOccurrences(of: "{pano}", with: clipboard ?? "")
        if p.contains("{metin}") { return p.replacingOccurrences(of: "{metin}", with: t) }
        p = p.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? p : p + "\n\n" + t
    }

    static let defaults: [AIAction] = [
        AIAction(id: "cevir", name: "Çevir", icon: "globe",
                 prompt: "Şu metni İngilizceye çevir; Türkçe değilse Türkçeye çevir. Yalnız çeviriyi yaz:", target: here),
        AIAction(id: "duzelt", name: "Düzelt", icon: "pencil",
                 prompt: "Yazım ve dil bilgisi hatalarını düzelt, anlamı ve üslubu koru. Yalnız düzeltilmiş metni yaz:", target: here),
        AIAction(id: "resmi", name: "Resmîleştir", icon: "briefcase",
                 prompt: "Şu mesajı kibar ve resmî bir dille yeniden yaz. Mesaj olarak kalsın: konu satırı, hitap ya da imza ekleme, uzunluğu yakın tut. Yalnız yeni metni yaz:", target: here),
        AIAction(id: "kibar", name: "Kibarlaştır", icon: "face.smiling",
                 prompt: "Şu metni anlamını koruyarak kibar ve sıcak bir dille yeniden yaz. Yalnız yeni metni yaz:", target: here),
        AIAction(id: "kisalt", name: "Kısalt", icon: "text.alignleft",
                 prompt: "Şu metni anlamını koruyarak kısalt. Yalnız kısa hâlini yaz:", target: here),
        AIAction(id: "cevap", name: "Cevap öner", icon: "bubble.left",
                 prompt: "Bana gelen şu mesaja tek, kısa ve doğal bir Türkçe cevap yaz:\n\n{metin}", target: here),
        AIAction(id: "hatirlatici", name: "Hatırlatıcı", icon: "checklist", kind: .reminder,
                 prompt: AIService.reminderTemplateDefault, target: here),
        AIAction(id: "takvim", name: "Takvim", icon: "calendar", kind: .event,
                 prompt: AIService.eventTemplateDefault, target: here),
        AIAction(id: "kisi", name: "Kişi", icon: "person.crop.circle", kind: .contact,
                 prompt: AIService.contactTemplateDefault, target: here),
        AIAction(id: "resim", name: "Resim üret", icon: "photo", kind: .image,
                 prompt: "Şunun resmini çiz:", target: "chatgpt"),
    ]

    /// Kullanıcının değiştirmediği (eski varsayılanla aynı) istemleri bugünkü varsayılana çevirir.
    /// Metin tuşlarının eski varsayılan istemleri (kimliğe göre).
    static let legacyTextPrompts: [String: [String]] = [
        "resmi": ["Şu metni kibar ve resmî bir dille yeniden yaz. Yalnız yeni metni yaz:"],
    ]

    /// Yanlışlıkla varsayılan yapılıp sonra geri alınan tuşlar: kullanıcının
    /// listesinde hâlâ el değmemiş hâliyle duruyorsa siliniyor.
    static let retiredDefaults: [String: String] = [
        "arapca": "Şu metni Arapçaya çevir. Yalnız çeviriyi yaz:",
    ]

    static func upgradingTemplates(_ list: [AIAction]) -> [AIAction] {
        list.filter { a in
            retiredDefaults[a.id].map { $0 != a.prompt.trimmingCharacters(in: .whitespacesAndNewlines) } ?? true
        }.map { a in
            var a = a
            let p = a.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.kind == .text, legacyTextPrompts[a.id]?.contains(p) == true,
               let current = defaults.first(where: { $0.id == a.id }) {
                a.prompt = current.prompt
            }
            if a.kind.isStructured,
               (AIService.legacyTemplates[a.kind] ?? []).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == p }) {
                a.prompt = a.kind.defaultTemplate
            }
            return a
        }
    }

    /// Düzenleyicide seçilebilen simgeler (SF Symbols).
    static let icons = ["globe", "pencil", "briefcase", "text.alignleft", "bubble.left", "photo",
                        "sparkles", "wand.and.stars", "envelope", "face.smiling", "lightbulb", "list.bullet",
                        "checklist", "calendar", "person.crop.circle"]

    /// Kartta mı çalışacak: "Klavyede" seçili **ve** servis bağlı. Bağlı
    /// değilse ChatGPT'ye düşüyor (tasarım 20).
    var runsHere: Bool { target == Self.here && AIService.isConnected }
    /// Uygulamada açılacaksa hangisi.
    var app: AIApp? {
        target == Self.shortcut ? nil : AIApp.byID[target == Self.here ? "chatgpt" : target]
    }

    /// Kestirmeyi metinle çalıştıran adres. Bitince sonuç uygulamaya geliyor
    /// (`bestkeyboard://kestirme-sonuc?result=…`) ve panoya konuyor.
    func shortcutURL(text: String) -> URL? {
        guard target == Self.shortcut, let name = shortcutName, !name.isEmpty,
              var c = URLComponents(string: "shortcuts://x-callback-url/run-shortcut") else { return nil }
        c.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: String(text.prefix(4000))),
            URLQueryItem(name: "x-success", value: DeepLink.url(.shortcutResult)?.absoluteString),
            URLQueryItem(name: "x-error", value: DeepLink.url(.shortcutResult, [URLQueryItem(name: "hata", value: "1")])?.absoluteString),
        ]
        return c.url
    }
}

