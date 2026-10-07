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

    /// Karşılaştırma ve sözlük anahtarı: NFC → Türkçe küçük harf → NFC.
    public static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased(with: locale).precomposedStringWithCanonicalMapping
    }
}
