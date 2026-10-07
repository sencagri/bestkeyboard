import KBGeometry

public extension KeyLayout {
    /// Bir yüzeyin **tuş merkezlerine** konmuş dokunma dizisi.
    ///
    /// Gerçek gözlem değil: koordinatörün türetilmiş kanıtı (§8.4) ve
    /// araçların gürültüsüz sondası. Aynı döngü koordinatörde ve iki araçta
    /// ayrı ayrı yazılıyordu. Layout'ta olmayan bir harf varsa `nil` — yarım
    /// bir dizi başka bir kelimenin kanıtı olurdu.
    ///
    /// - Parameter interval: ardışık dokunmalar arası süre (sn); ilk dokunma 0'da.
    func centerTouches(for word: String, interval: Double = 0) -> [TouchSample]? {
        var out: [TouchSample] = []
        out.reserveCapacity(word.count)
        for ch in word {
            guard let k = keyIndex(for: ch) else { return nil }
            out.append(TouchSample(down: keys[k].center,
                                   timestamp: Double(out.count) * interval))
        }
        return out
    }
}
