import UIKit
import CoreText
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions
import KBFoundation

/// Kısayollar: metin/medya kısayolu, eğik çizgi komutları, uygulama kısayolları ve fontlu yazı.
extension KeyboardViewController {
    // MARK: - Kısayollar

    /// Son kelime `/` ile başlıyorsa adı o önekle başlayan tuşlar.
    private static func slashCommand(before: String, actions: [AIAction]) -> (String, [AIAction])? {
        // Satır sonu da kelimeyi bitiriyor ("abc\n/çe" → "/çe").
        guard let token = before.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0.isNewline }).last,
              token.hasPrefix("/"), !token.dropFirst().contains("/") else { return nil }
        // Aksansız da eşleşsin: "/cevir" → "Çevir".
        let fold = { (s: String) in s.trFolded.replacingOccurrences(of: " ", with: "") }
        let q = fold(String(token.dropFirst()))
        let hits = actions.filter { fold($0.name).hasPrefix(q) }
        return hits.isEmpty ? nil : (String(token), hits)
    }

    func refreshShortcut() {
        activeShortcut = nil
        activeCommands = []
        defer {
            if let s = activeShortcut, s.item.isMedia {
                suggestionBar.setShortcut(s.item.kind == .gif ? "GIF, panoya kopyala" : "Çıkartma, panoya kopyala",
                                          image: shortcutThumb(s.item.output))
            } else {
                suggestionBar.setShortcut(activeShortcut?.item.output)
            }
        }
        guard !fieldIsSecure,
              let before = textDocumentProxy.documentContextBeforeInput else { return }
        // `/çe` → yapay zeka tuşları (tasarım 23). Öneri satırının tamamını
        // alıyor; `refreshUI` adayların yerine bunları koyuyor.
        if let (token, hits) = Self.slashCommand(before: before, actions: settings.aiActions) {
            commandToken = token
            activeCommands = hits
            return
        }
        // Az önce emoji yazıldıysa aynısı ilk yuvada: arka arkaya basıp
        // çoğaltılabilsin (😂😂😂). Tetikleyici boş — hiçbir şey silinmiyor.
        if let last = before.last, Self.isEmoji(last) {
            activeShortcut = ("", TextShortcut(trigger: "", output: String(last)))
            return
        }
        for token in ShortcutLibrary.candidates(before: before) {
            // Öğesi Stüdyo'dan silinmiş çıkartma/GIF kısayolu eşleşmiyor.
            if let hit = ShortcutLibrary.matches(token: token, list: settings.shortcuts)
                .first(where: { !$0.isMedia || shortcutThumb($0.output) != nil }) {
                activeShortcut = (token, hit)
                return
            }
        }
        // Hatırlama aynı yuvayı kullanıyor: yazılan önek → daha önce yazılan
        // tam token (IP, e-posta…). Uygulama yolu da aynı.
        if settings.recallTokens, let raw = ShortcutLibrary.candidates(before: before).first,
           let hit = history.recall(lastToken: raw) {
            activeShortcut = (hit.prefix, TextShortcut(trigger: hit.prefix, output: hit.full, kind: .text))
        }
    }

    /// Emoji olarak **görünen** karakter mi. `isEmoji` rakamlar ve `#` için
    /// de doğru; sunum ya da VS16 şartı onları eliyor.
    private static func isEmoji(_ c: Character) -> Bool {
        let sc = c.unicodeScalars
        return sc.contains { $0.properties.isEmojiPresentation }
            || sc.contains { $0.value == 0xFE0F }
            || (sc.count > 1 && sc.first?.properties.isEmoji == true && !(sc.first?.properties.numericType != nil))
    }

    private func shortcutThumb(_ id: String) -> UIImage? {
        if let t = thumbCache[id] { return t }
        guard let item = MediaStore.item(id: id), let t = MediaStore.thumbnail(item) else { return nil }
        thumbCache[id] = t
        return t
    }

    /// Tetikleyiciyi silip çıktıyı yazar — kayda geçen yoldan: önce token
    /// kapanıyor, sonra her karakter bir `⌫`, sonra çıktı sembol olarak.
    func applyShortcut() {
        guard let s = activeShortcut else { return }
        if s.item.isMedia { applyMediaShortcut(s.trigger, id: s.item.output); return }
        closeComposition()
        activeShortcut = nil
        guard deleteTrailing(s.trigger) else { refreshUI(); return }
        insertAtBoundary(s.item.output)
    }

    /// Çıkartma/GIF kısayolu: tetikleyici silinip öğe panoya konuyor —
    /// iOS klavyenin belgeye resim koymasına izin vermiyor.
    private func applyMediaShortcut(_ trigger: String, id: String) {
        closeComposition()
        activeShortcut = nil
        guard let item = MediaStore.item(id: id), hasFullAccess, MediaStore.copyToPasteboard(item) else {
            refreshUI()
            showToast(CommonText.fullAccess(failed: "Panoya konamadı"))
            return
        }
        clipboard.noteOwnWrite()
        deleteTrailing(trigger)
        afterTokenBoundary()
        updateAutoCapitalization()
        refreshUI()
        showToast(PasteHint.placed)
    }

    /// `/çe` yazılıp öneriden seçildi: kelime (ve önündeki boşluk) siliniyor,
    /// tuş kartta ya da uygulamada çalışıyor.
    func runCommand(_ a: AIAction) {
        closeComposition()
        if deleteTrailing(commandToken) {
            // "metin /çe" → "metin".
            if textDocumentProxy.documentContextBeforeInput?.last == " " { session.perform(.backspaceTap) }
        }
        activeCommands = []
        aiCard.run(command: a)
        refreshUI()
    }

    // MARK: - Uygulama kısayolları

    /// Seçili metin, yoksa panodaki metinle uygulamayı açar.
    ///
    /// Resim adresle taşınamıyor: panodaysa orada kalıyor ve kullanıcıya
    /// "yapıştır" deniyor. Metni `q` almayan uygulamalarda metin de panoya
    /// konuyor.
    func openApp(_ id: String) {
        guard let app = AIApp.byID[id] else { return }
        let imageOnBoard = clipboard.hasImage(allowed: clipboardAllowed)
        var text = textDocumentProxy.selectedText
        if (text ?? "").isEmpty, !imageOnBoard { text = clipboard.string(allowed: clipboardAllowed) }
        let carried = text.flatMap(\.nilIfEmpty)
        if let t = carried, !app.takesText, hasFullAccess { clipboard.put(string: t) }
        guard let url = app.url(text: app.takesText ? carried : nil) else { return }
        guard openURL(url) else {
            showToast(CommonText.fullAccess(open: app.name))
            return
        }
        if imageOnBoard {
            showToast(PasteHint.image(in: app.name))
        } else if carried != nil, !app.takesText {
            showToast(PasteHint.text(in: app.name))
        }
    }

    // MARK: - Fontlu yazı (tasarım 24)

    func toggleFancy() {
        fancy.toggle()
        applyFancy()
    }

    func pickFancyStyle(_ i: Int) {
        fancy.pick(i)
        applyFancy()
    }

    private func applyFancy() {
        suggestionBar.fontsActive = fancy.isOpen
        suggestionBar.showStyles(fancy.samples, selected: fancy.selectedIndex)
        if let s = fancy.style {
            keyboardView.letterTransform = { FancyText.apply(s, to: $0) }
            keyboardView.spaceTitle = FancyTextMode.name(s)
        } else {
            keyboardView.letterTransform = nil
            keyboardView.spaceTitle = nil
        }
        refreshUI()
    }
}
