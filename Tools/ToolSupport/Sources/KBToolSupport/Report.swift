import Foundation

// MARK: - Rapor yardımcıları
//
// Araçların ortak çıktı dili. Her araç kendi kopyasını yazınca aynı istatistik
// iki araçta iki farklı tanımla raporlanıyordu (yüzdelik bir yerde yuvarlanan
// `(n−1)·p`, diğer yerde kesilen `n·p` indeksiydi).

/// Sıralı dizinin `p` yüzdeliği — **`⌊n·p⌋` indeksi** (sona kırpılmış).
///
/// Tek tanım. Deterministik raporların hepsi (θ dağılımı, ölçek ofseti,
/// kullanıcı dağılımı) bu tanımla üretilmişti; yalnız kbbench'in gecikme
/// yüzdelikleri `round((n−1)·p)` kullanıyordu. Birleştirme yalnız onları
/// etkiliyor: büyük örneklemde en fazla bir sıra yukarı (p99'u biraz daha
/// kötümser), ve gecikme zaten koşudan koşuya değişen bir ölçüm.
///
/// Boş dizide `NaN` — ölçülemeyen değer sıfır değildir; `0` "gecikme yok"
/// gibi okunur.
public func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

/// Sağa boşlukla doldurur.
///
/// `String(format:)` genişlik belirteci `%@` ile güvenilir çalışmıyor
/// (Türkçe karakterlerde hiç dolgu yapmıyor); dolgu Swift tarafında,
/// karakter (grapheme) sayısına göre.
public func pad(_ s: String, _ n: Int) -> String {
    s + String(repeating: " ", count: max(0, n - s.count))
}

/// Sola boşlukla doldurur — sayı sütunları için.
public func lpad(_ s: String, _ n: Int) -> String {
    String(repeating: " ", count: max(0, n - s.count)) + s
}

/// Hatayı standart hataya yazar ve aracı **1** ile durdurur.
///
/// Araçlar yarım bir sonuçla devam etmemeli: sessizce atlanan bir paket ya da
/// satır, eksik bir ölçümü tam ölçüm gibi gösterir.
public func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hata: \(message)\n".utf8))
    exit(1)
}

/// Monoton saatle geçen süre.
public struct Stopwatch: Sendable {
    private let start = DispatchTime.now().uptimeNanoseconds
    public init() {}

    /// Başlangıçtan bu yana milisaniye.
    public var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
