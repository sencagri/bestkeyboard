import CryptoKit
import Foundation
import KBDecoder
import KBLearning
import KBLexicon

/// Kabul edilmiş kişisel kelimelerden bir decoder kaynağı üretir (§8.7).
///
/// Kişisel sözlük çalışma anında değişiyor, paketler değişmiyor: bu yüzden trie
/// **bellekte** kuruluyor. `FormTrieBuilder` zaten saf Swift ve maliyeti kelime
/// sayısıyla doğrusal; 512 kelimelik tavanda ölçülemeyecek kadar küçük.
public enum PersonalLexiconSource {

    /// Kurulan kaynak ve **kimliği**.
    ///
    /// Kimlik kayda giriyor (§12.7): kişisel kaynak decoder'ın leksikon
    /// kaynaklarından biri ve onu yazmamak, kaydın kendi motorunu eksik
    /// anlatması olurdu. Diskte bir dosya karşılığı yok, o yüzden özet
    /// **kurulan trie'nin baytları** üzerinden — aynı kelime kümesi aynı
    /// baytları üretiyor (`FormTrieBuilder` sıralı yazıyor), dolayısıyla özet
    /// kararlı ve karşılaştırılabilir.
    public struct Built {
        public let source: LexiconSet.Source
        /// Süzgeçten geçip trie'ye **fiilen** giren yüzeyler.
        public let words: [String]
        public let byteCount: Int
        public let sha256: String
    }

    /// - Parameter base: paket kaynaklarından kurulmuş leksikon. Yüzeyin zaten
    ///   bilinip bilinmediği **buna** sorulur.
    /// - Parameter lexCost: kişisel yüzeyin ham `F_lex`'i. Üretimde daima
    ///   `PersonalLexicon.lexCost`; parametre olmasının tek sebebi `kbbench
    ///   --personal`'ın çıpayı **tarayabilmesi** (§8.7 ağırlık taraması).
    /// - Returns: kabul edilecek yüzey kalmadıysa ya da trie kurulamadıysa `nil`.
    public static func build(words: [String], base: LexiconSet,
                             lexCost: Double = PersonalLexicon.lexCost) -> Built? {
        // §7 **tek sahiplik**: paket (form listesi ∪ morfoloji) yüzeyi zaten
        // kabul ediyorsa kişisel kopya oluşturulmaz. Oluşsaydı aynı yüzey iki
        // kaynaktan iki farklı maliyet alır ve decoder ucuz olanı seçerdi —
        // argo katmanını ayrı kaynak olarak yüklerken bir kez yapılan hata.
        //
        // Filtre **her kurulumda** yeniden koşuyor: paket güncellenip kelimeyi
        // içerir hâle geldiğinde kişisel kopya kendiliğinden düşsün.
        let fresh = words.filter { !base.containsSurface($0) }
        guard !fresh.isEmpty else { return nil }

        let entries = fresh.map { FormTrieBuilder.Entry(word: $0, lexCost: lexCost) }
        // Kurulamayan bir kişisel sözlük klavyeyi durdurmaz: kaynak düşer,
        // kullanıcı yalnız korumayı kaybeder.
        guard let built = try? FormTrieBuilder().build(
                entries: entries, maxSurfaceLen: PersonalLexicon.maxLength),
              let trie = try? FormTrie(bytes: built.bytes)
        else { return nil }

        // Dil: **referans dil** — `LiteralChannel.oovLanguage` ile aynı.
        //
        // Sözlük dışı bir token'ın dili tanımı gereği gözlenmiyor (kanalın
        // kendi notu). Kabulden önce yüzey referans dilde puanlanıyordu;
        // kabulden sonra başka bir dile atamak, `Δ`'nın iki tarafını farklı
        // dil terimleriyle hesaplamak olurdu — kabul, dil kararını sessizce
        // çevirmemeli.
        let digest = SHA256.hash(data: Data(built.bytes))
            .map { String(format: "%02x", $0) }.joined()
        return Built(source: .personal(trie, language: LiteralChannel.oovLanguage),
                     words: fresh, byteCount: built.bytes.count, sha256: digest)
    }

    /// Yalnız kaynağı isteyen çağıranlar için kısayol.
    public static func make(words: [String], base: LexiconSet,
                            lexCost: Double = PersonalLexicon.lexCost)
        -> LexiconSet.Source? {
        build(words: words, base: base, lexCost: lexCost)?.source
    }
}
