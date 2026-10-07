/// Aralığa kırpma ve kademeye oturtma — kullanıcı ayarlarının (tuş ölçüleri,
/// tekrar zamanlaması) **tek** kanonikleştirme kuralı.
///
/// Geometri ve zamanlama ayarları aynı adımları ayrı ayrı yazıyordu; biri
/// sonlu olmayan değeri reddetmeyi unutursa `NaN` kırpmadan da yuvarlamadan da
/// sağ çıkıyor (`Swift.max(NaN, a)` `NaN` döner) ve bir sonraki tüketicide
/// trap ediyor.
public extension Comparable {
    @inlinable
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

public extension Double {
    /// Kademeye oturt, aralığa kırp, **sonlu olmayanı reddet**.
    ///
    /// Kademeye oturtmak kimliği kayıpsız tutuyor: kaydedilen değer
    /// `0.0850000001` değil `0.085` — gösterilen ile saklanan aynı.
    ///
    /// - Parameter fallback: değer sonlu değilse (bozuk bir kayıt, başka bir
    ///   sürüm) dönen değer.
    func canonicalized(step: Double, within range: ClosedRange<Double>,
                       fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return ((self / step).rounded() * step).clamped(to: range)
    }
}
