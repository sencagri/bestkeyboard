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

/// Paneller: açma/kapama, panel kurulumu, pano, emoji ve yapay zeka kartı.
extension KeyboardViewController {
    // MARK: - Paneller
    //
    // Açma/kapama burada **tek** yoldan: önce her panelin kendi kopyası vardı
    // ve hangisinin hangisini kapattığı, hangisinin token'ı kapattığı panelden
    // panele değişiyordu.

    func togglePanel(_ kind: PanelSlot.Kind) {
        let wasOpen = panels.kind == kind
        closePanel()
        if !wasOpen { openPanel(kind) }
    }

    private func openPanel(_ kind: PanelSlot.Kind) {
        // Panel klavyenin üstünü kaplıyor ama **zaten basılı** parmaklar
        // olaylarını almaya devam ediyor: ⌫'yi basılı tutarken ikinci parmakla
        // ⚙︎'ye basmak panelin arkasında silmeyi sürdürüyordu.
        keyboardView.cancelInteraction()
        // Yazılmakta olan token burada kapanıyor. Ayar geometriyi
        // değiştirebilir ve tampondaki dokunmalar eski normalize uzayda
        // kaydedilmiş olur; emoji ve pano girişi de token sınırı.
        closeComposition()
        selectionNote = nil
        // Token kapandı: bekleyen profil geçişi ve kalibrasyon kaydı burada
        // karşılanmalı. Yoksa composition sırasında cihaz döndürülüp panel
        // açıldığında `pendingProfile` asılı kalıyor ve panelden sonraki ilk
        // kelime **eski** yönelimin kalibrasyonuyla işleniyordu.
        afterTokenBoundary()

        let panel: OverlayPanel
        var bottom = view.bottomAnchor
        switch kind {
        case .settings: panel = makeSettingsPanel()
        case .emoji: panel = makeEmojiPanel()
        case .clipboard:
            checkPasteboard()
            panel = makeClipboardPanel()
        case .media: panel = makeMediaPanel()
        case .ai:
            panel = aiCard.makePanel(theme: resolvedTheme)
            // Kart klavyenin **üstünde**; klavye yukarı uzuyor (`aiCardHeightChanged`).
            bottom = suggestionBar.topAnchor
        }
        panels.show(kind, panel, bottom: bottom)
        if kind == .ai {
            suggestionBar.aiActive = true
            aiCard.didOpen()
        }
        overlayPanelDidChange(panel)
        refreshUI()
    }

    /// - Parameter byUser: kullanıcı mı kapattı (klavye gizlenince `false`).
    func closePanel(byUser: Bool = true) {
        guard let kind = panels.close() else { return }
        switch kind {
        case .settings:
            // Bekleyen ağır kurulum burada kesinleşiyor: panel kapanır kapanmaz
            // yazılabiliyor ve o an decoder yeni geometriyle kurulmuş olmalı.
            rebuildModel()
        case .ai:
            aiCard.didClose(byUser: byUser)
            suggestionBar.aiActive = false
            suggestionBarTop.constant = 0
        case .emoji, .clipboard, .media: break
        }
        overlayPanelDidChange(nil)
        refreshUI()
    }

    private func makeSettingsPanel() -> KeyboardSettingsPanel {
        let p = KeyboardSettingsPanel(
            settings: settings,
            theme: resolvedTheme,
            showsGlobe: needsInputModeSwitchKey,
            // Liste **motordan** okunuyor, diskten değil: kullanıcı o an
            // klavyenin bildiği kelimeleri görmeli. Kaydedici bozuksa yedek
            // yolun sözlüğü de aynı dosyadan yüklendi.
            personalWords: session.personalWords)
        p.onChange = { [weak self] s in self?.apply(settings: s) }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onCapture = { [weak self] in
            self?.closePanel()
            self?.captureSlice()
        }
        p.onDismissKeyboard = { [weak self] in self?.dismissWithPanels() }
        p.onOpenApp = { [weak self] in
            guard let self, !self.openHome() else { return }
            self.showToast(CommonText.fullAccess(open: CommonText.app))
        }
        p.onForgetPersonal = { [weak self] word in self?.session.forgetPersonal(word) }
        p.onImportPersonal = { [weak self] in
            self?.importPersonalFromField() ?? ([], [], "klavye hazır değil")
        }
        return p
    }

    private func makeEmojiPanel() -> EmojiPanel {
        let p = EmojiPanel(theme: resolvedTheme, recents: emojiRecents)
        p.onPick = { [weak self] emoji in self?.insertEmoji(emoji) }
        p.onBackspace = { [weak self] in self?.emojiBackspace() }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onClipboard = { [weak self] in self?.togglePanel(.clipboard) }
        p.onMedia = { [weak self] in self?.togglePanel(.media) }
        return p
    }

    private func makeClipboardPanel() -> ClipboardPanel {
        let p = ClipboardPanel(items: clipboard.store.items, theme: resolvedTheme)
        p.onPickText = { [weak self] t in
            self?.closePanel()
            self?.insertAtBoundary(t)
        }
        p.onPickImage = { [weak self] name in
            guard let self, let image = ClipboardStore.image(named: name) else { return }
            self.clipboard.put(image: image)
            self.panels.current(ClipboardPanel.self)?.flash(PasteHint.image())
        }
        p.onClear = { [weak self] in self?.clipboard.clear() }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onEmoji = { [weak self] in self?.togglePanel(.emoji) }
        return p
    }

    private func makeMediaPanel() -> MediaPanel {
        let p = MediaPanel(theme: resolvedTheme)
        p.onCopied = { [weak self] in
            // Kendi koyduğumuz panoyu geçmişe almayalım.
            self?.clipboard.noteOwnWrite()
            self?.showToast(PasteHint.copied)
        }
        p.onClose = { [weak self] in self?.closePanel() }
        p.onEmoji = { [weak self] in self?.togglePanel(.emoji) }
        return p
    }

    /// `dismissKeyboard()` uzantının kendi kapanma yolu; host'a "işim bitti"
    /// demenin desteklenen tek biçimi. Açık panel önce kapanıyor: panel
    /// `view`'ın alt görünümü ve klavye kapanınca ekranda kalmıyor ama bir
    /// sonraki açılışta **açık** geliyordu.
    func dismissWithPanels() {
        closePanel()
        dismissKeyboard()
    }

    /// Uygulamanın ana ekranı (Tam Erişim gerekli).
    func openHome() -> Bool {
        DeepLink.url(.home).map { openURL($0) } ?? false
    }

    /// Uzantıdan adres açmak. iOS klavyeye `extensionContext.open` vermiyor;
    /// yanıtlayıcı zincirinde `UIApplication`'a ulaşıp onun `open`'ı
    /// çağrılıyor. Yalnız Tam Erişimle çalışıyor.
    @discardableResult
    func openURL(_ url: URL) -> Bool { bkOpenURL(url) }

    // MARK: - Pano (`ClipboardWatcher`)

    func checkPasteboard() {
        clipboard.check(allowed: clipboardAllowed)
    }

    func refreshClipChip() {
        let chip = session.isComposing ? nil : clipboard.chip
        suggestionBar.showClip(image: chip?.image, text: chip?.text)
    }

    func useRecentClip() {
        guard let c = clipboard.chip else { return }
        if c.image != nil {
            showToast(PasteHint.image())
        } else if case let .text(t)? = clipboard.store.items.first {
            insertAtBoundary(t)
        }
        clipboard.consumeRecent()
        refreshClipChip()
    }

    // MARK: - Bilgi balonu

    /// Kısa bilgi balonu — klavyenin üstünde.
    func showToast(_ text: String) { toast.show(text, theme: resolvedTheme) }
    // MARK: - Emoji

    /// Emoji **sembol yolundan** giriyor.
    ///
    /// Doğrudan `textDocumentProxy.insertText` çağırmak kaydın görmediği bir
    /// mutasyon üretirdi (§12.6) ve defter belgeyle ayrışırdı. Sembolle aynı
    /// yol olması ayrıca doğru semantiği veriyor: emoji bir **token sınırı**,
    /// kod çözmeye girmiyor ve düzeltme denenmiyor. Güvenli alanda da
    /// yazılabilmeli; `perform` tamponu zaten düşürüyor.
    private func insertEmoji(_ emoji: String) {
        insertAtBoundary(emoji)
        if emojiRecents.use(emoji) {
            EmojiRecentsStore.save(emojiRecents)
            panels.current(EmojiPanel.self)?.update(recents: emojiRecents)
        }
    }

    private func emojiBackspace() {
        session.perform(.backspaceTap)
        shift.didInterruptChain()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Örtü panel açıldı ya da kapandı — erişilebilirlik tarafı.
    ///
    /// ## Panel klavyeyi görsel olarak kapatıyor, ekran okuyucu için kapatmıyordu
    ///
    /// `cancelInteraction()` **parmakları** kesiyor: panel açılırken basılı
    /// duran bir tuş arkada silmeye devam ediyordu ve o düzeltilmişti. Ama
    /// erişilebilirlik etkinleştirmesi parmak değil — panelin arkasındaki tuşlar
    /// erişilebilirlik ağacında duruyor ve VoiceOver kullanıcısı sağa kaydırarak
    /// **görünmeyen** bir klavyeye ulaşabiliyor.
    ///
    /// Bu kusur §8.9'dan önce zararsızdı: tuşlar okunabiliyor ama
    /// etkinleştirilemiyordu, yani en kötü ihtimalle gürültüydü. Etkinleştirme
    /// bağlanınca **gerçek** oldu — panel açıkken görünmeyen bir tuşa basıp
    /// belgeye harf yazmak. Yeni bir özellik eski bir kusuru işler hâle
    /// getirdi; ikisini birlikte kapatmak zorunluydu.
    ///
    /// İki savunma, ayrı gerekçelerle:
    ///
    /// 1. `accessibilityViewIsModal` — panelin kardeşlerini ağaçtan düşürüyor.
    ///    Doğru ve genel çözüm bu; gezinme de panelin içinde kalıyor.
    /// 2. `allowsAccessibilityActivation` — tuş yüzeyinin kendi kapısı.
    ///    Modalliğin doğru uygulanmasına bel bağlamamak için: `cancelInteraction`
    ///    da aynı sebeple var, ve o hatanın bedeli zaten bir kez ödendi.
    ///
    /// Ayrıca `.screenChanged` gönderiliyor: bildirimsiz açılan panelde odak
    /// ⚙︎ düğmesinde kalıyor ve kullanıcı bir panelin açıldığını hiç duymuyor.
    private func overlayPanelDidChange(_ panel: UIView?) {
        panel?.accessibilityViewIsModal = true
        keyboardView.allowsAccessibilityActivation = (panel == nil)
        suggestionBar.accessibilityElementsHidden = panel != nil
        guard UIAccessibility.isVoiceOverRunning else { return }
        // Argüman odağın **nereye** gideceğini söylüyor: panel açılırken panele,
        // kapanırken tuş yüzeyine. `nil` göndermek odağı ekranın başına atardı.
        UIAccessibility.post(notification: .screenChanged,
                             argument: panel ?? keyboardView)
    }
}

/// Yapay zeka kartının klavyeye açılan penceresi.
extension KeyboardViewController: AICardHost {
    var isOnScreen: Bool { view.window != nil }
    var clipboardAllowed: Bool { hasFullAccess && !fieldIsSecure }
    var aiActions: [AIAction] { settings.aiActions }

    func openAICard() {
        guard panels.kind != .ai else { return }
        closePanel()
        openPanel(.ai)
    }

    func closeAICard() {
        guard panels.kind == .ai else { return }
        closePanel()
    }

    /// Kart açılınca klavye **yukarı** uzuyor: çubuğun üstü aşağı itiliyor,
    /// giriş görünümü kartın boyu kadar büyüyor.
    func aiCardHeightChanged() {
        guard let p = panels.current(AIPanel.self) else { return }
        let h = ceil(p.fittingHeight(width: view.bounds.width))
        guard abs(suggestionBarTop.constant - h) > 0.5 else { return }
        suggestionBarTop.constant = h
        view.setNeedsLayout()
    }

    /// Kart belgeye proxy'den yazdı — kaydın anlatmadığı bir değişiklik:
    /// işaretlenip deneme devrediliyor, sonraki kayıtlı eylem bu farkı kendi
    /// mutasyonuna katmasın.
    func didEditFromCard() {
        session.editedOutsideLog()
        afterTokenBoundary()
        updateAutoCapitalization()
    }
}
