/// Sözlük yüzeylerinin sınırları — (I1) invariantı **tek yerde**: biçim
/// üretici (morfotaktik), biçim ağacı, karakter n-gram puanlaması, kişisel
/// sözlük ve paket üretim aracı aynı uzunluk sınırını
/// kullanmak zorunda (biri daha uzun kelime kabul ederse diğeri puanlayamaz).
public enum LexiconLimits {
    public static let maxSurfaceLength = 40
}
