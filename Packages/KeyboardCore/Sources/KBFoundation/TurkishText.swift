import Foundation

/// Türkçe metin kuralları — **tek yerde**. `i/I` ve `ı/İ` ayrımı locale'e bağlı;
/// locale'siz çevirmek `İ`'yi iki skalere (`i` + birleşen nokta) açar.
///
/// Öğrenme (kişisel sözlük, yazma geçmişi), bağlam (bigram) ve oturum kaydı
/// aynı anahtarı üretmek zorunda: biri farklı normalleştirirse aynı kelime iki
/// ayrı kayıt olur ya da bağlam paketteki anahtarla eşleşmez.
public enum TurkishText {
    public static let locale = Locale(identifier: "tr")

    /// Türkçe küçük harf (normalleştirme yok).
    public static func lowercased(_ s: String) -> String { s.lowercased(with: locale) }

    /// Türkçe büyük harf: `i → İ`, `ı → I`.
    ///
    /// Swift'in locale'siz `uppercased()`'i `i`'yi `I` yapar; Türkçe Q
    /// layout'unda bu iki ayrı harfi birbirine karıştırır.
    ///
    /// **Bilinen sınır:** kullanıcı İngilizce yazarken `i` tuşuna basıp shift
    /// yaparsa `İ` çıkar. Layout Türkçe olduğu için Türkçe kural uygulanıyor;
    /// gerçek çözüm §5b'nin dil-duyarlı casing'i, o da kelimenin dili
    /// çözüldükten SONRA uygulanabilir (Faz 5). Fiziksel Türkçe klavyelerin
    /// davranışı da budur.
    public static func uppercased(_ s: String) -> String { s.uppercased(with: locale) }

    /// Tek karakterin büyük hâli — shift'li harf girişi. `ß → SS` gibi
    /// açılımlar yüzünden sonuç bir `String`.
    public static func uppercased(_ ch: Character) -> String { uppercased(String(ch)) }

    /// Karşılaştırma ve sözlük anahtarı: NFC → Türkçe küçük harf → NFC.
    public static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased(with: locale).precomposedStringWithCanonicalMapping
    }

    /// Büyük/küçük harf dışında aynı mı — Türkçe kuralla.
    ///
    /// Locale'siz karşılaştırma `İstanbul` ile `istanbul`'u **farklı** sayar
    /// (`İ` iki skalere açılır); kayıt etiketi, doğrulayıcı ve casing olgusu
    /// aynı soruyu aynı kuralla sormalı.
    public static func equalIgnoringCase(_ a: String, _ b: String) -> Bool {
        lowercased(a) == lowercased(b)
    }

    // MARK: - Büyük harf biçimi

    /// Kullanıcının yazdığı **büyük harf biçimi**.
    ///
    /// Üç biçim ayırt ediliyor: tamamı büyük (caps-lock), yalnız ilk harf
    /// büyük, hiçbiri. Ayrı bir durum tutmaya gerek yok — biçim görünen
    /// yüzeyden çıkarılıyor.
    public enum Casing: Sendable, Equatable {
        case none, capitalized, allCaps
    }

    /// `shown`'un biçimi. Tamamı büyük sayılmak için **en az iki harf** gerekir:
    /// tek büyük harf caps-lock'u ilk harf büyüklüğünden ayırt etmez.
    public static func casing(of shown: String) -> Casing {
        if shown.count > 1, shown == uppercased(shown), shown != lowercased(shown) {
            return .allCaps
        }
        if let f = shown.first, isUppercaseLetter(f) { return .capitalized }
        return .none
    }

    /// Biçimi adaya taşır — `Kslem` düzeltilirken `Kalem` olur, `kalem` değil.
    public static func applying(_ casing: Casing, to candidate: String) -> String {
        guard let head = candidate.first else { return candidate }
        switch casing {
        case .none:        return candidate
        case .allCaps:     return uppercased(candidate)
        case .capitalized: return uppercased(head) + candidate.dropFirst()
        }
    }

    /// Harf **ve** büyük — rakam ve noktalama iki çeviride de aynı kalır.
    private static func isUppercaseLetter(_ ch: Character) -> Bool {
        let s = String(ch)
        return s == uppercased(s) && s != lowercased(s)
    }
}
