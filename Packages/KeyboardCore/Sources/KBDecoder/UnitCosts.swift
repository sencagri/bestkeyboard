import KBGeometry
import KBSpatial

/// Skor modelinin **birim maliyetleri** — sözleşme §2.3 / §5.1.
///
/// Decoder ve oracle aynı formülleri buradan alıyor. Oracle'ın bağımsız
/// doğruladığı şey **arama** (beam, dedup, budama, artımlılık), formüller
/// değil: formülleri iki kez yazmak yalnız iki kopyanın ayrışmasını davet
/// ediyordu — tekrar insertion sınıfı decoder'a eklenip oracle'a eklenmemişti
/// ve eşdeğerlik testi bunu ancak ilk ayrışmada yakaladı.
protocol UnitCosts {
    var layout: KeyLayout { get }
    var spatial: SpatialModel { get }
    var weights: ScoreWeights { get }
}

extension UnitCosts {

    /// `sub(i,j) = min(sub_direct, sub_eq)` — §2.3. Tanımsızsa `+∞`.
    ///
    /// İki seçenek **bağımsız** hesaplanır: doğrudan tuş yoksa bile `base(c)`
    /// tanımlıysa `SUB_eq` yasaldır. (Türkçe leksikonu ASCII-only bir layout'ta
    /// kullanmak tam olarak bu durumdur: `ü` tuşu yok, `u` var.)
    @inline(__always)
    func substitutionCost(_ t: TouchSample, char: Character) -> Double {
        var best = Double.infinity
        if let direct = layout.keyIndex(for: char) {
            best = spatial.negLogP(t, keyIndex: direct)          // w_spa ≡ 1
        }
        if let base = layout.asciiBaseKeyIndex(for: char) {
            best = min(best, weights.wSpaEq * spatial.negLogP(t, keyIndex: base) + weights.wEq)
        }
        return best
    }

    /// `ins(i)` — fazladan dokunma.
    ///
    /// - Parameter previous: `t_{i−1}`; ilk dokunmada yok ve sınıf daima
    ///   normal (§5.1: `t_0` yok).
    /// - Parameter lastChar: en son **emit edilen** karakter (`nil` ise henüz
    ///   yok). Tekrar sınıfı (§2 `F_ins,rep`) buna bakıyor.
    @inline(__always)
    func insertionCost(_ t: TouchSample, previous: TouchSample?,
                       lastChar: Character?) -> Double {
        let bg = weights.wInsBg * spatial.negLogPBackground(t)
        if Decoder.isRepeatInsertion(touch: t, lastChar: lastChar, layout: layout) {
            return weights.wInsRepeat + bg
        }
        guard let prev = previous else { return weights.wIns + bg }
        let dt = t.timestamp - prev.timestamp
        let dist = t.down.distance(to: prev.down)
        return ((dt < weights.tauFast && dist < weights.dNear) ? weights.wInsNear : weights.wIns) + bg
    }

    /// `om(j)` sınıfı — sıralama §5.1: önce kelime başı, sonra ikiz harf.
    @inline(__always)
    func omissionCost(atWordStart: Bool, repeatsPrevious: Bool) -> Double {
        if atWordStart { return weights.wOmInit }
        return repeatsPrevious ? weights.wOmGem : weights.wOm
    }

    /// `TR`'nin uzamsal kısmı — dokunmalar **çapraz** eşleşir (§2.2):
    /// `t_{i−1} → key(c_j)`, `t_i → key(c_{j−1})`. Toplam maliyet `w_tr` +
    /// bu terim.
    @inline(__always)
    func transpositionSpatialCost(earlier: TouchSample, later: TouchSample,
                                  firstKey: Int, secondKey: Int) -> Double {
        spatial.negLogP(earlier, keyIndex: secondKey)
            + spatial.negLogP(later, keyIndex: firstKey)
    }
}
