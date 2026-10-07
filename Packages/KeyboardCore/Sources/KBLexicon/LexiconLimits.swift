/// Sözlük yüzeylerinin sınırları — (I1) invariantı **tek yerde**: biçim
/// ağacı, karakter n-gram puanlaması ve kişisel sözlük aynı uzunluk sınırını
/// kullanmak zorunda (biri daha uzun kelime kabul ederse diğeri puanlayamaz).
public enum LexiconLimits {
    public static let maxSurfaceLength = 40
}
