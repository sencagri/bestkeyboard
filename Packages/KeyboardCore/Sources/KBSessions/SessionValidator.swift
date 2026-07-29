import Foundation
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
    public static func validate(_ session: CanonicalSession,
                                state: SessionEventReducer.State? = nil)
        -> [Finding] {
        var out: [Finding] = []
        out += validateActionSequence(session)
        out += validateTouches(session)
        out += validatePayloads(session)
        out += validateNumbers(session)
        out += validateStatus(session)

        let s = state ?? SessionEventReducer.reduce(session)
        out += s.violations.map {
            Finding(kind: .reducerViolation, actionID: $0.actionID,
                    detail: "\($0.kind.rawValue): \($0.detail)")
        }
        out += validateDivergence(session, state: s)
        return out
    }

    // MARK: - Yapısal

    /// `actionID` **sıfırdan başlayan kesintisiz** dizi olmalı.
    ///
    /// Boşluk, kaydın bir parçasının kaybolduğu anlamına geliyor ve katlama
    /// bunu fark etmeden çalışırdı: eksik bir `space` iki token'ı birleştirir.
    private static func validateActionSequence(_ session: CanonicalSession)
        -> [Finding] {
        var out: [Finding] = []
        var lastTime = -Double.infinity
        for (i, a) in session.actions.enumerated() {
            if a.actionID != i {
                out.append(.init(kind: .actionIDNotContiguous, actionID: a.actionID,
                                 detail: "\(i). sırada \(a.actionID) var"))
            }
            if a.t < lastTime {
                out.append(.init(kind: .timeNotMonotonic, actionID: a.actionID,
                                 detail: "t=\(a.t) < önceki \(lastTime)"))
            }
            lastTime = a.t
            if a.kind.isLegacyOnly, session.sourceSchema == CanonicalSession.currentSchema {
                out.append(.init(kind: .legacyOnlyKindInNativeRecord,
                                 actionID: a.actionID,
                                 detail: "\(a.kind.rawValue) yalnız migrasyondan çıkabilir"))
            }
        }
        return out
    }

    /// Her `letter` **tek terminal committed** dokunmaya çözülmeli.
    ///
    /// Çözülmezse harfin uzamsal kanıtı yok demektir; o token kalibrasyona
    /// giremez ve bunu sessizce geçmek, kanıtsız bir örneği güçlü sayardı.
    private static func validateTouches(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        var terminalCount: [Int: Int] = [:]
        for t in session.touches where t.phase == .ended || t.phase == .cancelled {
            terminalCount[t.touchID, default: 0] += 1
        }
        for (id, n) in terminalCount where n > 1 {
            out.append(.init(kind: .duplicateTerminalTouch, actionID: nil,
                             detail: "touch \(id) için \(n) terminal kayıt"))
        }

        let committed = Set(session.touches
            .filter { $0.outcome == .committed }
            .map(\.touchID))
        for a in session.actions where a.kind == .letter {
            guard let id = a.touchID else {
                out.append(.init(kind: .letterTouchUnresolved, actionID: a.actionID,
                                 detail: "harfin dokunması yok"))
                continue
            }
            if !committed.contains(id) {
                out.append(.init(kind: .letterTouchUnresolved, actionID: a.actionID,
                                 detail: "touch \(id) committed değil"))
            }
        }
        return out
    }

    /// Yük ile kip uyuşmalı.
    ///
    /// `kind` ile `event` iki ayrı alan ve ayrışabilirler: bir yazıcı hatası
    /// `kind: .space` yazarken `event: .backspaceTap` koyabilir ve replay o
    /// zaman kayıttan **farklı** bir şey sürerdi.
    private static func validatePayloads(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        for a in session.actions {
            guard let event = a.event.value else { continue }
            let ok: Bool
            switch (a.kind, event) {
            case (.letter, .letter): ok = true
            case (.symbol, .symbol): ok = true
            case (.space, .space): ok = true
            case (.newline, .newline): ok = true
            case (.suggestionPick, .suggestionPick): ok = true
            case (.backspaceTap, .backspaceTap): ok = true
            case (.backspaceRepeat, .backspaceRepeat): ok = true
            case (.deleteWord, .deleteWord): ok = true
            case (.shift, .shift): ok = true
            case (.planeChange, .planeChange): ok = true
            default: ok = false
            }
            if !ok {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "kind \(a.kind.rawValue), event \(event)"))
            }
            // `baseKey` tek grapheme taşımak zorunda: `layout.keyIndex(for:)`
            // tek karakter istiyor ve çok karakterli bir değer sessizce
            // `nil`'e düşerdi.
            if case let .letter(baseKey, _, _) = event, baseKey.count != 1 {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "baseKey tek grapheme değil: \(baseKey)"))
            }
            // Yıkıcı olmayan bir kip yıkıcı etki taşıyamaz.
            if !a.kind.invalidatesBeam, !a.kind.closesToken,
               a.effect.value != nil {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "\(a.kind.rawValue) yıkıcı etki taşıyor"))
            }
        }
        return out
    }

    /// Sayısal alanlar sonlu olmalı.
    ///
    /// JSON sonsuz taşıyamıyor; `θ = ∞` olan koruma durumu ayrı bir bayrakla
    /// (`literalProtected`) yazılıyor. Bir alanda NaN görülmesi, o bayrağın
    /// atlandığı ya da hesabın bozulduğu anlamına gelir.
    private static func validateNumbers(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        func check(_ v: Double?, _ name: String, _ id: Int?) {
            guard let v, !v.isFinite else { return }
            out.append(.init(kind: .nonFiniteNumber, actionID: id,
                             detail: "\(name) = \(v)"))
        }
        for t in session.touches {
            check(t.rawX, "rawX", nil); check(t.rawY, "rawY", nil)
            check(t.normX, "normX", nil); check(t.normY, "normY", nil)
            check(t.decoderX, "decoderX", nil); check(t.decoderY, "decoderY", nil)
            check(t.timestamp, "timestamp", nil)
        }
        for a in session.actions {
            check(a.t, "t", a.actionID)
            guard let c = a.commit else { continue }
            check(c.delta, "delta", a.actionID)
            check(c.theta, "theta", a.actionID)
            check(c.bestCost, "bestCost", a.actionID)
        }
        return out
    }

    /// Terminal durum ile `endedAt` tutarlı olmalı.
    ///
    /// `.recording` + `endedAt` dolu ya da `.completed` + `endedAt` boş, kaydın
    /// yarıda kesildiği ya da durumun elle değiştirildiği anlamına geliyor.
    private static func validateStatus(_ session: CanonicalSession) -> [Finding] {
        let terminal = session.status != .recording
        if terminal && session.endedAt == nil {
            return [.init(kind: .terminalStateInconsistent, actionID: nil,
                          detail: "\(session.status.rawValue) ama endedAt yok")]
        }
        if !terminal && session.endedAt != nil {
            return [.init(kind: .terminalStateInconsistent, actionID: nil,
                          detail: "recording ama endedAt dolu")]
        }
        return []
    }

    /// Kayıtlı sapma bayrağı ile türetilen aynı olmalı.
    ///
    /// Yalnız v2 kayıtlarında sınanabiliyor: v3 bayrağı ayrıca yazmıyor, çünkü
    /// `effect` olgularından **kesin** olarak katlanıyor ve iki yerde tutulan
    /// bir olgu sessizce ayrışır.
    private static func validateDivergence(_ session: CanonicalSession,
                                           state: SessionEventReducer.State)
        -> [Finding] {
        // Bilinmeyen olgu varsa katlama zaten doğrulanamaz; karşılaştırma
        // sahte bir uyuşmazlık üretirdi.
        guard state.unverifiable.isEmpty else { return [] }
        guard let recorded = session.actions.last?.legacy.value?.alignmentDiverged
        else { return [] }
        guard recorded != state.diverged else { return [] }
        return [.init(kind: .divergenceMismatch, actionID: nil,
                      detail: "kayıt \(recorded), türetim \(state.diverged)")]
    }
}
