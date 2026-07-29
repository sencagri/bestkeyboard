import Testing
@testable import KBDecoder

/// Skor ağırlıklarının kayda **tam** geçmesi — plan v8 §2.8.
///
/// Replay motoru bu sözlükten kuruluyor. Bir parametre kayda girmezse replay
/// onu varsayılanıyla kurar; ortaya çıkan fark "kod regresyonu" diye
/// raporlanır, oysa sebep kayda hiç girmemiş bir parametredir.
@Suite("Skor ağırlıkları — kayıt bütünlüğü")
struct ScoreWeightsRecordingTests {

    /// **Asıl kapı bu.** Sayısal olmayan bir alan eklenirse `dictionary` onu
    /// sessizce düşürür; sayı ancak burada tutulmazsa haber alırız.
    @Test("Her parametre sözlüğe giriyor")
    func everyFieldIsRecorded() {
        let w = ScoreWeights()
        let all = Set(Mirror(reflecting: w).children.compactMap(\.label))
        let missing = all.subtracting(w.dictionary.keys).sorted()
        #expect(missing.isEmpty,
                "sayısal olmayan alan(lar) kayda girmiyor: \(missing)")
    }

    @Test("Değerler birebir taşınıyor")
    func valuesSurvive() {
        var w = ScoreWeights()
        w.wOm = 3.25
        w.maxKeyCandidates = 9
        #expect(w.dictionary["wOm"] == 3.25)
        #expect(w.dictionary["maxKeyCandidates"] == 9)
    }

    /// Gauge sabitleri (`w_spa ≡ 1`, `offset_tr ≡ 0`) sözlükte **yok**: ayarlanabilir
    /// olmadıkları için alan da değiller. Kaydın onları taşımaması doğru —
    /// taşısaydı replay'de değiştirilebilirmiş gibi görünürlerdi.
    @Test("Gauge sabitleri sözlükte yok")
    func gaugeConstantsAbsent() {
        #expect(ScoreWeights().dictionary["wSpa"] == nil)
    }
}
