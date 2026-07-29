import Foundation
import Testing
@testable import KBDecoder
@testable import KBSessions

/// Skor ağırlıklarının kayda **tam** geçmesi — plan v8 §2.8.
///
/// Replay motoru bu anlık görüntüden kuruluyor. Bir parametre kayda girmezse
/// replay onu varsayılanıyla kurar; ortaya çıkan fark "kod regresyonu" diye
/// raporlanır, oysa sebep kayda hiç girmemiş bir parametredir.
@Suite("Skor ağırlıkları — kayıt bütünlüğü")
struct ScoreWeightsSnapshotTests {

    /// Her alana **ayırt edici** bir değer verip gidip gelmesini bekliyoruz.
    /// Varsayılanla test etmek, düşen alanı varsayılanına eşit gördüğü için
    /// kaybı gizlerdi — turun başında fixture'da yaptığım hatanın aynısı.
    private var distinctive: ScoreWeights {
        var w = ScoreWeights()
        w.wSpaEq = 0.11; w.wEq = 0.12
        w.wOmGem = 0.13; w.wOmInit = 0.14; w.wOm = 0.15
        w.wInsNear = 0.16; w.wInsRepeat = 0.17; w.wIns = 0.18; w.wInsBg = 0.19
        w.wTr = 0.21; w.wLen = 0.22; w.wLex = 0.23
        w.wCtx = 0.24; w.wLang = 0.25; w.wSwitch = 0.26
        w.maxConsecutiveOmissions = 7
        w.maxKeyCandidates = 9
        w.candidateCostWindow = 0.27
        w.tauFast = 0.28; w.dNear = 0.29
        return w
    }

    /// **Asıl kapı bu.** Yansımayla her alanı sayıyoruz: yeni bir ağırlık
    /// eklenip anlık görüntüde unutulursa burada görünür.
    @Test("Her parametre gidip geliyor")
    func everyFieldRoundTrips() {
        let original = distinctive
        let back = CanonicalSession.EngineSnapshot.ScoringConfig
            .WeightsSnapshot(original).scoreWeights

        let a = Mirror(reflecting: original).children
        let b = Mirror(reflecting: back).children
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect("\(x.value)" == "\(y.value)",
                    "\(x.label ?? "?") kayboldu: \(x.value) → \(y.value)")
        }
    }

    /// Anlık görüntünün alan sayısı `ScoreWeights`'inkiyle aynı olmalı.
    /// Eşitsizlik, DTO'nun ya eksik ya fazla alan taşıdığını söylüyor.
    @Test("Anlık görüntü ile ağırlıklar aynı alan sayısına sahip")
    func fieldCountsMatch() {
        let w = ScoreWeights()
        let snapshot = CanonicalSession.EngineSnapshot.ScoringConfig
            .WeightsSnapshot(w)
        #expect(Mirror(reflecting: w).children.count
                == Mirror(reflecting: snapshot).children.count)
    }

    /// Gauge sabitleri (`w_spa ≡ 1`, `offset_tr ≡ 0`) ayarlanabilir olmadıkları
    /// için alan da değiller; kaydın onları taşımaması doğru — taşısaydı
    /// replay'de değiştirilebilirmiş gibi görünürlerdi.
    @Test("Gauge sabitleri anlık görüntüde yok")
    func gaugeConstantsAbsent() {
        let snapshot = CanonicalSession.EngineSnapshot.ScoringConfig
            .WeightsSnapshot(ScoreWeights())
        let labels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
        #expect(!labels.contains("wSpa"))
    }
}
