import Foundation
import KBRuntime

extension SessionValidator {

    // MARK: - §2.1 operasyon × etki tablosu

    /// Kaydedilen etkinin, o operasyon için **tabloda** olup olmadığı.
    ///
    /// Reducer bu bileşimleri katlıyor ama katlarken sormuyor: tabloda olmayan
    /// bir satır (ör. `space` ile `restoreToken`) sessizce katlanıp anlamsız
    /// bir duruma yol açıyordu. Yazıcı hatası burada görünmeli.
    static func validateEffectTable(_ session: CanonicalSession)
        -> [Finding] {
        var out: [Finding] = []
        for a in session.actions {
            guard let e = a.effect.value else { continue }
            let ok: Bool
            switch a.kind {
            case .space, .symbol, .text, .newline, .suggestionPick:
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
            // Kanonik biçim — üreticinin kuralıyla (`DeletedSpan.canonical`).
            if !DeletedSpan.isCanonical(e.deleted) {
                out.append(.init(kind: .effectNotInTable, actionID: a.actionID,
                                 detail: "kanonik değil: \(e.deleted)"))
            }
        }
        return out
    }

    /// `backspaceTap`/`backspaceRepeat`'in tablodaki satırları.
    static func tapRowIsValid(_ e: DestructiveEffect) -> Bool {
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
            // **Koşulsuz `true` değil.** İki meşru aile var ve ikisi de kapalı:
            //
            // (a) Zaten kopuk bir yüzeyde silme: silinen karakter composing
            //     yüzeyine ait, dolayısıyla `deleted` **boş**. Yüzey duruyorsa
            //     kanıt `.detached`, boşaldıysa `.cleared`.
            // (b) Composing yokken silme: kanıt daima `.cleared` ve tek
            //     dokunuş **tek grapheme** siliyor, yani en fazla bir span.
            //
            // `.attached` + `.none` **üretilemez**: hizalı silme `.dropLast`
            // veriyor, kopuk yüzeyde ise `detachEvidence()` koşuyor. Koşulsuz
            // kabul, tabloda hiç olmayan bir satırı geçiriyordu — örneğin
            // `pending: .none, deleted: [.removedToken(0)], after: .attached`;
            // reducer onu katlayıp token'ı geçersiz kılıyor ve cursor'ı geri
            // alıyordu.
            switch e.evidenceStateAfter {
            case .detached:
                return e.deleted.isEmpty
            case .cleared:
                return e.deleted.count <= 1
            case .attached:
                return false
            }
        }
    }
}
