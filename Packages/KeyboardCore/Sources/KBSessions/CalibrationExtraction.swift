import Foundation
import KBGeometry
import KBLearning
import KBRuntime
import KBSpatial

/// Katlanmış kayıttan kalibrasyon örnekleri — plan v8 §2.4'ün karşılığı.
///
/// ## Neden reducer üzerinden
///
/// Örnekleri ham `actions` dizisinden çıkarmak, geri açma ve kanıt kopması
/// kurallarını **ikinci kez** uygulamak demekti. Reducer onları zaten katlıyor
/// ve düşen dokunmaları gerekçesiyle ayırıyor; buradaki iş yalnız hangi
/// token'ların uygun olduğunu seçmek.
public enum CalibrationExtraction {

    /// Kaydın **tamamının** neden dışlandığı.
    ///
    /// Boş bir `Result` döndürmek yetmiyordu: token düzeyi sayaçların hepsi de
    /// sıfır kalıyor ve rapor *"0 örnek · 0 dışlanan"* diyordu. Yani "kayıt
    /// uygun değildi" ile "kayıt uygundu ama hiç token yoktu" ayırt edilemiyor,
    /// eksik veri sessizce temiz veri gibi görünüyordu.
    public enum SessionExclusion: Equatable, Sendable, CustomStringConvertible {
        /// Hizalama `constructed` değil — sıra varsayımı olguya dayanmıyor.
        case alignmentNotConstructed(CanonicalSession.AlignmentSource)
        /// Katlama doğrulanamadı; token sınırları güvenilmez.
        case foldingUnverifiable(violations: Int, unverifiable: Int)

        public var description: String {
            switch self {
            case let .alignmentNotConstructed(s):
                return "hizalama kaynağı \(s.rawValue) (constructed değil)"
            case let .foldingUnverifiable(v, u):
                return "katlama doğrulanamadı: \(v) ihlal, \(u) bilinmeyen olgu"
            }
        }
    }

    public struct Result {
        public var samples: [CalibrationLearner.Sample] = []
        /// Kayıt bütün olarak dışlandıysa gerekçesi; `nil` = kayıt işlendi.
        public var excludedSession: SessionExclusion?
        /// Hizalama bozulduğu için dışlanan token sayısı.
        public var excludedDiverged = 0
        /// Hedefle uzunluğu tutmayan token sayısı.
        public var excludedLengthMismatch = 0
        /// Etiketi zayıf olduğu için dışlananlar.
        public var excludedWeakLabel = 0
        /// Kayıtla türetimin uyuşmadığı token sayısı.
        public var excludedTouchCountMismatch = 0
        /// **Kurtarılan** dokunmalar: kullanıcı komşu tuşa kaymış ama hedef
        /// biliniyor.
        ///
        /// Bunları saymak kalibrasyonun neyi öğrendiğini görünür kılıyor —
        /// hepsi sıfırsa çıkarıcı yalnız zaten doğru basılanları topluyordur
        /// ve sapma öğrenilemez.
        public var recoveredDriftedTouches = 0
    }

    /// - Parameter session: kanonik kayıt.
    ///
    /// ## Dışlama ölçütleri
    ///
    /// - **Hizalama `constructed` değilse hiçbir örnek yok**: `sequential`
    ///   sırayla varsayıyor, kayıt değil (§12.4).
    /// - Doğrulanamaz olgu taşıyan kayıtlar tamamen dışlanıyor: bilinmeyenden
    ///   örnek çıkarmak, bilmediğini bildiğini sanmaktır.
    /// - Politika düzeltmeyi uyguluyorsa etiket **zayıf**: kullanıcı kendi
    ///   hatasını gördüğü için dokunma dağılımı temiz değil (§12.3).
    public static func extract(_ session: CanonicalSession,
                               layout: KeyLayout,
                               state: SessionEventReducer.State? = nil) -> Result {
        var out = Result()
        guard session.alignmentSource == .constructed else {
            out.excludedSession = .alignmentNotConstructed(session.alignmentSource)
            return out
        }
        let s = state ?? SessionEventReducer.reduce(session)
        // Katlama doğrulanamadıysa token sınırları da güvenilmez.
        guard s.unverifiable.isEmpty, s.violations.isEmpty else {
            out.excludedSession = .foldingUnverifiable(
                violations: s.violations.count, unverifiable: s.unverifiable.count)
            return out
        }

        for token in s.tokens {
            if token.afterDivergence || token.invalidated {
                out.excludedDiverged += 1
                continue
            }
            guard token.touchCountAgrees else {
                out.excludedTouchCountMismatch += 1
                continue
            }
            guard let target = targetWord(for: token, in: session),
                  !target.isEmpty else {
                out.excludedWeakLabel += 1
                continue
            }
            let chars = Array(target)
            guard chars.count == token.atoms.count else {
                out.excludedLengthMismatch += 1
                continue
            }

            // **Hedef** karakterin tuşuna atanıyor, basılan tuşa değil.
            //
            // Basılan tuşa atamak sapmayı sistematik olarak kırpıyordu: komşu
            // tuşa kayan dokunma o komşunun örneği sayılıyor ve kendi tuşunun
            // sapması hiç öğrenilmiyordu. Kaymanın **kendisi** öğrenilecek şey.
            var mapped: [CalibrationLearner.Sample] = []
            var drifted = 0
            var ok = true
            for (i, atom) in token.atoms.enumerated() {
                guard let key = layout.keyIndex(for: chars[i]),
                      let x = atom.touch.decoderX ?? atom.touch.normX,
                      let y = atom.touch.decoderY ?? atom.touch.normY else {
                    ok = false
                    break
                }
                if atom.keyIndex != key { drifted += 1 }
                mapped.append(.init(point: Point(x: x, y: y), keyIndex: key,
                                    confidence: .strong))
            }
            guard ok else {
                out.excludedLengthMismatch += 1
                continue
            }
            out.recoveredDriftedTouches += drifted
            out.samples.append(contentsOf: mapped)
        }
        return out
    }

    /// Token'ın hedef kelimesi — **kayıttaki etiketten**.
    ///
    /// `promptTokens`'tan `cursorBefore` ile bakmak da mümkün ama etiket zaten
    /// §12.5 kurallarına göre kurulmuş olguyu taşıyor ve yalnız `strong`
    /// olanlar kalibrasyona giriyor.
    private static func targetWord(for token: SessionEventReducer.Token,
                                   in session: CanonicalSession) -> String? {
        for a in session.actions {
            guard let c = a.commit, c.tokenID.value == token.tokenID else { continue }
            guard c.label.confidence == .strong else { return nil }
            return c.label.targetWord
        }
        return nil
    }
}
