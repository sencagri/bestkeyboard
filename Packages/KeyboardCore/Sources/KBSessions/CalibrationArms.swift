import Foundation
import KBDecoder
import KBGeometry
import KBLearning
import KBRuntime
import KBSpatial

/// Kalibrasyon kollarının **held-out** karşılaştırması — sözleşme §12.8.
///
/// ## Neden ölçüm gerekiyor
///
/// §12.5 bugün yalnız hedefiyle birebir yazılan token'ı `strong` sayıyor.
/// Gerçek veride ölçüldü: 167 token'ın 149'u bu yüzden düştü ve 1348 dokunmadan
/// geriye 85 örnek kaldı. Düşenler rastgele değil — hepsi komşu tuş kaymaları,
/// yani kalibrasyonun öğrenmesi gereken şeyin ta kendisi.
///
/// İki kolun hangisinin daha iyi olduğu **tahminle** belirlenemez: kayan
/// token'ları almak daha çok veri veriyor ama yanlış hizalanmış örnek de
/// getirebiliyor. §12.8: *"tek oturumda öğrenip aynı oturumda ölçmek kendini
/// doğrulamadır"*.
///
/// ## Deneyin şekli
///
/// - **Eğitim**: yalnız `split == train` kayıtları. Kol başına ayrı öğrenici.
/// - **Değerlendirme**: `split == test` kayıtlarının token'ları. Her token'ın
///   dokunmaları o kolun kalibrasyonuyla kurulmuş decoder'a veriliyor ve
///   **top-1** çıktısı hedef kelimeyle karşılaştırılıyor.
///
/// Değerlendirme ölçütü kasten "kalibrasyon örneği" değil **doğruluk**: örnek
/// sayısını ölçmek kolu kendi tanımıyla ödüllendirirdi. Kullanıcının kaydırdığı
/// dokunmalardan hedef kelimeyi geri kurabilmek zaten kalibrasyonun vaadi.
///
/// Prompt'lar tekrarsız ve split içerikten bağımsız (`i % 5`), dolayısıyla
/// prompt-ayrık split aynı zamanda **oturum-ayrık**.
public enum CalibrationArms {

    public struct Arm: Sendable {
        public let name: String
        /// Değerlendirme kümesinde hedefi birebir üreten token sayısı.
        public var correct = 0
        /// Değerlendirilen token sayısı.
        public var evaluated = 0
        /// Eğitimde kullanılan örnek sayısı.
        public var trainingSamples = 0
        /// Eğitimde hedef tuşa **kurtarılan** kayan dokunma.
        public var recoveredDrift = 0
        /// Kendi katmanı açılan tuş sayısı.
        public var keysWithOwnLayer = 0

        public var accuracy: Double {
            evaluated > 0 ? Double(correct) / Double(evaluated) : 0
        }
    }

    public struct Report: Sendable {
        public var arms: [Arm] = []
        /// Eğitim kümesindeki kayıt sayısı.
        public var trainRecords = 0
        /// Değerlendirme kümesindeki kayıt sayısı.
        public var testRecords = 0
        /// Değerlendirilemeyen token'lar ve gerekçeleri.
        ///
        /// Sessizce atlamak, dar bir değerlendirme kümesini geniş gibi
        /// gösterirdi.
        public var skipped: [String: Int] = [:]
    }

    /// Bir kaydın hangi kümeye ait olduğu.
    ///
    /// `split` **kayıttan** okunuyor, burada yeniden atanmıyor: §12.8 bölmenin
    /// oturum sonucuna bakılarak atanmasını yasaklıyor ve prompt'un split'i
    /// veri görülmeden sabit.
    public static func isTrain(_ s: CanonicalSession) -> Bool { s.split == "train" }
    public static func isTest(_ s: CanonicalSession) -> Bool { s.split == "test" }

    /// - Parameter records: analiz edilmiş kayıtlar (her biri kendi layout'uyla).
    /// - Parameter makeDecoder: verilen uzamsal modelle decoder kuran fabrika.
    ///   Paket yükleme çağıranda: burada yapmak `KBSessions`'ı paket yoluna
    ///   bağlardı ve aynı motoru ikinci kez kurmak olurdu.
    public static func compare(
        records: [RecordingAnalysis.Record],
        makeDecoder: (KeyLayout, SpatialModel) -> Decoder) -> Report {

        var report = Report()
        let train = records.filter { isTrain($0.session) }
        let test = records.filter { isTest($0.session) }
        report.trainRecords = train.count
        report.testRecords = test.count

        // Değerlendirme kümesi **bir kez** kuruluyor: kollar aynı token'lar
        // üzerinde karşılaştırılmazsa fark koldan değil kümeden gelirdi.
        var cases: [(layout: KeyLayout, target: String, touches: [TouchSample])] = []
        for r in test {
            guard r.layoutResolved else {
                report.skipped["geometri çözülemedi", default: 0] += 1
                continue
            }
            let commits = r.session.commitsByToken
            for token in r.state.tokens {
                guard token.trust == .trusted else {
                    report.skipped["token güvenilmez", default: 0] += 1
                    continue
                }
                guard let commit = commits[token.tokenID],
                      commit.label.source == .protocol,
                      let target = commit.label.targetWord, !target.isEmpty else {
                    report.skipped["hedef bilinmiyor", default: 0] += 1
                    continue
                }
                guard let samples = token.decoderSamples, !samples.isEmpty else {
                    report.skipped["dokunma noktası yok", default: 0] += 1
                    continue
                }
                cases.append((r.layout, target, samples))
            }
        }

        // Kalsız kol: kalibrasyonun **bir şey kattığını** göstermenin tek yolu.
        report.arms.append(evaluate(name: "kalsız", cases: cases,
                                    learner: nil, makeDecoder: makeDecoder))

        for policy in CalibrationExtraction.LabelPolicy.allCases {
            var learner = CalibrationLearner()
            var recovered = 0, count = 0
            // **Tek geometri**: farklı tuş ölçülerindeki kayıtları tek
            // öğrenicide birleştirmek, bir layout'un gerçek merkez farkını
            // diğerinde kullanıcı sapması sanmak olurdu. Değerlendirme
            // kümesinin geometrisi ölçüt.
            let evalLayoutID = cases.first?.layout.id
            for r in train {
                guard r.layoutResolved, r.layout.id == evalLayoutID else {
                    continue
                }
                let ext = CalibrationExtraction.extract(
                    r.session, layout: r.layout, state: r.state,
                    findings: r.findings, policy: policy)
                for s in ext.samples { learner.append(s) }
                recovered += ext.recoveredDriftedTouches
                count += ext.samples.count
            }
            var arm = evaluate(name: policy.rawValue, cases: cases,
                               learner: learner, makeDecoder: makeDecoder)
            arm.trainingSamples = count
            arm.recoveredDrift = recovered
            if let layout = cases.first?.layout {
                arm.keysWithOwnLayer =
                    learner.hierarchicalEstimate(layout: layout).keysWithOwnLayer
            }
            report.arms.append(arm)
        }
        return report
    }

    private static func evaluate(
        name: String,
        cases: [(layout: KeyLayout, target: String, touches: [TouchSample])],
        learner: CalibrationLearner?,
        makeDecoder: (KeyLayout, SpatialModel) -> Decoder) -> Arm {

        var arm = Arm(name: name)
        // Decoder layout başına **bir kez** kuruluyor: her token için yeniden
        // kurmak ölçümü yavaşlatır ve hiçbir şey değiştirmez.
        var byLayout: [String: Decoder] = [:]
        for c in cases {
            let decoder: Decoder
            if let d = byLayout[c.layout.id] {
                decoder = d
            } else {
                var spatial = SpatialModel(layout: c.layout)
                // Hiyerarşik kol uygulanıyor: §8.6'nın ince katmanı bu.
                learner?.applyHierarchical(to: &spatial)
                let d = makeDecoder(c.layout, spatial)
                byLayout[c.layout.id] = d
                decoder = d
            }
            var inc = IncrementalDecoder(decoder: decoder)
            for t in c.touches { inc.append(t) }
            arm.evaluated += 1
            if inc.results(topK: 1).first?.word == c.target { arm.correct += 1 }
        }
        return arm
    }
}
