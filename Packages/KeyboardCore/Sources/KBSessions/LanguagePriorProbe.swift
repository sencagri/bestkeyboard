import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBRuntime
import KBSpatial

/// Dil öncelinin düzeltme kararını **ne kadar çevirdiği** — offline ölçüm.
///
/// ## Sorulan soru
///
/// Kullanıcının gözlemi: *"bazen boşluğa bastığım hâlde düzeltmediği kelimeler
/// var, sanırım önceki kelimelerden biri yanlış yazılırsa böyle oluyor."*
///
/// Mekanizma kodda var: her commit'te `remember(language:)` çalışıyor ve o
/// token'ın dili **sonraki** token'ın dil önceline yazılıyor. Yanlış yazılan bir
/// kelime İngilizce puanlanırsa sonraki kelimenin Türkçe adayları pahalılaşıyor,
/// `Δ = maliyet(literal) − en_iyi.maliyet` küçülüyor ve `Δ > θ` kapısı
/// geçilemiyor — düzeltme **sessizce** iptal oluyor.
///
/// ## Neden yeni veri gerekmiyor
///
/// Dokunmalar zaten kayıtta. Dil önceli bir **model parametresi**: aynı
/// dokunmaları iki farklı öncelle yeniden decode etmek, mekanizmanın etkisini
/// başka hiçbir şey değişmeden ölçüyor. Yeni oturum toplamak, ölçülecek şeyi
/// kullanıcının o gün nasıl yazdığına da bağlardı.
///
/// ## Ölçüm yalnız **karar** üzerinden
///
/// Kayıttaki `Δ`/`θ` yeniden hesaplanmıyor; token'ın dokunmaları gerçek
/// koordinatöre sürülüyor ve **commit raporu** karşılaştırılıyor. Eşiği burada
/// yeniden kurmak, `InputCoordinator`'ın kararını ikinci bir yerde taklit etmek
/// olurdu ve ikisi sessizce ayrışırdı.
public enum LanguagePriorProbe {

    public struct Flip: Sendable {
        public let literal: String
        public let target: String?
        /// Türkçe öncelle commit edilen yüzey.
        public let withTurkish: String
        /// İngilizce öncelle commit edilen yüzey.
        public let withEnglish: String
        /// Türkçe öncelde düzeltme uygulandı mı.
        public let correctedTurkish: Bool
        public let correctedEnglish: Bool
    }

    public struct Report: Sendable {
        /// Değerlendirilen token sayısı.
        public var tokens = 0
        /// Kararın **değiştiği** token sayısı.
        public var flips: [Flip] = []
        /// İngilizce öncelde düzeltmenin **kaybolduğu** durumlar.
        ///
        /// Kullanıcının şikâyetinin tam karşılığı: Türkçe öncelle düzelirdi,
        /// İngilizce öncelle düzelmiyor.
        public var lostCorrections = 0
        /// Tersi: İngilizce öncelle düzeltme **başlıyor**.
        public var gainedCorrections = 0
        /// Değerlendirilemeyen token'lar, gerekçesiyle.
        public var skipped: [String: Int] = [:]

        public var flipRate: Double {
            tokens > 0 ? Double(flips.count) / Double(tokens) : 0
        }
    }

    /// - Parameter records: analiz edilmiş kayıtlar (her biri kendi layout'uyla).
    /// - Parameter makeEngine: verilen dil önceliyle motoru kuran fabrika.
    ///   Paket yükleme çağıranda: burada yapmak `KBSessions`'ı paket yoluna
    ///   bağlar ve aynı motoru ikinci kez kurmak olurdu.
    public static func run(records: [RecordingAnalysis.Record],
                           makeEngine: (KeyLayout, UInt8?) -> InputCoordinator.Engine)
        -> Report {
        var report = Report()
        for r in records {
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
                // Basılan tuşun harfi **dokunmanın kaydından**: sonda
                // kullanıcının fiilen bastığını yeniden sürüyor.
                let keys = token.atoms.compactMap { $0.touch.key?.first }
                guard let points = token.decoderSamples,
                      keys.count == points.count, !points.isEmpty else {
                    report.skipped["dokunma noktası yok", default: 0] += 1
                    continue
                }

                // **Düzeltme açık** sürülüyor: kayıt kalibrasyon koşulundaysa
                // orada bastırılmıştı, ama ölçülen şey düzeltme kararının dile
                // duyarlılığı — bastırılmış hâlde her iki kol da aynı çıkar ve
                // ölçüm hiçbir şey söylemezdi.
                let samples = Array(zip(keys, points))
                let tr = commit(samples, layout: r.layout,
                                engine: makeEngine(r.layout, 0))
                let en = commit(samples, layout: r.layout,
                                engine: makeEngine(r.layout, 1))
                report.tokens += 1
                guard tr.committed != en.committed
                        || (tr.kind == .autocorrect) != (en.kind == .autocorrect)
                else { continue }
                let target = commits[token.tokenID]?.label.targetWord
                report.flips.append(.init(
                    literal: tr.literal, target: target,
                    withTurkish: tr.committed, withEnglish: en.committed,
                    correctedTurkish: tr.kind == .autocorrect,
                    correctedEnglish: en.kind == .autocorrect))
                if tr.kind == .autocorrect, en.kind != .autocorrect {
                    report.lostCorrections += 1
                } else if en.kind == .autocorrect, tr.kind != .autocorrect {
                    report.gainedCorrections += 1
                }
            }
        }
        return report
    }

    /// Token'ın dokunmalarını **gerçek** koordinatöre sürüp commit raporunu alır.
    private static func commit(_ samples: [(Character, TouchSample)],
                               layout: KeyLayout,
                               engine: InputCoordinator.Engine)
        -> InputCoordinator.TokenCommitReport {
        var c = InputCoordinator(layout: layout)
        c.setEngine(engine)
        let buffer = TextBuffer()
        for (ch, sample) in samples {
            c.insertLetter(ch, touch: sample, into: buffer)
        }
        return c.space(into: buffer)
    }
}
