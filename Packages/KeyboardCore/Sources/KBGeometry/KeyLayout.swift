import Foundation

/// Normalize koordinat: klavye tuş alanının [0,1]×[0,1] uzayı.
/// Cihaz ve yönelim bağımsız — geometri imzası değişince ölçek değil, layout değişir.
public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Key: Sendable {
    /// Tuşun ürettiği birincil karakter (küçük harf).
    public let char: Character
    public let center: Point
    public let width: Double
    public let height: Double

    public init(char: Character, center: Point, width: Double, height: Double) {
        self.char = char
        self.center = center
        self.width = width
        self.height = height
    }
}

/// Layout **veridir**, kod değil. Çekirdekte Türkçeye özgü hiçbir karar yoktur;
/// bu tip yalnız dil paketinden gelen tuş geometrisini taşır.
public struct KeyLayout: Sendable {
    public let id: String
    public let keys: [Key]

    /// Karakter → tuş indeksi. Aynı karakteri üreten tek tuş varsayımı.
    public let indexByChar: [Character: Int]

    /// Eşdeğerlik haritası: `base(c)` — diyakritik formun ASCII tabanı.
    /// Skor sözleşmesi §2.3. Yalnız bu yönde tanımlıdır.
    public let asciiBase: [Character: Character]

    public init(id: String, keys: [Key], asciiBase: [Character: Character]) {
        self.id = id
        self.keys = keys
        self.asciiBase = asciiBase
        var idx = [Character: Int]()
        for (i, k) in keys.enumerated() { idx[k.char] = i }
        self.indexByChar = idx
    }

    public func keyIndex(for char: Character) -> Int? { indexByChar[char] }

    /// `base(c)` uygulanmış tuş indeksi — eşdeğerlik ikamesi için (§2.3).
    /// Taban tanımlı değilse `nil`; o durumda `SUB_eq` yasal değildir.
    public func asciiBaseKeyIndex(for char: Character) -> Int? {
        guard let base = asciiBase[char] else { return nil }
        return indexByChar[base]
    }

    /// Verilen noktaya en yakın merkezli tuş — literal (posterior argmax'ın
    /// uzamsal bileşeni) ve geliştirme aracı için.
    public func nearestKey(to p: Point) -> Int? {
        var best = -1
        var bestD = Double.infinity
        for (i, k) in keys.enumerated() {
            let dx = p.x - k.center.x, dy = p.y - k.center.y
            let d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = i }
        }
        return best >= 0 ? best : nil
    }
}
