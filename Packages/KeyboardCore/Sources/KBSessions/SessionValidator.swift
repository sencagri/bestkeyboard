import Foundation
import KBGeometry
import KBRuntime

/// Kaydın **kendi içinde tutarlı** olup olmadığını sınar — plan v8 §2.5.
///
/// ## Neden ayrı bir katman
///
/// Reducer katlar; katlarken gördüğü tutarsızlıkları `violations`'a yazar. Ama
/// katlamanın hiç bakmadığı şeyler var: `actionID` dizisi kesintisiz mi, zaman
/// monoton mu, payload kind'la uyuyor mu, sayısal alanlar sonlu mu. Bunlar
/// kaydın **yapısal** doğruluğu ve bozuklarsa katlamanın sonucu zaten anlamsız.
///
/// ## Neden sapma meşrulaştırmıyor
///
/// `diverged` hizalamanın bozulduğunu söylüyor — hedef kelimeyle token'ın
/// eşleşmediğini. Token'ın **kendi** dokunma sayısının tutmaması ayrı bir
/// şey ve sapma onu açıklamıyor: kayıtta delik var demektir.
public enum SessionValidator {

    public struct Finding: Equatable, Sendable, CustomStringConvertible {
        public enum Kind: String, Equatable, Sendable {
            /// `actionID` sıfırdan başlayan kesintisiz dizi değil.
            case actionIDNotContiguous
            /// Zaman geri gitti.
            case timeNotMonotonic
            /// Olay yükü kip ile uyuşmuyor.
            case payloadKindMismatch
            /// `letter` tek terminal `committed` dokunmaya çözülmüyor.
            case letterTouchUnresolved
            /// Sayısal alan sonsuz ya da NaN.
            case nonFiniteNumber
            /// Aynı `touchID` birden çok terminal kayıt taşıyor.
            case duplicateTerminalTouch
            /// Kayıtlı sapma bayrağı türetilenle uyuşmuyor.
            case divergenceMismatch
            /// v3'ün üretmesi yasak bir kip.
            case legacyOnlyKindInNativeRecord
            /// Katlama bir tutarsızlık buldu.
            case reducerViolation
            /// Terminal olmayan durumda `endedAt` var (ya da tersi).
            case terminalStateInconsistent
            /// §2.1 tablosunda karşılığı olmayan operasyon×etki bileşimi.
            case effectNotInTable
            /// Token kimliği tekil ve monoton değil.
            case tokenIDNotMonotonic
            /// Sınır olayı commit taşımıyor.
            case boundaryWithoutCommit
            /// Yerel v3 kaydında bilinmeyen olgu.
            case unknownFactInNativeRecord
            /// Dokunma yaşam döngüsü bozuk.
            case touchLifecycle
            /// Aynı dokunma birden çok harfe bağlanmış.
            case touchConsumedTwice
            /// Kaydedilen hedef dizisi tokenizer'ın ürettiğiyle uyuşmuyor.
            ///
            /// §2.3: *"gösterilen dizi == kayda yazılan dizi"*. Kural iki yerde
            /// yaşarken (UI'da bir kopya, kayıt zincirinde başka bir kural) ikisi
            /// ayrışabiliyordu ve kayıt, kullanıcının **görmediği** bir hedefe
            /// göre hizalanmış görünürdü.
            case promptTokensNotCanonical
            /// §12.5 etiketi kendi olgularıyla çelişiyor.
            ///
            /// Etiket kalibrasyona giren **tek** yargı: `strong` olan her token
            /// hedef tuşlara güçlü örnek yazıyor. Değerinin doğru üretildiğini
            /// hiçbir şey sınamıyordu — validator etiketin hedef token, cursor,
            /// literal ve hizalama ile ilişkisine bakmıyor, golden da etiket
            /// alanlarını karşılaştırmıyordu. Yani uydurulmuş bir `targetWord`
            /// bütün zincirden temiz geçip yanlış tuşlara örnek yazabiliyordu.
            case labelInconsistent
            /// Zaman değeri denemenin penceresine sığmıyor.
            ///
            /// İki saat tabanının karıştığı hâli tam olarak bu yakalıyor:
            /// `UITouch.timestamp` açılışa göre, `CFAbsoluteTimeGetCurrent`
            /// duvar saatine göre. Gerçek bir cihaz kaydında harf action'larının
            /// `t`'si −806 576 468 çıktı ve **monotonluk kontrolü yeşil geçti**,
            /// çünkü dizi kendi içinde artıyordu.
            case timeOutOfSessionWindow
        }
        public let kind: Kind
        public let actionID: Int?
        public let detail: String

        public var description: String {
            let a = actionID.map { "action \($0): " } ?? ""
            return "\(a)\(kind.rawValue) — \(detail)"
        }
    }

    /// - Returns: bulgular; boşsa kayıt yapısal olarak tutarlı.
    /// - Parameter layout: hedef dizisini yeniden türetmek için. Verilmezse §2.3
    ///   kanoniklik kontrolü **atlanıyor**: yanlış bir layout'la doğrulamak,
    ///   doğru bir kaydı bozuk göstermekten beterdir.
    public static func validate(_ session: CanonicalSession,
                                state: SessionEventReducer.State? = nil,
                                layout: KeyLayout? = nil)
        -> [Finding] {
        var out: [Finding] = []
        out += validateActionSequence(session)
        out += validateTouches(session)
        out += validatePayloads(session)
        out += validateNumbers(session)
        out += validateStatus(session)
        out += validateTimeWindow(session)

        out += validateEffectTable(session)
        out += validateTokenIdentity(session)
        out += validateLabels(session)
        out += validatePromptTokens(session, layout: layout)
        out += validateNativeCompleteness(session)

        let s = state ?? SessionEventReducer.reduce(session)
        out += s.violations.map {
            Finding(kind: .reducerViolation, actionID: $0.actionID,
                    detail: "\($0.kind.rawValue): \($0.detail)")
        }
        out += validateDivergence(session, state: s)
        return out
    }
}
