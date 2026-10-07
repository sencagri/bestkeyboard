import Foundation
import KBRuntime
import KBSpatial

/// Olay günlüğünü token görünümüne katlayan **saf** fonksiyon — plan v8 §2.4.
///
/// ## Neden reducer
///
/// Sözleşme §12.6: *"`actions[]` append-only bir olay dizisidir; token görünümü
/// **Mac tarafında türetilir**."* Cihazda token listesi tutmak yanlış sayım
/// üretiyordu, çünkü boşluğu silmek önceki kelimeyi dokunmalarıyla birlikte
/// geri açabiliyor — ilk commit kaydı artık nihai token değil.
///
/// ## Neden saf
///
/// Reducer hiçbir şey **çıkarmaz**; yalnız kayda yazılmış olguları katlar.
/// Geri açma ve kanıt kopması kararları `ComposingSession`'da veriliyor ve
/// `DestructiveEffect` olarak kayda giriyor (§6.2). Reducer onları yeniden
/// keşfetmeye çalışsaydı belge bağlamına ihtiyacı olurdu ve elinde yok.
///
/// ## Bilinmeyen olgu
///
/// v2'den migrate edilmiş kayıtlarda yıkıcı olgu `.unknown`. Reducer o noktada
/// **tahmin etmiyor**: action'ı `unverifiable`'a yazıyor ve sonrasını hizalama
/// dışı sayıyor. Bilinmeyenden sonuç çıkarmak yerine bilinmediğini raporlamak.
public enum SessionEventReducer {

    /// Bir token'a ait tek dokunma.
    public struct TouchAtom: Equatable, Sendable {
        public let touchID: Int
        public let keyIndex: Int?
        /// Kaydedilen dokunmanın tamamı — kalibrasyon çıkarıcısı buna bakıyor.
        public let touch: CanonicalSession.Touch
    }

    /// Türetilmiş token.
    public struct Token: Equatable, Sendable {
        public let tokenID: TokenID
        /// Commit **öncesi** cursor — geri açma bunu geri yükler.
        public let cursorBefore: Int
        public var atoms: [TouchAtom]
        public var literal: String
        public var committed: String
        /// Kayda yazılan dokunma sayısı — türetilenle karşılaştırılıyor.
        public var recordedTouchCount: Int
        /// Yıkıcı bir işlem bu token'ın metnini geçersiz kıldı.
        public var invalidated: Bool = false
        /// Hizalama bu token'a ulaştığında zaten bozulmuştu.
        public var afterDivergence: Bool = false

        /// Kayıt ile türetim aynı şeyi mi söylüyor.
        ///
        /// Sapma bunu **meşrulaştırmaz**: hizalama bozulsa bile token'ın kendi
        /// dokunma sayısı tutmak zorunda. Tutmuyorsa kayıtta delik var.
        public var touchCountAgrees: Bool { atoms.count == recordedTouchCount }

        /// Token'ın dokunmaları hedefe **güvenle** bağlanabilir mi.
        ///
        /// Üç tüketici (kalibrasyon çıkarımı, kalibrasyon kolları, dil önceli
        /// sondası) bu soruyu ayrı ayrı soruyordu. Biri bir koşulu (örneğin
        /// geçersiz kılınmış token) atlasaydı silinmiş bir kelimenin
        /// dokunmaları ölçüme girerdi.
        public enum Trust: Sendable {
            case trusted
            /// Hiza bu token'dan önce bozuldu ya da token sonradan silindi.
            case diverged
            /// Kayıtlı dokunma sayısı türetilenle uyuşmuyor — kayıtta delik var.
            case touchCountMismatch
        }

        public var trust: Trust {
            if afterDivergence || invalidated { return .diverged }
            return touchCountAgrees ? .trusted : .touchCountMismatch
        }

        /// Dokunmaların decoder'a verilen hâli — biri bile noktasızsa `nil`.
        ///
        /// Eksik noktayı atlamak dokunma ile karakter eşlemesini kaydırırdı;
        /// `(0,0)` koymak kanıt uydurmak olurdu. İkisinin yerine token düşüyor.
        public var decoderSamples: [TouchSample]? {
            let samples = atoms.compactMap(\.touch.decoderSample)
            return samples.count == atoms.count ? samples : nil
        }
    }

    /// Bir dokunmanın neden hiçbir token'a girmediği.
    public enum DropReason: String, Equatable, Sendable {
        /// Kanıt kopmuşken gelen harf: hangi karakteri ürettiği bilinmiyor.
        case evidenceDetached
        /// Kopma **anında** bekleyen dokunmalar düşürüldü.
        ///
        /// Bunu yapmazsak `commit.touchCount == token.atoms.count` meşru bir
        /// yolda patlıyordu: kopma öncesi biriken dokunmalar token'a giriyor
        /// ama canlı taraf onları saymıyordu.
        case droppedOnDetach
        /// Silme bekleyen kanıtı düşürdü.
        case deletedBeforeCommit
        /// Dokunma hiçbir tuşa denk gelmedi.
        case neverHit
    }

    public struct Drop: Equatable, Sendable {
        public let atom: TouchAtom
        public let reason: DropReason
        public let actionID: Int
    }

    /// Katlama sırasında bulunan tutarsızlık.
    ///
    /// Reducer `Void` döndürdüğü sürece bozuk bir sıra sessizce geçiyordu.
    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        public enum Kind: String, Equatable, Sendable {
            /// Sınır olayında boş commit ama bekleyen dokunmalar var.
            case pendingAtEmptyCommit
            /// Geri açılan kimlik hiçbir kapalı token'a ait değil.
            case restoreOfUnknownToken
            /// Hedefli silme bilinmeyen bir kimliği işaret ediyor.
            case deleteOfUnknownToken
            /// Zaten geri alınmış token'a ikinci kez atıf.
            case restoreOfInvalidatedToken
            /// Hedefli işlem **en son kapanan** token'ı işaret etmiyor.
            ///
            /// `ComposingSession` yalnız geçmişin tepesini geri açabiliyor ve
            /// silme belgenin **sonundan** yürüyor. Daha eski bir token'a atıf
            /// yapan kayıt, üretimde imkânsız bir şeyi anlatıyor: yazıcı hatası.
            /// Reducer bunu `lastIndex` ile sessizce uyguluyordu — araya giren
            /// token'lar açıkta kalıyor ve cursor keyfî bir yere taşınıyordu.
            case targetIsNotTheNewestToken
            /// Kayıtlı dokunma sayısı türetilenle uyuşmuyor.
            case touchCountMismatch
            /// Bilinmeyen olgu — katlama bu noktadan sonra doğrulanamaz.
            case unknownFact
        }
        public let kind: Kind
        public let actionID: Int
        public let detail: String

        public var description: String {
            "action \(actionID): \(kind.rawValue) — \(detail)"
        }
    }

    public struct State: Equatable, Sendable {
        /// Hedef dizisindeki konum. **Clamp edilmiyor**: sınırın dışına
        /// çıkması başlı başına bir olgu ve gizlenirse tamamlanma koşulu
        /// (`cursor == promptTokens.count`) yanlışlıkla sağlanır.
        public var cursor: Int = 0
        public var pending: [TouchAtom] = []
        public var tokens: [Token] = []
        public var dropped: [Drop] = []
        public var evidence: DestructiveEffect.EvidenceState = .cleared
        /// Hizalama bozuldu — bu noktadan sonraki token'lar hedefe bağlanamaz.
        public var diverged: Bool = false
        public var violations: [Violation] = []
        /// Olgusu bilinmeyen action'lar; kalibrasyon bu kayıtları dışlıyor.
        public var unverifiable: [Int] = []
    }

    // MARK: - Katlama

    public static func reduce(_ session: CanonicalSession) -> State {
        var state = State()
        // **Son** faz: canlı motor da onu görüyordu. İlk fazı seçmek reducer'ı
        // decoder'dan farklı bir koordinatla besliyordu (§ `terminalTouches`).
        let touchByID = session.terminalTouches

        for action in session.actions {
            apply(action, to: &state, touches: touchByID)
        }
        return state
    }

    /// Tek bir action'ı katlar — canlı kayıt için.
    ///
    /// `RecordingEngine` her eylemden sonra durumu güncel tutmak zorunda:
    /// tamamlanma koşulu (`cursor == promptTokens.count`, ihlal yok) terminal
    /// **anında** biliniyor olmalı. Sonda topluca katlamak, o anda cevabı
    /// olmayan bir soru sormak olurdu.
    ///
    /// Sonuç, aynı olay dizisini `reduce` ile katlamakla **aynı** olmalı; testi
    /// bunu sınıyor.
    public static func applyIncrementally(_ action: CanonicalSession.Action,
                                          to state: inout State,
                                          touches: [Int: CanonicalSession.Touch]) {
        apply(action, to: &state, touches: touches)
    }

    private static func apply(_ action: CanonicalSession.Action,
                              to s: inout State,
                              touches: [Int: CanonicalSession.Touch]) {
        switch action.kind {
        case .letter:
            collectLetter(action, to: &s, touches: touches)

        case .shift, .planeChange:
            // UI olayları kanıta dokunmuyor: shift bir sonraki harfin
            // **yüzeyini** değiştiriyor ama uzamsal kanıt yine küçük harf
            // tuşuna ait, dolayısıyla eşleme bozulmuyor.
            break

        case .space, .symbol, .text, .newline, .suggestionPick:
            closeToken(action, to: &s)

        case .backspaceTap, .backspaceRepeat, .deleteWord, .backspaceUnspecified:
            applyDestructive(action, to: &s)
        }
    }

    /// Harf toplama — **kanıt durumu makinesi**.
    ///
    /// "Yalnız `.attached` iken topla" kuralı yeni token'ın **ilk** harfini
    /// düşürüyordu: token kapandığında kanıt `.cleared` oluyor ve bir sonraki
    /// harf oradan geliyor.
    private static func collectLetter(_ action: CanonicalSession.Action,
                                      to s: inout State,
                                      touches: [Int: CanonicalSession.Touch]) {
        switch s.evidence {
        case .cleared:
            s.evidence = .attached
        case .attached:
            break
        case .detached:
            // Kanıt kopmuşken hangi dokunmanın hangi karakteri ürettiği
            // bilinmiyor. Yüzey belgede duruyor ama kalibrasyona giremez.
            if let atom = atom(for: action, touches: touches) {
                s.dropped.append(.init(atom: atom, reason: .evidenceDetached,
                                       actionID: action.actionID))
            }
            return
        }

        guard let atom = atom(for: action, touches: touches) else { return }
        if atom.touch.outcome == .neverHit {
            s.dropped.append(.init(atom: atom, reason: .neverHit,
                                   actionID: action.actionID))
            return
        }
        s.pending.append(atom)
    }

    private static func atom(for action: CanonicalSession.Action,
                             touches: [Int: CanonicalSession.Touch]) -> TouchAtom? {
        guard let id = action.touchID, let t = touches[id] else { return nil }
        return TouchAtom(touchID: id, keyIndex: t.keyIndex, touch: t)
    }

    /// Sınır olayı: token kapanır ve cursor ilerler.
    private static func closeToken(_ action: CanonicalSession.Action,
                                   to s: inout State) {
        defer {
            // Sınır işlemleri kanıtı **her hâlde** sıfırlıyor
            // (`finishToken → clearComposing`). Olgu varsa ondan, yoksa
            // kuraldan: `.cleared`.
            s.evidence = action.effect.value?.evidenceStateAfter ?? .cleared
        }

        guard let commit = action.commit, commit.kind != .empty else {
            // Boş commit'te bekleyen dokunma **olmamalı**: token yoksa
            // dokunmalar nereye gitti?
            if !s.pending.isEmpty {
                s.violations.append(.init(
                    kind: .pendingAtEmptyCommit, actionID: action.actionID,
                    detail: "\(s.pending.count) bekleyen dokunma açıkta kaldı"))
                s.pending.removeAll()
            }
            return
        }

        // v2 kayıtlarında kimlik yok; katlama kimliğe dayalı hedefli etkileri
        // uygulayamaz. Uydurmak yerine doğrulanamaz diyoruz.
        guard let tokenID = commit.tokenID.value else {
            s.violations.append(.init(
                kind: .unknownFact, actionID: action.actionID,
                detail: "commit tokenID bilinmiyor; hedefli etki uygulanamaz"))
            s.unverifiable.append(action.actionID)
            s.pending.removeAll()
            s.cursor += 1
            return
        }

        let token = Token(
            tokenID: tokenID,
            // Cursor bilinmiyorsa geri açma yapılamaz; `cursorBefore`'ı
            // uydurmak, geri açmada hedefi yanlış konuma taşırdı.
            cursorBefore: commit.cursorBefore.value ?? s.cursor,
            atoms: s.pending, literal: commit.literal,
            committed: commit.committed,
            recordedTouchCount: commit.touchCount,
            afterDivergence: s.diverged)
        if commit.cursorBefore.isUnknown {
            s.unverifiable.append(action.actionID)
        }
        if !token.touchCountAgrees {
            s.violations.append(.init(
                kind: .touchCountMismatch, actionID: action.actionID,
                detail: "kayıt \(commit.touchCount), türetim \(token.atoms.count)"))
        }
        s.tokens.append(token)
        s.pending.removeAll()
        s.cursor += 1
    }

    /// Yıkıcı olay: bekleyen kanıt, silinen aralıklar ve kanıt durumu.
    private static func applyDestructive(_ action: CanonicalSession.Action,
                                         to s: inout State) {
        guard let effect = action.effect.value else {
            // v2'de yıkıcı olgu hiç kaydedilmemişti. Ne silindiğini tahmin
            // etmek yerine bu noktadan sonrasını hizalama dışı sayıyoruz.
            s.violations.append(.init(
                kind: .unknownFact, actionID: action.actionID,
                detail: "yıkıcı etki bilinmiyor"))
            s.unverifiable.append(action.actionID)
            s.diverged = true
            s.pending.removeAll()
            s.evidence = .cleared
            return
        }

        applyPending(effect, action: action, to: &s)
        applyDeletions(effect, action: action, to: &s)
        // **İlk kopuş sapma başlatır** (§2.1 tablosu, "hiza bozuldu" satırı):
        // yüzeyin hangi kısmının hangi dokunmadan geldiği artık bilinmiyor.
        //
        // Zaten kopukken gelen silmeler başlatmaz — o satırlarda `pending`
        // `.none` ve önceki durum korunuyor. `.dropAll` + `.cleared`
        // (composing token'ının tamamen silinmesi) de başlatmaz: commit
        // edilmiş bir token'a dokunulmuyor ve cursor değişmiyor.
        if effect.pending == .dropAll, effect.evidenceStateAfter == .detached {
            s.diverged = true
        }
        s.evidence = effect.evidenceStateAfter
    }

    private static func applyPending(_ effect: DestructiveEffect,
                                     action: CanonicalSession.Action,
                                     to s: inout State) {
        switch effect.pending {
        case .none:
            break
        case .dropLast:
            // Düşen dokunma **gerekçesiyle** kaydediliyor. Sessizce
            // `removeLast()` yapmak, kullanıcının bastığı bir tuşu hiçbir
            // token'a ve hiçbir gerekçeye bağlamadan yok ediyordu: `.dropAll`
            // gerekçe yazıyor, `.dropLast` yazmıyordu ve "toplam dokunma =
            // token'lardaki + gerekçeli düşenler" denkliği tam da en sık yolda
            // (yanlış harfi silip düzeltmek) tutmuyordu.
            if let atom = s.pending.popLast() {
                s.dropped.append(.init(atom: atom, reason: .deletedBeforeCommit,
                                       actionID: action.actionID))
            }
        case .dropAll:
            // **Kopma anında** bekleyenlerin tamamı gerekçeli düşer. Onları
            // token'da bırakmak `commit.touchCount == atoms.count` eşitliğini
            // meşru bir yolda bozuyordu.
            let reason: DropReason =
                effect.evidenceStateAfter == .detached
                    ? .droppedOnDetach : .deletedBeforeCommit
            for atom in s.pending {
                s.dropped.append(.init(atom: atom, reason: reason,
                                       actionID: action.actionID))
            }
            s.pending.removeAll()
        case .restoreToken:
            restore(effect, action: action, to: &s)
        }
    }

    /// Geri açma: token yeniden **açık** hâle gelir.
    ///
    /// **Divergence set ETMEZ**: geri açma hizalamayı tam olarak eski hâline
    /// döndürüyor — aynı dokunmalar, aynı cursor. Sapma varsa geri açmadan
    /// değil, ondan **önce** olan bir şeyden gelir (hizasız bir silme kanıtı
    /// koparırsa oradan).
    private static func restore(_ effect: DestructiveEffect,
                                action: CanonicalSession.Action,
                                to s: inout State) {
        guard let id = effect.restoredToken else {
            s.violations.append(.init(
                kind: .unknownFact, actionID: action.actionID,
                detail: "restoreToken hangi token'ı açtığını söylemiyor"))
            s.unverifiable.append(action.actionID)
            return
        }
        guard let index = s.tokens.lastIndex(where: { $0.tokenID == id }) else {
            s.violations.append(.init(
                kind: .restoreOfUnknownToken, actionID: action.actionID,
                detail: "token \(id.raw) kapalı token'lar arasında yok"))
            return
        }
        guard !s.tokens[index].invalidated else {
            s.violations.append(.init(
                kind: .restoreOfInvalidatedToken, actionID: action.actionID,
                detail: "token \(id.raw) zaten geçersiz kılınmıştı"))
            return
        }
        // **En son kapanan token olmak zorunda.** `restorePreviousWord` yalnız
        // `history.last`'ı açabiliyor; daha eskisini açan bir kayıt üretimde
        // imkânsız. Sessizce uygulamak araya giren token'ları kapalı bırakıp
        // cursor'ı onların önüne taşıyordu.
        guard index == s.tokens.count - 1 else {
            s.violations.append(.init(
                kind: .targetIsNotTheNewestToken, actionID: action.actionID,
                detail: "token \(id.raw) en son kapanan değil"
                    + " (\(s.tokens.count - 1 - index) token daha yeni)"))
            return
        }
        let token = s.tokens.remove(at: index)
        s.pending = token.atoms
        s.cursor = token.cursorBefore
    }

    private static func applyDeletions(_ effect: DestructiveEffect,
                                       action: CanonicalSession.Action,
                                       to s: inout State) {
        // Cursor **eylem başına bir kez** geri alınır: bir `deleted` listesinde
        // birden çok `removedToken` varsa tam silinen **en eski** token'ınki.
        // Öğe başına geri alım, `wi-fi ` gibi tek çağrıda iki token silen
        // durumlarda cursor'ı iki kez geriye taşırdı.
        var rollbackTarget: Int?
        var setsDivergence = false

        for span in effect.deleted {
            switch span {
            case let .editedToken(id):
                // Token'ın **bir kısmı** silindi; kalanı belgede duruyor.
                // Cursor geri alınmaz — yeniden yazılan harfler aynı hedefe
                // gidiyor.
                guard let i = s.tokens.lastIndex(where: { $0.tokenID == id }) else {
                    s.violations.append(.init(
                        kind: .deleteOfUnknownToken, actionID: action.actionID,
                        detail: "editedToken \(id.raw) bilinmiyor"))
                    setsDivergence = true
                    continue
                }
                s.tokens[i].invalidated = true
                // §2.1: `.editedToken` **sapma başlatır**. Cursor geri
                // alınmıyor (belgede token'ın kalanı duruyor) ama commit
                // edilen metin artık belgedekinden farklı — o token'ın hedefe
                // eşlemesi kanıtlanamaz hâle geldi.
                //
                // `.removedToken`'dan farkı cursor'da: orada tam silme
                // kanıtlandığı için `cursorBefore`'a dönülüp hiza korunabiliyor.
                setsDivergence = true

            case let .removedToken(id):
                guard let i = s.tokens.lastIndex(where: { $0.tokenID == id }) else {
                    s.violations.append(.init(
                        kind: .deleteOfUnknownToken, actionID: action.actionID,
                        detail: "removedToken \(id.raw) bilinmiyor"))
                    // Cursor'ı geri alamıyoruz: hizalama bozuldu.
                    setsDivergence = true
                    continue
                }
                s.tokens[i].invalidated = true
                rollbackTarget = min(rollbackTarget ?? Int.max,
                                     s.tokens[i].cursorBefore)

            case .separator:
                // Ayırıcı silmek hizayı **bozmuyor**: cursor ilerlemiyor ve
                // belge yüzeyi zaten mutasyonlardan yeniden kuruluyor.
                // Koşulsuz sapma kuralı burada her ayırıcı silmede yanlış
                // pozitif üretiyordu.
                break

            case .unattributed:
                // Ne silindiği doğrulanamıyor → bu noktadan sonraki token'lar
                // hedefe bağlanamaz.
                setsDivergence = true
            }
        }

        if let target = rollbackTarget { s.cursor = target }
        if setsDivergence { s.diverged = true }
    }
}
