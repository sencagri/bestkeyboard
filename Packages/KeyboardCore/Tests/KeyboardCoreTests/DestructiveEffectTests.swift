import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Yıkıcı olguların **tam** değeri — plan v8 §2.1 tablosu.
///
/// ## Neden ayrı bir suite
///
/// Mevcut silme testlerinin hepsi `Deletion.outcome`'a ya da belge metnine
/// bakıyordu; `effect` alanı **atılıyordu**. Sonuç: 179 test yeşilken kayda
/// yazılan olgular yanlış olabiliyordu — boş belgede silme "bir şey silindi"
/// diye, ayırıcı silme "atfedilemez" diye kaydediliyordu. Burada her satır
/// `DestructiveEffect`'in **tamamını** karşılaştırıyor.
@Suite("Yıkıcı olgu tablosu")
struct DestructiveEffectTests {

    /// Yalnız sona yazan belge — replay'in kullandığı tampon.
    private typealias Doc = RecordingTestSupport.Doc

    private func type(_ word: String, _ s: inout ComposingSession, _ doc: Doc) {
        for (i, ch) in word.enumerated() {
            _ = s.insertLetter(ch, touch: .init(down: .init(x: Double(i) * 0.1,
                                                            y: 0.5),
                                                timestamp: Double(i)),
                               into: doc)
        }
    }

    /// Bir token yazıp kapatır; kimliğini döndürür.
    @discardableResult
    private func commit(_ word: String, separator: String = " ",
                        _ s: inout ComposingSession, _ doc: Doc) -> TokenID {
        let id = s.pendingTokenID
        type(word, &s, doc)
        _ = s.finishToken(separator: separator, into: doc)
        return id
    }

    // MARK: - Boş belge

    /// Boş belgede `deleteBackward` no-op. "Bir şey silindi" yazmak sahte
    /// olgudur ve reducer'da kalıcı, sebepsiz bir sapma üretirdi.
    @Test("Boş belgede tap hiçbir şey silmiyor")
    func tapOnEmptyDocument() {
        var s = ComposingSession()
        let doc = Doc()
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [],
                                  evidenceStateAfter: .cleared)))
    }

    @Test("Boş belgede repeat hiçbir şey silmiyor")
    func repeatOnEmptyDocument() {
        var s = ComposingSession()
        let doc = Doc()
        let d = s.backspaceRepeat(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [],
                                  evidenceStateAfter: .cleared)))
    }

    @Test("Boş belgede deleteWord hiçbir şey silmiyor")
    func deleteWordOnEmptyDocument() {
        var s = ComposingSession()
        let doc = Doc()
        let d = s.deleteWordBackward(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [],
                                  evidenceStateAfter: .cleared)))
    }

    // MARK: - Açık token

    @Test("Hizalı yüzeyde tek harf silme")
    func alignedSurfaceDropsOneTouch() {
        var s = ComposingSession()
        let doc = Doc()
        type("ev", &s, doc)
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .dropLast, deleted: [],
                                  evidenceStateAfter: .attached)))
    }

    @Test("Token'ın son harfi silinince kanıt temizleniyor")
    func lastCharacterClearsEvidence() {
        var s = ComposingSession()
        let doc = Doc()
        type("e", &s, doc)
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .dropLast, deleted: [],
                                  evidenceStateAfter: .cleared)))
    }

    /// Ayrışmış yüzeyde **ilk** silme kanıtı koparıyor ve bekleyen dokunmaların
    /// tamamı düşüyor.
    @Test("İlk kopuş bekleyenleri düşürüyor")
    func firstDetachDropsPending() {
        var s = ComposingSession()
        let doc = Doc()
        type("ev", &s, doc)
        _ = s.insertShiftedLetter("a", display: "AA", touch: .init(down: .init(x: 0.3, y: 0.5)),
                                  into: doc)   // display literal'den uzun → ayrışık
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .dropAll, deleted: [],
                                  evidenceStateAfter: .detached)))
    }

    /// **Codex bulgusu.** İkinci silmede düşecek bekleyen kanıt yok; `.dropAll`
    /// yazmak olmamış bir kaybı olmuş gibi kaydetmek ve reducer'da var olmayan
    /// dokunmaları aramak olurdu.
    @Test("Zaten kopukken ikinci silme hiçbir şey düşürmüyor")
    func secondDeleteWhileDetachedDropsNothing() {
        var s = ComposingSession()
        let doc = Doc()
        type("ev", &s, doc)
        _ = s.insertShiftedLetter("a", display: "AA", touch: .init(down: .init(x: 0.3, y: 0.5)),
                                  into: doc)
        _ = s.backspaceTap(into: doc)                       // ilk kopuş
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [],
                                  evidenceStateAfter: .detached)))
    }

    /// Açık token'ın tamamı silindi; commit edilmiş bir token'a dokunulmadı.
    @Test("deleteWord açık token'ı silince atıf boş")
    func deleteWordOnComposingToken() {
        var s = ComposingSession()
        let doc = Doc()
        type("ev", &s, doc)
        let d = s.deleteWordBackward(into: doc)
        #expect(d.effect == .known(.init(pending: .dropAll, deleted: [],
                                  evidenceStateAfter: .cleared)))
    }

    // MARK: - Sınırda silme

    /// Geri açma yıkıcı bir silme değil; silinen ayırıcı `DocumentMutation`
    /// olarak zaten kayıtta.
    @Test("Sınırda tap token'ı geri açıyor")
    func tapAtBoundaryRestores() {
        var s = ComposingSession()
        let doc = Doc()
        let id = commit("kalem", &s, doc)
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .restoreToken, deleted: [],
                                  evidenceStateAfter: .attached,
                                  restoredToken: id)))
    }

    /// Repeat geri açma **yapmıyor** (kullanıcı toplu siliyor, düzenlemiyor);
    /// silinen şey ayırıcı ve `.unattributed` değil.
    @Test("Sınırda repeat ayırıcıyı siliyor")
    func repeatAtBoundaryDeletesSeparator() {
        var s = ComposingSession()
        let doc = Doc()
        commit("kalem", &s, doc)
        let d = s.backspaceRepeat(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [.separator],
                                  evidenceStateAfter: .cleared)))
    }

    /// Ayırıcı gittikten sonraki silme token'ın **içine** giriyor: kalanı
    /// belgede durduğu için `editedToken`.
    @Test("Ayırıcıdan sonraki repeat token'ı kısmen siliyor")
    func repeatAfterSeparatorEditsToken() {
        var s = ComposingSession()
        let doc = Doc()
        let id = commit("kalem", &s, doc)
        _ = s.backspaceRepeat(into: doc)
        let d = s.backspaceRepeat(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [.editedToken(id)],
                                  evidenceStateAfter: .cleared)))
    }

    @Test("deleteWord kelimeyi ve ayırıcısını siliyor")
    func deleteWordRemovesTokenAndSeparator() {
        var s = ComposingSession()
        let doc = Doc()
        commit("kalem", &s, doc)
        let ev = commit("ev", &s, doc)
        let d = s.deleteWordBackward(into: doc)
        #expect(d.effect == .known(.init(pending: .none,
                                  deleted: [.removedToken(ev), .separator],
                                  evidenceStateAfter: .cleared)))
    }

    /// **Codex bulgusu.** `deleteWordBackward` boşluğa kadar olan **tüm**
    /// non-whitespace diziyi siliyor; tokenizer'ın iki token saydığı `wi-fi `
    /// tek çağrıda ikisini ve aradaki sembolü birden yiyor. Tek token
    /// atfedebilen eski kod burada bilgi kaybediyordu.
    @Test("Tek çağrıda iki token silinince ikisi de atfediliyor")
    func deleteWordAttributesEveryToken() {
        var s = ComposingSession()
        let doc = Doc()
        let wi = s.pendingTokenID
        type("wi", &s, doc)
        _ = s.finishToken(separator: "", into: doc)
        s.insertSeparator("-", into: doc)
        let fi = s.pendingTokenID
        type("fi", &s, doc)
        _ = s.finishToken(separator: " ", into: doc)
        #expect(doc.text == "wi-fi ")

        let d = s.deleteWordBackward(into: doc)
        #expect(doc.text == "")
        #expect(d.effect == .known(.init(pending: .none,
                                  deleted: [.removedToken(wi), .separator,
                                            .removedToken(fi), .separator],
                                  evidenceStateAfter: .cleared)))
    }

    /// Atıf `history`'ye dayanıyordu; `history` ise **ilk silmede atılıyor**
    /// (tepesindeki kelime artık belgede olduğundan farklı olabilir). Bu yüzden
    /// eski kodda **ikinci** `deleteWord` atfını tamamen kaybediyordu — üstelik
    /// yığın sekiz girişle de sınırlı. Defter ikisinden de bağımsız.
    @Test("Art arda silmelerde atıf kaybolmuyor")
    func attributionSurvivesRepeatedDeletes() {
        var s = ComposingSession()
        let doc = Doc()
        var ids: [TokenID] = []
        for i in 0..<(ComposingSession.maxHistoryDepth + 3) {
            ids.append(commit("k\(i)", &s, doc))
        }
        for expected in ids.reversed() {
            let d = s.deleteWordBackward(into: doc)
            #expect(d.effect.value?.deleted == [.removedToken(expected), .separator],
                    "token \(expected.raw) atfı kayboldu")
        }
        #expect(doc.text == "")
    }

    /// Defter yalnız **bizim** yazdığımızı biliyor. Host'un koyduğu metne
    /// uzanan silme kimliksiz — kimlik uydurmak doğrulanmamış bir eşlemeyi
    /// olgu gibi kaydetmek olurdu.
    @Test("Bizim yazmadığımız metnin silinmesi atfedilemez")
    func deletingForeignTextIsUnattributed() {
        var s = ComposingSession()
        let doc = Doc()
        doc.hostRewrites(to: "önceden burada")
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [.unattributed],
                                  evidenceStateAfter: .cleared)))
    }

    /// Host belgeyi bizden habersiz değiştirdiyse defter neyi anlattığını
    /// bilmiyor; atıf `.unattributed`'a düşmeli, eski kimliği yazmamalı.
    @Test("Host yeniden yazınca defter kimlik uydurmuyor")
    func hostRewriteInvalidatesAttribution() {
        var s = ComposingSession()
        let doc = Doc()
        commit("kalem", &s, doc)
        doc.hostRewrites(to: "bambaşka metin")
        let d = s.backspaceTap(into: doc)
        #expect(d.effect == .known(.init(pending: .none, deleted: [.unattributed],
                                  evidenceStateAfter: .cleared)))
    }

    /// **Codex karşı örneği.** Belgede zaten `"a "` varken klavye ikinci bir
    /// `"a "` yazıyor, sonra imleç **ilk** `"a "`nın sonuna taşınıyor. Sonek
    /// kontrolü, uyum kontrolü ve tam-token kontrolü üçü de geçiyordu; defter
    /// yabancı metni kendi token'ı sanıp `restoreToken(0)` yazıyordu.
    ///
    /// Sonek eşleşmesi konumu **kanıtlayamaz**: klavye imleci göremiyor. Tek
    /// dürüst çözüm imlecin oynamış olabileceği her noktada konumsal atfı
    /// bırakmak.
    @Test("İmleç taşınınca yabancı metin kendi token'ımız sanılmıyor")
    func cursorMoveDropsPositionalAttribution() {
        var s = ComposingSession()
        let doc = Doc()
        doc.hostRewrites(to: "a ")                 // bize ait olmayan metin
        commit("a", &s, doc)                       // belge: "a a "
        #expect(doc.text == "a a ")

        // İmleç ilk "a "nın sonuna taşındı: bağlam yine "a " görünüyor.
        doc.hostRewrites(to: "a ")
        s.invalidatePositionalAttribution()         // VC'nin seçim geri çağrısı

        let d = s.backspaceTap(into: doc)
        // `.none` burada `Optional.none` diye çözülüyor; tip açıkça yazılmalı.
        #expect(d.effect.value?.pending == DestructiveEffect.PendingMutation.none,
                "geri açma OLMAMALI")
        #expect(d.effect.value?.deleted == [.unattributed],
                "yabancı metne kimlik yazılamaz")
        #expect(d.effect.value?.restoredToken == nil)
    }

    /// **Codex bulgusu.** Bağlamı gizleyen ama `deleteBackward`ı çalışan bir
    /// host'ta (güvenli alan) gerçek bir karakter siliniyor ve kayıt
    /// "hiçbir şey silinmedi" diyordu. Gözlenemeyen olgu `.unknown`.
    @Test("Gözlenemeyen bağlamda silme olgusu bilinmiyor")
    func unobservableContextYieldsUnknownEffect() {
        final class Blind: DocumentEditor {
            var deletions = 0
            func insertText(_ t: String) {}
            func deleteBackward() { deletions += 1 }
            var contextBeforeInput: String? { nil }
            var contextAfterInput: String? { nil }
            var selectedText: String? { nil }
        }
        var s = ComposingSession()
        let doc = Blind()
        #expect(s.backspaceTap(into: doc).effect.isUnknown)
        #expect(s.backspaceRepeat(into: doc).effect.isUnknown)
        #expect(s.deleteWordBackward(into: doc).effect.isUnknown)
        #expect(doc.deletions == 2, "tap ve repeat gerçekten sildi")
    }

    /// Satır sonu bir sınır: `deleteWord` ya sınıra kadar siler ya **yalnız**
    /// sınırı. İkisini birden yapmak tek basılı tutuşla önceki satırın sonunu
    /// da yutmak demekti.
    @Test("deleteWord satır sonunu geçmiyor")
    func deleteWordStopsAtNewline() {
        var s = ComposingSession()
        let doc = Doc()
        commit("bir", separator: "\n", &s, doc)
        let d = s.deleteWordBackward(into: doc)
        #expect(doc.text == "bir")
        #expect(d.effect == .known(.init(pending: .none, deleted: [.separator],
                                  evidenceStateAfter: .cleared)))
    }
}
