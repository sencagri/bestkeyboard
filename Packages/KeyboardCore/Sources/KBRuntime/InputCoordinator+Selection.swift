import KBGeometry
import KBSpatial

// MARK: - Seçim

extension InputCoordinator {

    /// Host'ta bir metin seçildi (ya da seçim kalktı).
    ///
    /// Önce **gerçek** kanıt aranır: kelimeyi bu oturumda biz yazdıysak ve
    /// konumu doğrulanıyorsa kullanıcının kendi dokunmaları kullanılır.
    /// Bulunamazsa yüzeyden **türetilmiş** kanıtla yine öneri üretilir.
    ///
    /// - Returns: seçim düzenleme kipine girildiyse seçilen yüzey.
    @discardableResult
    public mutating func handleSelection(_ selected: String?,
                                         into editor: DocumentEditor) -> String? {
        // Bu geri çağrı **imlecin oynamış olabileceği** her durumda geliyor
        // (seçim, dokunmayla imleç taşıma, host müdahalesi). Defter belgenin
        // **sonu** hakkında konuşuyor; imleç başka bir yere gittiyse cümlesi
        // yanlış bir yer hakkında olur.
        //
        // `agreesWithHost`'un yeterli olmadığı somut durum: belgede zaten
        // `"a "` varken klavye ikinci bir `"a "` yazıyor ve imleç **ilk**
        // `"a "`nın sonuna taşınıyor. Sonek kontrolü geçiyor, uyum kontrolü
        // geçiyor, ama defter yabancı metni kendi token'ı sanıyor.
        session.invalidatePositionalAttribution()
        // İmleç oynamış olabilir: önündeki kelime artık bizim kapattığımız
        // token olmayabilir. Bağlam **bilinmiyor**a düşüyor.
        forgetContext()
        let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let sel = selected, !trimmed.isEmpty {
            apply(session.beginEditingSelection(sel, into: editor))

            // Türetilmiş yol yalnız seçimin **kendisi** tek kelimeyse açılır:
            // kırpılmışla açmak, aday uygulanırken `insertText`'in host'un tüm
            // seçimini (kenar boşlukları dahil) değiştirmesine yol açardı.
            if !session.isEditingSelection, sel == trimmed,
               let ts = layout.centerTouches(for: sel) {
                apply(session.beginEditingSelectionSynthetic(sel, touches: ts))
            }
            return session.isEditingSelection ? sel : nil
        }

        if session.isEditingSelection {
            apply(session.endEditingSelection())
            return nil
        }

        // İmleç taşındıysa hangi karakterlerin bizim token'ımıza ait olduğunu
        // artık bilmiyoruz — ama **ne yazdığımızı** biliyoruz. Geçmiş korunur
        // (§8.4: çift dokunuşun ilk dokunuşu geçmişi siliyordu).
        if !session.agreesWithHost(editor) {
            apply(session.invalidateComposing())
        }
        return nil
    }
}
