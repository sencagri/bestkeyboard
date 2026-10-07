import Foundation
import KBRuntime

extension SessionValidator {

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
    static func validateLabels(_ session: CanonicalSession) -> [Finding] {
        var out: [Finding] = []
        // `strong` ve `protocol` yalnız hedefli protokolde meşru (§12.5).
        let targeted = session.isTargetedProtocol
        // Sapma **eylem sırasına göre** ve **reducer'ın kuralıyla** izleniyor:
        // nihai `state.diverged` sapmadan önceki token'ları da suçlardı.
        //
        // Kural eskiden burada yeniden yazılmıştı ve reducer'dan ayrışmıştı:
        // bilinmeyen bir yıkıcı etki ya da var olmayan bir token'ı silen etki
        // reducer'da sapma başlatıyor, buradaki kopyada başlatmıyordu. Yazıcı
        // etiketi reducer'ın `diverged`'ı ile kuruyor; doğrulayan başka bir
        // kurala bakarsa yazıcıyı değil kendi kopyasını doğrular.
        var fold = SessionEventReducer.State()
        let touches = session.terminalTouches

        for a in session.actions {
            // Etiket action **öncesindeki** duruma göre kuruldu (yazıcı katlamayı
            // eylemden sonra yapıyor); durum bu yüzden kontrolden sonra
            // ilerletiliyor.
            let diverged = fold.diverged
            SessionEventReducer.applyIncrementally(a, to: &fold, touches: touches)
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
                let expected = CanonicalSession.Action.Commit.Label
                    .target(in: tokens, cursor: cursor)
                if label.targetWord != expected {
                    fail("targetWord=\(label.targetWord ?? "yok") ama cursor"
                         + " \(cursor) → \(expected ?? "hedef dışı")")
                }
            }

            // `matchesTarget` türetilmiş bir olgu: literal ile hedefin Türkçe
            // küçük harf karşılaştırması.
            let expectedMatch = label.targetWord.map {
                CanonicalSession.Action.Commit.Label.literal(c.literal, matches: $0)
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

    /// Kayıtlı sapma bayrağı ile türetilen aynı olmalı.
    ///
    /// Yalnız v2 kayıtlarında sınanabiliyor: v3 bayrağı ayrıca yazmıyor, çünkü
    /// `effect` olgularından **kesin** olarak katlanıyor ve iki yerde tutulan
    /// bir olgu sessizce ayrışır.
    static func validateDivergence(_ session: CanonicalSession,
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
