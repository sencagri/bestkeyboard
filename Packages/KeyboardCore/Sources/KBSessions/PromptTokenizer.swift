import Foundation
import KBGeometry

/// Hedef metnin **tek** tokenizer'ı — plan v8 §2.3.
///
/// ## Neden burada
///
/// Kural `PromptCorpus.words` içinde, `Apps/` altında yaşıyordu: yalnız boşluktan
/// bölüp **uç** noktalamayı sıyırıyordu. Üç sonucu vardı ve hiçbiri testte
/// görünmüyordu, çünkü A5 testi gerçek `PromptCorpus`u değil yerel bir kopyasını
/// `withKnownIssue` içinde sınıyordu.
///
/// 1. **İç ayırıcı hizalamayı deliyor.** `Wi-Fi şifresi` tek token (`Wi-Fi`)
///    sayılıyordu. Kullanıcı `-`'ye bastığında `insertSymbol` token'ı kapatıp
///    cursor'ı ilerletiyor; `Fi` bir sonraki hedefe bağlanıyor ve cümlenin kalanı
///    kayıyor.
/// 2. **Büyük harfli hedefin bütün örnekleri düşüyor.** `Ali` hedefinde etiket
///    Türkçe küçük harf karşılaştırmasıyla `strong` oluyor ama çıkarıcı
///    `layout.keyIndex("A") == nil` gördüğü için o token'ın **hepsini** atıyor.
/// 3. **Boş hedef `completed` üretiyor.** Manuel `---` prompt'unda tokenizer boş
///    dizi veriyor; semboller yazıldıktan sonra `cursor == expected == 0`
///    olduğundan deneme tamamlanmış sayılıyor.
///
/// ## Kural
///
/// **Maksimal layout-harf dizileri.** Bir karakter ancak layout'ta bir tuşa
/// karşılık geliyorsa harf sayılıyor; geri kalan her şey (boşluk, noktalama,
/// rakam, tire, kesme işareti) ayırıcı. `Wi-Fi → ["wi","fi"]`,
/// `Caddesi'ne → ["caddesi","ne"]`.
///
/// Layout'u ölçüt almak keyfi bir liste tutmaktan iyi: klavyede olmayan bir
/// karakteri kullanıcı **yazamaz**, dolayısıyla onu hedefin parçası saymak
/// yazılamaz bir hedef üretmek olur.
///
/// ## NFC **önce**, casing sonra
///
/// `ş` iki biçimde temsil edilebiliyor (`U+015F` ya da `s` + `U+0327`).
/// Normalize etmeden küçültmek, aynı kelimenin iki farklı token dizisi üretmesine
/// izin veriyordu; `keyIndex` de kombine biçimi tanımıyor.
///
/// Küçültme **Türkçe locale ile**: `I → ı`, `İ → i`. Varsayılan locale `I → i`
/// üretir ve `Ilgaz` hedefi `ilgaz` olur — kullanıcının basacağı tuş değil.
public struct PromptTokenizer: Sendable {

    private let layout: KeyLayout

    public init(layout: KeyLayout) { self.layout = layout }

    /// Hedef metnin gösterilecek ve kaydedilecek token dizisi.
    ///
    /// Dönen diziler **küçük harf**: kullanıcının basacağı tuşlar bunlar. Büyük
    /// harf göstermek shift'e bastırıyor, shift dokunmanın uzamsal kanıtını
    /// değiştirmiyor ama hedefin kendisi artık `keyIndex`'e çözülmüyordu.
    /// Orijinal metin `promptText`'te olduğu gibi duruyor.
    public func tokens(of text: String) -> [String] {
        let normalized = CanonicalSession
            .turkishLowercased(text.precomposedStringWithCanonicalMapping)
        var out: [String] = []
        var current = ""
        for ch in normalized {
            if layout.keyIndex(for: ch) != nil {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Hedef **yazılabilir** mi.
    ///
    /// Boş dizi bir hedef değil: yazılacak harf yoksa tamamlanma koşulu
    /// (`cursor == promptTokens.count`) daha başlamadan sağlanıyor ve deneme
    /// hiçbir şey ölçmeden `completed` oluyor.
    public func isTypable(_ text: String) -> Bool { !tokens(of: text).isEmpty }
}
