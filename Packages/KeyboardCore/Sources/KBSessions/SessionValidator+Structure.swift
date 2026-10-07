import Foundation
import KBGeometry
import KBRuntime

extension SessionValidator {

    // MARK: - Yapısal

    /// `actionID` **sıfırdan başlayan kesintisiz** dizi olmalı.
    ///
    /// Boşluk, kaydın bir parçasının kaybolduğu anlamına geliyor ve katlama
    /// bunu fark etmeden çalışırdı: eksik bir `space` iki token'ı birleştirir.
    static func validateActionSequence(_ session: CanonicalSession)
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
    static func validateTouches(_ session: CanonicalSession) -> [Finding] {
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
            let terminals = records.filter(\.phase.isTerminal)
            if terminals.count > 1 {
                out.append(.init(kind: .duplicateTerminalTouch, actionID: nil,
                                 detail: "touch \(id) için \(terminals.count) terminal"))
            }
            // Terminalden **sonra** olay olamaz: dokunma bitti.
            if let terminalIndex = records.firstIndex(where: \.phase.isTerminal),
               terminalIndex != records.count - 1 {
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
    static func validatePayloads(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        for a in session.actions {
            guard let event = a.event.value else { continue }
            // Eşleme **komutun kendisinde** (`ReplayCommand.actionKind`) —
            // yazıcının kipi seçtiği kural ile burada sınanan kural aynı.
            if a.kind != event.actionKind {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "kind \(a.kind.rawValue), event \(event)"))
            }
            // `baseKey` tek grapheme taşımak zorunda: `layout.keyIndex(for:)`
            // tek karakter istiyor ve çok karakterli bir değer sessizce
            // `nil`'e düşerdi.
            if case let .letter(baseKey, _, _) = event, event.baseCharacter == nil {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "baseKey tek grapheme değil: \(baseKey)"))
            }
            // Sembol tek grapheme, metin boş olmayan dize: koordinatör ikisini
            // de mutasyondan önce reddediyor ve böyle bir kayıt replay
            // edilemez.
            if case let .symbol(s) = event, event.symbolCharacter == nil {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "sembol tek grapheme değil: \(s)"))
            }
            if case .text("") = event {
                out.append(.init(kind: .payloadKindMismatch, actionID: a.actionID,
                                 detail: "metin komutu boş"))
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
    static func validateNumbers(_ session: CanonicalSession) -> [Finding] {
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
    static func validateTimeWindow(_ session: CanonicalSession) -> [Finding] {
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

    /// Terminal durum ile `endedAt` tutarlı olmalı.
    ///
    /// `.recording` + `endedAt` dolu ya da `.completed` + `endedAt` boş, kaydın
    /// yarıda kesildiği ya da durumun elle değiştirildiği anlamına geliyor.
    static func validateStatus(_ session: CanonicalSession) -> [Finding] {
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
    static func validatePromptTokens(_ session: CanonicalSession,
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
}
