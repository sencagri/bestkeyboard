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
        /// Deneme tamamlanmadı.
        ///
        /// Vazgeçilen ya da kesilen bir denemenin token'ları da "temiz"
        /// görünüyor: kullanıcı kelimeyi doğru yazıp sonra çıkmış olabilir. Ama
        /// **neden** çıktığını bilmiyoruz ve yarıda bırakılan bir deneme
        /// tamamlananlarla aynı dağılımdan gelmiyor (§12.6'nın seçim yanlılığı
        /// argümanının aynısı, ters yönde).
        case notCompleted(CanonicalSession.Status)
        /// Kayıt kalibrasyon politikasıyla alınmamış.
        ///
        /// §12.3: düzeltme uygulanıyorsa kullanıcı kendi hatasını **görüyor** ve
        /// dokunma dağılımı temiz değil. Öğrenme canlıysa motor kaydın ortasında
        /// değişmiş olabilir.
        case policyNotCalibration(String)
        /// Kayıt zaten kalibre bir modelle alınmış.
        ///
        /// O noktaların sapması modele **girmiş** durumda; onlardan yeniden
        /// sapma öğrenmek aynı düzeltmeyi iki kez uygulamak olurdu (§12.3
        /// kaydın kalibrasyonsuz alınmasını şart koşuyor).
        case calibrationAlreadyApplied
        /// Kayıt yapısal olarak tutarsız.
        ///
        /// Reducer'ın **kendi** ihlal listesi yetmiyordu: dokunma yaşam döngüsü,
        /// §2.1 etki tablosu, zaman penceresi ve tokenID tekilliği orada
        /// görünmüyor ve hepsi token sınırlarını ya da koordinatları
        /// güvenilmez yapabiliyor.
        case structurallyInvalid([String])
        /// Kaydın geometrisi çözülemedi.
        ///
        /// Tuş merkezleri kaydın anlattığı yerde değil; yedek layout'la örnek
        /// çıkarmak cihaz profiline **yanlış** bias yazardı.
        case layoutUnresolved

        public var description: String {
            switch self {
            case let .alignmentNotConstructed(s):
                return "hizalama kaynağı \(s.rawValue) (constructed değil)"
            case let .foldingUnverifiable(v, u):
                return "katlama doğrulanamadı: \(v) ihlal, \(u) bilinmeyen olgu"
            case let .notCompleted(s):
                return "deneme tamamlanmadı (\(s.rawValue))"
            case let .policyNotCalibration(d):
                return "kalibrasyon politikası değil: \(d)"
            case .calibrationAlreadyApplied:
                return "kayıt kalibre bir modelle alınmış"
            case .layoutUnresolved:
                return "kaydın geometrisi çözülemedi"
            case let .structurallyInvalid(f):
                return "yapısal bulgu (\(f.count)): "
                    + f.prefix(3).joined(separator: "; ")
            }
        }
    }

    /// Hangi token'ların hedefe **eşlenebilir** sayılacağı.
    ///
    /// §12.5 bugünkü kuralı veriyor: `literal == hedef` ise `strong`. O kural
    /// hedeften **kayan** her token'ı dışlıyor — oysa kayma tam da kalibrasyonun
    /// öğreneceği şey. Gerçek veride ölçüldü: 167 token'ın 149'u bu yüzden
    /// düştü ve 1348 dokunmadan geriye 85 örnek kaldı.
    ///
    /// İki politikayı **karşılaştırabilmek** için seçenek; üretim varsayılanı
    /// değişmiyor. §12.8: hangi kolun daha iyi olduğu held-out ölçümle
    /// belirlenir, tahminle değil.
    public enum LabelPolicy: String, Sendable, CaseIterable {
        /// §12.5 — yalnız hedefiyle birebir yazılan token.
        case strongOnly
        /// Ek olarak hedeften kayan ama **uzunluğu tutan** token.
        ///
        /// Gerekçe: `calibrationReplay` koşulunda geri bildirim gizli ve
        /// düzeltme kapalı (§12.3). Kullanıcı çıktısını göremediği için her
        /// dokunma sırasıyla hedef harfe yapılmış bir denemedir. Uzunluk
        /// eşitliği konumsal hizalamanın kendisi.
        ///
        /// **Bilinen risk:** bir harf atlanıp başka bir yere fazladan
        /// basıldıysa uzunluk tesadüfen tutar ve o token'da hizalama yanlış
        /// olur. Bu yüzden deneysel.
        case includeLengthAlignedDrift
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
    /// Kaydın kalibrasyona **uygun** olup olmadığı — tek kapı.
    ///
    /// Önce yalnız `alignmentSource` ve reducer'ın kendi ihlal listesi
    /// kontrol ediliyordu, yani kapı **fail-open**'dı: vazgeçilmiş bir deneme,
    /// düzeltmenin açık olduğu bir koşul, kalibre bir modelle alınmış bir kayıt
    /// ve dokunma yaşam döngüsü bozuk bir kayıt öğrenmeye giriyordu. Hepsi
    /// "temiz" görünüyordu çünkü hiçbiri reducer'ın baktığı yerde değil.
    public static func eligibility(_ session: CanonicalSession,
                                   state: SessionEventReducer.State,
                                   findings: [SessionValidator.Finding])
        -> SessionExclusion? {
        guard session.alignmentSource == .constructed else {
            return .alignmentNotConstructed(session.alignmentSource)
        }
        // Yalnız tamamlanan deneme öğretiyor.
        guard session.status == .completed else {
            return .notCompleted(session.status)
        }
        // Politika **uygulanan** olgudan okunuyor, `condition`'dan değil:
        // `condition` niyeti gösteriyor, motorun nasıl kurulduğunu değil.
        let policy = session.engine.policy
        switch policy.correction {
        case .known(.suppressed): break
        case .known(.applied):
            return .policyNotCalibration("düzeltme uygulanıyordu")
        case .unknown:
            return .policyNotCalibration("düzeltme durumu bilinmiyor")
        case .notApplicable:
            return .policyNotCalibration("düzeltme olgusu yok")
        }
        guard policy.learning == .frozen else {
            return .policyNotCalibration("öğrenme canlıydı")
        }
        // Kalibre bir modelle alınan kayıttan yeniden sapma öğrenmek, aynı
        // düzeltmeyi iki kez uygulamaktır.
        if let cfg = session.engine.configuration.value, cfg.calibration.applied {
            return .calibrationAlreadyApplied
        }
        guard findings.isEmpty else {
            return .structurallyInvalid(findings.map(\.description))
        }
        // Katlama doğrulanamadıysa token sınırları da güvenilmez.
        guard state.unverifiable.isEmpty, state.violations.isEmpty else {
            return .foldingUnverifiable(violations: state.violations.count,
                                        unverifiable: state.unverifiable.count)
        }
        return nil
    }

    /// - Parameter findings: `SessionValidator` bulguları. Verilmezse burada
    ///   hesaplanıyor — çağıran zaten hesapladıysa ikinci kez koşturmak boşa iş,
    ///   ama **atlamak** kapıyı açık bırakmak olurdu.
    /// - Parameter policy: **üretim varsayılanı `.strongOnly`.** Diğer kol
    ///   yalnız held-out karşılaştırması için.
    public static func extract(_ session: CanonicalSession,
                               layout: KeyLayout,
                               state: SessionEventReducer.State? = nil,
                               findings: [SessionValidator.Finding]? = nil,
                               policy: LabelPolicy = .strongOnly)
        -> Result {
        var out = Result()
        let s = state ?? SessionEventReducer.reduce(session)
        let f = findings ?? SessionValidator.validate(session, state: s)
        if let why = eligibility(session, state: s, findings: f) {
            out.excludedSession = why
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
            guard let target = targetWord(for: token, in: session,
                                          policy: policy),
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
                                   in session: CanonicalSession,
                                   policy: LabelPolicy) -> String? {
        for a in session.actions {
            guard let c = a.commit, c.tokenID.value == token.tokenID else { continue }
            switch policy {
            case .strongOnly:
                guard c.label.confidence == .strong else { return nil }
            case .includeLengthAlignedDrift:
                // Hedef **biliniyor olmak** zorunda; zayıf etiket "hedefi
                // bilmiyoruz" değil "yüzey hedeften farklı" demek. Uzunluk
                // kontrolü çağıranda, `chars.count == atoms.count`.
                guard c.label.source == .protocol else { return nil }
            }
            return c.label.targetWord
        }
        return nil
    }
}
