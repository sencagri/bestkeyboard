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

    // MARK: - §2.1 operasyon × etki tablosu

    /// Kaydedilen etkinin, o operasyon için **tabloda** olup olmadığı.
    ///
    /// Reducer bu bileşimleri katlıyor ama katlarken sormuyor: tabloda olmayan
    /// bir satır (ör. `space` ile `restoreToken`) sessizce katlanıp anlamsız
    /// bir duruma yol açıyordu. Yazıcı hatası burada görünmeli.
    private static func validateEffectTable(_ session: CanonicalSession)
        -> [Finding] {
        var out: [Finding] = []
        for a in session.actions {
            guard let e = a.effect.value else { continue }
            let ok: Bool
            switch a.kind {
            case .space, .symbol, .newline, .suggestionPick:
                // Sınır: kanıt sıfırlanır ve hiçbir şey silinmez. Tek istisna
                // `suggestionPick`'in kopuk kanıtta no-op olması — orada kanıt
                // `detached` kalıyor ve sınırın `cleared`'ı dayatılırsa meşru
                // kayıt violation sayılırdı.
                ok = e.pending == .none && e.deleted.isEmpty
                    && (e.evidenceStateAfter == .cleared
                        || (a.kind == .suggestionPick
                            && e.evidenceStateAfter == .detached))

            case .backspaceTap:
                ok = Self.tapRowIsValid(e)

            case .backspaceRepeat:
                // Repeat geri açma **yapmıyor**: kullanıcı toplu siliyor,
                // düzenlemiyor.
                ok = e.pending != .restoreToken && Self.tapRowIsValid(e)

            case .deleteWord, .backspaceUnspecified:
                ok = e.pending != .restoreToken && e.pending != .dropLast

            case .letter, .shift, .planeChange:
                // Bu kipler yıkıcı değil; etki taşımaları zaten
                // `validatePayloads` tarafından yakalanıyor.
                ok = false
            }
            if !ok {
                out.append(.init(kind: .effectNotInTable, actionID: a.actionID,
                                 detail: "\(a.kind.rawValue) × \(e.pending.rawValue)"
                                    + "/\(e.deleted)/\(e.evidenceStateAfter.rawValue)"))
            }
            // `restoreToken` hangi token'ı açtığını **söylemek zorunda**;
            // söylemezse reducer hedefsiz kalır.
            if e.pending == .restoreToken, e.restoredToken == nil {
                out.append(.init(kind: .effectNotInTable, actionID: a.actionID,
                                 detail: "restoreToken hedefsiz"))
            }
            if e.pending != .restoreToken, e.restoredToken != nil {
                out.append(.init(kind: .effectNotInTable, actionID: a.actionID,
                                 detail: "restoredToken yalnız restoreToken'da"))
            }
            // Kanonik biçim: bitişik ayırıcı ya da atfedilemez tekrar etmez.
            if Self.hasAdjacentDuplicates(e.deleted) {
                out.append(.init(kind: .effectNotInTable, actionID: a.actionID,
                                 detail: "kanonik değil: \(e.deleted)"))
            }
        }
        return out
    }

    /// `backspaceTap`/`backspaceRepeat`'in tablodaki satırları.
    private static func tapRowIsValid(_ e: DestructiveEffect) -> Bool {
        switch e.pending {
        case .restoreToken:
            // Geri açma: hiçbir şey silinmiş sayılmaz, kanıt geri gelir.
            return e.deleted.isEmpty && e.evidenceStateAfter == .attached
        case .dropLast:
            // Hizalı silme: yalnız bekleyen kanıt düşer.
            return e.deleted.isEmpty
                && (e.evidenceStateAfter == .attached
                    || e.evidenceStateAfter == .cleared)
        case .dropAll:
            // İlk kopuş.
            return e.deleted.isEmpty
                && (e.evidenceStateAfter == .detached
                    || e.evidenceStateAfter == .cleared)
        case .none:
            // Composing yokken silme ya da zaten kopuk yüzeyde silme.
            return true
        }
    }

    private static func hasAdjacentDuplicates(_ spans: [DeletedSpan]) -> Bool {
        for (a, b) in zip(spans, spans.dropFirst()) {
            if case .separator = a, case .separator = b { return true }
            if case .unattributed = a, case .unattributed = b { return true }
        }
        return false
    }

    // MARK: - Token kimliği

    /// Kimlikler **monoton, tekil ve yeniden kullanılmaz** olmalı.
    ///
    /// Geri açılıp yeniden commit edilen token **yeni** kimlik alır; eskisini
    /// geri vermek, kaydı okuyan tarafta iki farklı yazım denemesini tek token
    /// sanmaya yol açardı.
    private static func validateTokenIdentity(_ session: CanonicalSession)
        -> [Finding] {
        var out: [Finding] = []
        var seen = Set<Int>()
        var last = Int.min
        for a in session.actions {
            guard a.kind.closesToken else { continue }
            guard let commit = a.commit else {
                out.append(.init(kind: .boundaryWithoutCommit,
                                 actionID: a.actionID,
                                 detail: "\(a.kind.rawValue) commit taşımıyor"))
                continue
            }
            // Boş token gerçek bir token değil; kimlik tüketmez ve kimliği
            // `.notApplicable` olmalı — `.unknown` "vardı ama bilmiyoruz"
            // demek olurdu.
            guard commit.kind != .empty else {
                if commit.tokenID != .notApplicable {
                    out.append(.init(kind: .tokenIDNotMonotonic,
                                     actionID: a.actionID,
                                     detail: "boş token kimlik taşıyor"))
                }
                continue
            }
            guard let id = commit.tokenID.value?.raw else { continue }
            if !seen.insert(id).inserted {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) yeniden kullanıldı"))
            }
            if id <= last {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) monoton değil (önceki \(last))"))
            }
            last = id
        }
        // Hedefli etkiler yalnız **var olan** kimliklere atıf yapabilir.
        for a in session.actions {
            guard let e = a.effect.value else { continue }
            var referenced = e.restoredToken.map { [$0.raw] } ?? []
            for span in e.deleted {
                switch span {
                case let .editedToken(id), let .removedToken(id):
                    referenced.append(id.raw)
                case .separator, .unattributed:
                    continue
                }
            }
            for id in referenced where !seen.contains(id) {
                out.append(.init(kind: .tokenIDNotMonotonic, actionID: a.actionID,
                                 detail: "kimlik \(id) hiç commit edilmemiş"))
            }
        }
        return out
    }

    // MARK: - Yerel v3 bütünlüğü

    /// **v3 hiçbir `.unknown` üretmez.** `.unknown` yalnız v2 migrasyonundan
    /// çıkar; yerel bir kayıtta görünmesi yazıcının bir olguyu atladığı
    /// anlamına gelir ve o kayıt sessizce kalibrasyondan düşerdi.
    private static func validateNativeCompleteness(_ session: CanonicalSession)
        -> [Finding] {
        guard session.sourceSchema == CanonicalSession.currentSchema else {
            return []
        }
        var out: [Finding] = []
        func check(_ isUnknown: Bool, _ name: String, _ id: Int? = nil) {
            guard isUnknown else { return }
            out.append(.init(kind: .unknownFactInNativeRecord, actionID: id,
                             detail: name))
        }
        check(session.promptTokens.isUnknown, "promptTokens")
        check(session.geometry.layoutFingerprint.isUnknown, "layoutFingerprint")
        check(session.engine.build.codeRevision.isUnknown, "build.codeRevision")
        check(session.engine.build.provenance.isUnknown, "build.provenance")
        check(session.engine.policy.feedbackVisible.isUnknown, "policy.feedbackVisible")
        check(session.engine.policy.suggestionsVisible.isUnknown,
              "policy.suggestionsVisible")
        check(session.engine.policy.correction.isUnknown, "policy.correction")
        if let cfg = session.engine.configuration.value {
            check(cfg.scoring.isUnknown, "scoring")
            check(cfg.calibration.sigma.isUnknown, "calibration.sigma")
            for p in cfg.packs {
                check(p.sha256.isUnknown, "pack.sha256(\(p.name))")
                check(p.topology.isUnknown, "pack.topology(\(p.name))")
            }
        }
        for a in session.actions {
            check(a.event.isUnknown, "event", a.actionID)
            check(a.effect.isUnknown, "effect", a.actionID)
            check(a.document.isUnknown, "document", a.actionID)
            check(a.candidates.isUnknown, "candidates", a.actionID)
            check(a.shown.isUnknown, "shown", a.actionID)
            if let c = a.commit {
                check(c.tokenID.isUnknown, "commit.tokenID", a.actionID)
                check(c.cursorBefore.isUnknown, "commit.cursorBefore", a.actionID)
            }
        }
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

        // Yaşam döngüsü: `began → moved* → ended|cancelled`, tam bir kez.
        //
        // Eskiden yalnız terminal **sayısı** kontrol ediliyordu; `.began` fazlı
        // ama `outcome: .committed` olan bir kayıt harfi geçiriyordu. Faz ile
        // akıbet ayrı alanlar ve ayrışabilirler — biri "parmak hâlâ ekranda"
        // derken diğeri "harf kesinleşti" diyordu.
        var byID: [Int: [CanonicalSession.Touch]] = [:]
        for t in session.touches { byID[t.touchID, default: []].append(t) }

        for (id, records) in byID.sorted(by: { $0.key < $1.key }) {
            guard records.first?.phase == .began || records.count == 1 else {
                out.append(.init(kind: .touchLifecycle, actionID: nil,
                                 detail: "touch \(id) `began` ile başlamıyor"))
                continue
            }
            let terminals = records.filter {
                $0.phase == .ended || $0.phase == .cancelled
            }
            if terminals.count > 1 {
                out.append(.init(kind: .duplicateTerminalTouch, actionID: nil,
                                 detail: "touch \(id) için \(terminals.count) terminal"))
            }
            // Terminalden **sonra** olay olamaz: dokunma bitti.
            if let terminalIndex = records.firstIndex(where: {
                $0.phase == .ended || $0.phase == .cancelled
            }), terminalIndex != records.count - 1 {
                out.append(.init(kind: .touchLifecycle, actionID: nil,
                                 detail: "touch \(id) terminalden sonra olay taşıyor"))
            }
            // `committed` **yalnız** terminal kayıtta olabilir.
            for r in records where r.outcome == .committed {
                if r.phase != .ended {
                    out.append(.init(kind: .touchLifecycle, actionID: nil,
                                     detail: "touch \(id) `\(r.phase.rawValue)` fazında"
                                        + " committed"))
                }
            }
        }

        let committed = Set(session.touches
            .filter { $0.outcome == .committed && $0.phase == .ended }
            .map(\.touchID))
        // Bir dokunma **tam bir** harfe bağlanabilir: iki harfin aynı
        // dokunmayı tüketmesi, aynı uzamsal kanıtın iki karaktere sayılması
        // demek ve kalibrasyon onu iki kez öğrenirdi.
        var consumed = Set<Int>()
        for a in session.actions where a.kind == .letter {
            guard let id = a.touchID else {
                out.append(.init(kind: .letterTouchUnresolved, actionID: a.actionID,
                                 detail: "harfin dokunması yok"))
                continue
            }
            if !committed.contains(id) {
                out.append(.init(kind: .letterTouchUnresolved, actionID: a.actionID,
                                 detail: "touch \(id) terminal committed değil"))
            }
            if !consumed.insert(id).inserted {
                out.append(.init(kind: .touchConsumedTwice, actionID: a.actionID,
                                 detail: "touch \(id) ikinci kez tüketildi"))
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
    /// Bir denemenin makul üst sınırı.
    ///
    /// Sınırsız bırakmak, saat tabanı karışıklığının ürettiği 10⁸ saniyelik
    /// değerleri "uzun oturum" diye geçirirdi. Bir günden uzun tek deneme
    /// gerçek bir yazım denemesi değil.
    static let maxSessionDuration: TimeInterval = 86_400

    /// Zamanlar denemenin **kendi** penceresinde mi.
    ///
    /// `t` oturum başlangıcına göre bir **süre**: negatif olması mümkün değil.
    /// `endedAt` de başlangıçtan önce olamaz. İkisi de tek satırlık kontrol ama
    /// olmadığında kaydın bütün zaman çizgisi çöp olabiliyordu ve hiçbir şey
    /// bunu söylemiyordu.
    private static func validateTimeWindow(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        for a in session.actions {
            guard a.t.isFinite else { continue }   // `nonFiniteNumber` ayrı sayıyor
            if a.t < 0 {
                out.append(.init(kind: .timeOutOfSessionWindow, actionID: a.actionID,
                                 detail: "t = \(a.t) < 0; saat tabanı karışmış olabilir"))
            } else if a.t > maxSessionDuration {
                out.append(.init(kind: .timeOutOfSessionWindow, actionID: a.actionID,
                                 detail: "t = \(a.t) > \(maxSessionDuration) s"))
            }
        }
        if let ended = session.endedAt {
            let span = ended.timeIntervalSince(session.startedAt)
            if span < 0 {
                out.append(.init(kind: .timeOutOfSessionWindow, actionID: nil,
                                 detail: "endedAt startedAt'tan önce (\(span) s)"))
            } else if span > maxSessionDuration {
                out.append(.init(kind: .timeOutOfSessionWindow, actionID: nil,
                                 detail: "deneme \(span) s sürmüş"))
            }
        }
        return out
    }

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
    /// Kaydedilen hedef dizisi, `promptText`'ten türetilenle aynı mı (§2.3).
    ///
    /// ## Neden `layout` gerekiyor
    ///
    /// Tokenizer "harf" tanımını layout'tan alıyor: klavyede olmayan bir
    /// karakteri kullanıcı yazamaz. Layout verilmezse kontrol **atlanıyor** —
    /// yanlış bir layout'la doğrulamak, doğru bir kaydı bozuk göstermekten
    /// beterdir.
    ///
    /// Boş dizi ayrıca bulgu: yazılacak harfi olmayan bir hedefte tamamlanma
    /// koşulu daha başlamadan sağlanıyor.
    private static func validatePromptTokens(_ session: CanonicalSession,
                                             layout: KeyLayout?) -> [Finding] {
        guard let tokens = session.promptTokens.value else { return [] }
        if tokens.isEmpty {
            return [.init(kind: .promptTokensNotCanonical, actionID: nil,
                          detail: "hedef dizisi boş; yazılacak harf yok")]
        }
        guard let layout else { return [] }
        let expected = PromptTokenizer(layout: layout).tokens(of: session.promptText)
        guard tokens != expected else { return [] }
        return [.init(kind: .promptTokensNotCanonical, actionID: nil,
                      detail: "kayıt \(tokens), tokenizer \(expected)")]
    }

    /// §12.5 etiketi kendi olgularıyla tutarlı mı.
    ///
    /// ## Neden doğrulanmak zorunda
    ///
    /// Etiket, kalibrasyona giren **tek** yargı: `confidence == .strong` olan
    /// token'ın harfleri hedef tuşlara güçlü örnek olarak yazılıyor. Değerinin
    /// doğru üretildiğini hiçbir şey sınamıyordu. Geçerli bir `ev` commit'inin
    /// etiketini `targetWord: "at", matchesTarget: true, confidence: strong`
    /// yapmak yeterliydi: validator ve golden temiz kalıyor, çıkarıcı `e`/`v`
    /// koordinatlarını `a`/`t` tuşlarına güçlü örnek olarak yazıyordu.
    ///
    /// ## Neden `cursorBefore` üzerinden
    ///
    /// Hedef, commit **anındaki** cursor konumundan okunuyor; action'ın
    /// `targetTokenIndex`'i değil. İkincisi yazıcının o an ne düşündüğü,
    /// birincisi katlamanın türettiği olgu — etiketi yazıcının kendi iddiasıyla
    /// doğrulamak hiçbir şey doğrulamaz.
    private static func validateLabels(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        // `strong` ve `protocol` yalnız hedefli protokolde meşru (§12.5).
        let targeted = session.condition == .calibrationReplay
            && session.alignmentSource == .constructed
        // Sapma **eylem sırasına göre** izleniyor: nihai `state.diverged`
        // sapmadan önceki token'ları da suçlardı.
        var diverged = false

        for a in session.actions {
            if let e = a.effect.value {
                if e.pending == .dropAll, e.evidenceStateAfter == .detached {
                    diverged = true
                }
                for span in e.deleted {
                    switch span {
                    case .editedToken, .unattributed: diverged = true
                    case .removedToken, .separator: break
                    }
                }
            }
            guard let c = a.commit, c.kind != .empty else { continue }
            let label = c.label

            func fail(_ detail: String) {
                out.append(.init(kind: .labelInconsistent, actionID: a.actionID,
                                 detail: detail))
            }

            if !targeted {
                if label.source == .protocol {
                    fail("source=protocol ama koşul \(session.condition.rawValue)/"
                         + "\(session.alignmentSource.rawValue)")
                }
                if label.confidence == .strong {
                    fail("confidence=strong ama hizalama protokolden gelmiyor")
                }
            }

            // Hedef kelime: gösterilen dizi biliniyorsa **birebir** o konumdaki
            // kelime olmalı.
            if let tokens = session.promptTokens.value,
               let cursor = c.cursorBefore.value {
                let expected = cursor >= 0 && cursor < tokens.count
                    ? tokens[cursor] : nil
                if label.targetWord != expected {
                    fail("targetWord=\(label.targetWord ?? "yok") ama cursor"
                         + " \(cursor) → \(expected ?? "hedef dışı")")
                }
            }

            // `matchesTarget` türetilmiş bir olgu: literal ile hedefin Türkçe
            // küçük harf karşılaştırması.
            let expectedMatch = label.targetWord.map {
                CanonicalSession.turkishLowercased(c.literal)
                    == CanonicalSession.turkishLowercased($0)
            }
            if label.matchesTarget != expectedMatch {
                fail("matchesTarget=\(label.matchesTarget.map(String.init) ?? "yok")"
                     + " ama literal '\(c.literal)' ↔ hedef"
                     + " '\(label.targetWord ?? "yok")'")
            }

            // `strong` üç şeyi birlikte gerektiriyor: protokol, hedefle birebir
            // literal ve bozulmamış hizalama.
            if label.confidence == .strong {
                if label.matchesTarget != true {
                    fail("strong ama literal hedefle eşleşmiyor")
                }
                if diverged {
                    fail("strong ama hizalama bu action'dan önce bozulmuştu")
                }
            }
        }
        return out
    }

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
