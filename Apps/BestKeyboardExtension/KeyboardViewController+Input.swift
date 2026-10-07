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

/// Girdi: tuş işleme, token sınırı adımları, yazma geçmişi, dikte, imleç sürükleme ve host uzlaştırması.
extension KeyboardViewController {
    // MARK: - Ortak adımlar

    /// Yazılmakta olan token kapanıyor; kayda girmeyen durum değişikliği
    /// denemeyi kapatıyor. Klavye belgeye kendi yolundan başka bir şey
    /// yazmadan (panel, kısayol, kart, dikte) önce **hep** bu.
    func closeComposition() {
        session.closeComposition()
    }

    /// Token sınırında bir ekleme oldu (emoji, pano, kısayol, tahmin):
    /// çift dokunuş zinciri kesiliyor, sınır işleri ve otomatik büyük harf
    /// yeniden, çubuk tazeleniyor.
    private func didInsertAtBoundary() {
        shift.didInterruptChain()
        afterTokenBoundary()
        session.startPendingIfAtBoundary()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Metin kayda geçen yoldan (sembol: token sınırı, düzeltme yok) giriyor —
    /// emoji, pano, dikte ve kart sonucu aynı yol.
    func insertAtBoundary(_ text: String) {
        session.perform(Self.boundaryCommand(text))
        didInsertAtBoundary()
    }

    /// Tek karakter sembol olarak (bağlam korunuyor, emoji gibi); daha uzun
    /// metin tek bir metin eylemi — kayıt sembolde tek karakter istiyor ve
    /// pano/dikte/kısayol metni önce reddediliyordu.
    private static func boundaryCommand(_ text: String) -> ReplayCommand {
        text.count == 1 ? .symbol(text) : .text(text)
    }

    /// İmleçten hemen önce `suffix` duruyorsa onu siler (kayda geçen ⌫'lerle).
    /// Belgede gerçekten o metin duruyor mu yeniden bakılıyor — bayat bir
    /// öneriyle başka bir şeyi silmemek için.
    @discardableResult
    func deleteTrailing(_ suffix: String) -> Bool {
        guard textDocumentProxy.documentContextBeforeInput?.hasSuffix(suffix) == true else { return false }
        for _ in 0..<suffix.count { session.perform(.backspaceTap) }
        return true
    }

    // MARK: - Yazma geçmişi (sonraki kelime, hatırlama)

    func observeHistory() {
        guard settings.predictNext || settings.recallTokens, !fieldIsSecure,
              let before = textDocumentProxy.documentContextBeforeInput else { return }
        history.observe(before: before)
    }

    func nextWordPredictions() -> [String] {
        guard settings.predictNext, !fieldIsSecure, !session.isComposing,
              let before = textDocumentProxy.documentContextBeforeInput else { return [] }
        return history.nextWords(before: before)
    }

    /// Tahmin edilen kelime + boşluk — sembol yolundan (kayda geçen bir
    /// token sınırı), sonra boşluk.
    private func insertPredicted(_ word: String) {
        session.perform(Self.boundaryCommand(word))
        session.perform(.space)
        predictedNext = []
        didInsertAtBoundary()
    }

    // MARK: - Sesle yazma

    /// Uygulamanın dikte ekranından gelen metni yazar (`AppGroup.handoffTTL` içinde).
    func consumeDictation() {
        guard let pending = DictationHandoff.pending() else { return }
        // Yazılamayacak durumlarda metin **duruyor**: kullanıcı başka bir alana
        // geçince (süre içinde) yine gelsin. Neden yazılmadığı günlükte.
        if let why = DictationReceiver.blocker(fullAccess: hasFullAccess, secureField: fieldIsSecure,
                                               onScreen: isOnScreen) {
            DictationReceiver.log(pending.text, status: .error, detail: why)
            return
        }
        // Yazılabilir: şimdi atomik sahiplen (okuduğumuzdan sonra gelen yeni metin korunur).
        guard let claimed = DictationHandoff.claim(), !claimed.text.isEmpty else { return }
        guard claimed.isFresh else {
            DictationReceiver.log(claimed.text, status: .error, detail: "\(AppGroup.handoffTTLText)dan eski; yazılmadı.")
            return
        }
        closeComposition()
        let text = claimed.text.spaced(after: textDocumentProxy.documentContextBeforeInput)
        insertAtBoundary(text)
        DictationReceiver.log(claimed.text, status: .ok, detail: "\(text.count) harf yazıldı.")
        showToast("Sesle yazılan eklendi")
    }

    // MARK: - Girdi

    func handle(_ hit: KeyboardView.KeyHit,
                        _ how: KeyboardView.KeyActivation = .touch) {
        // Türetilmiş kanıt yalnız **harf** yolunda anlam taşıyor: rakam, sembol
        // ve işlev tuşları zaten kod çözmeye girmiyor ve hiçbir uzamsal iddiada
        // bulunmuyorlar.
        let synthetic = how == .accessibility
        switch hit {
        case let .letter(index, _) where fancy.style != nil:
            // Fontlu yazı: harf kod çözmeye girmiyor, stilli karakter olarak
            // doğrudan yazılıyor (sembol yolu — token kapanıyor, düzeltme yok).
            let ch = layout.keys[index].char
            let plain = shift.isUppercase ? TurkishText.uppercased(ch) : String(ch)
            selectionNote = nil
            session.perform(Self.boundaryCommand(fancy.styled(plain) ?? plain))
            shift.didEmitLetter()
            syncKeyboardState()
            afterTokenBoundary()
            refreshUI()

        case let .letter(index, point):
            let ch = layout.keys[index].char
            // **Tek saat.** `CFAbsoluteTimeGetCurrent()` duvar saati;
            // `ProductionRecorder.now` (= `systemUptime`) `UITouch.timestamp`
            // ile aynı taban. İkisini karıştırmak kaydın zaman çizgisini çöpe
            // çeviriyordu — kayıt ekranında ölçülmüştü (`t = −806 576 468`) ve
            // uzantıya geçerken aynı hata tekrarlanmıştı.
            let t = TouchSample(down: point, timestamp: ProductionRecorder.now)
            selectionNote = nil
            // Dokunma **komuttan önce** kaydediliyor: harf zarfı onun kimliğine
            // atıf yapıyor.
            // Dokunma **zaten kaydedildi** (`onTouchRecord`); zarf yalnız
            // kimliğine atıf yapıyor. Ayrıca uydurmak, aynı dokunmayı iki kez
            // farklı olgularla yazmak olurdu.
            session.perform(shift.letterCommand(ch),
                            point: point, touchID: synthetic ? nil : session.lastTouchID,
                            at: t.timestamp, synthetic: synthetic)
            shift.didEmitLetter()
            syncKeyboardState()

        // Rakam/sembol kod çözmeye girmez — üst sayı sırası da aynı yoldan
        // geçiyor, yalnız vurgusu ayrı bir katman kümesine gidiyor.
        case let .symbol(ch), let .digit(ch):
            selectionNote = nil
            session.perform(Self.boundaryCommand(fancy.styled(String(ch)) ?? String(ch)))
            shift.didInterruptChain()
            afterTokenBoundary()
            session.startPendingIfAtBoundary()
            updateAutoCapitalization()

        case let .function(fk):
            switch fk {
            case .space:
                session.perform(.space)
                selectionNote = nil
                shift.didInterruptChain()
                afterTokenBoundary()
                session.startPendingIfAtBoundary()
                updateAutoCapitalization()
            case .backspace:
                session.perform(.backspaceTap)
                shift.didInterruptChain()
                // Metin başına silmek ya da cümle sonlandırıcısını silmek
                // otomatik büyük harfi değiştirir; yeniden okunmalı.
                updateAutoCapitalization()
            case .ret:
                session.perform(.newline)
                selectionNote = nil
                afterTokenBoundary()
                updateAutoCapitalization()
            case .globe:
                advanceToNextInputMode()   // kısa dokunma; uzun basma view'da

            case .shift:
                shift.tapShift(at: CACurrentMediaTime())
                syncKeyboardState()

            // Düzlem geçişleri de çift dokunuş zincirini keser: hızlı
            // `shift → 123 → ABC → shift` yanlışlıkla caps-lock açardı.
            case .numbers:
                shift.didInterruptChain()
                keyboardView.plane = .numbers
            case .symbols:
                shift.didInterruptChain()
                keyboardView.plane = .symbols
            case .letters:
                shift.didInterruptChain()
                keyboardView.plane = .letters
                updateAutoCapitalization()

            // Nokta **sembol yoluna** giriyor, kendi dalını açmıyor.
            //
            // `123`'e geçip `.`'ya basmakla harf düzleminden basmak arasında
            // hiçbir fark olmamalı: ikisi de token'ı kapatıyor, ikisi de cümle
            // sonlandırıcı (`endsSentence`) ve ikisi de aynı öğrenme kanıtını
            // üretiyor. Ayrı bir dal açmak o davranışı ikinci bir yerde
            // tekrarlamak, yani ayrışmaya davet olurdu.
            case .period:
                handle(.symbol("."), how)
            }
        }
        refreshUI()
    }

    /// Basılı tutma tekrarı: önce karakter, uzun tutulursa kelime.
    func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit else { return }
        switch stage {
        case .character: session.perform(.backspaceRepeat)
        case .word:      session.perform(.deleteWord)
        }
        updateAutoCapitalization()
        refreshUI()
    }

    func pick(_ word: String) {
        if word.hasPrefix(Self.commandMark),
           let a = activeCommands.first(where: { Self.commandMark + $0.name == word }) {
            runCommand(a)
            return
        }
        if predictedNext.contains(word) { insertPredicted(word); return }
        // Kimlik ve kaynak **motordan**: `id = yüzey` uydurmak genişletmeyi
        // aday seçimi diye kaydediyordu.
        guard let picked = session.suggestion(for: word) else { return }
        session.perform(.suggestionPick(id: picked.id, surface: picked.surface,
                                         origin: picked.origin))
        selectionNote = nil
        // Öneri seçimi de token'ı kapatıyor: boşluk yolundaki iki adım burada
        // da gerekli, yoksa cümle başındaki one-shot shift açık kalıp sonraki
        // kelimeyi de büyük başlatırdı.
        shift.didInterruptChain()
        afterTokenBoundary()
        updateAutoCapitalization()
        refreshUI()
    }

    /// Alan türü literal'i koruyor mu (§8 `θ = ∞`).
    var fieldProtectsLiteral: Bool {
        switch textDocumentProxy.keyboardType {
        case .some(.emailAddress), .some(.URL), .some(.numberPad), .some(.decimalPad):
            return true
        default:
            return false
        }
    }

    /// Shift durumunu görünüme yansıtır.
    private func syncKeyboardState() { keyboardView.show(shift) }

    /// Cümle/kelime başı otomatiği — **token sınırında**.
    ///
    /// Karar metinden okunuyor, sayaçtan değil: host metni bizim bilmediğimiz
    /// bir şekilde değiştirmiş olabilir (§8, tampon spekülatiftir).
    func updateAutoCapitalization() {
        let type: ShiftPolicy.Autocapitalization
        switch textDocumentProxy.autocapitalizationType {
        case .some(.words):         type = .words
        case .some(.sentences):     type = .sentences
        case .some(.allCharacters): type = .allCharacters
        default:                    type = .none
        }
        shift.autoCapitalize(
            ShiftPolicy.shouldCapitalize(context: textDocumentProxy.documentContextBeforeInput,
                                         type: type))
        syncKeyboardState()
    }

    // MARK: - Üretim kaydı

    /// Klavyenin **gerçek** geometrisi.
    ///
    /// Önce sıfır bounds ve daima `portrait` yazılıyordu: landscape'te
    /// `rawX = 700` olan bir dokunma `boundsWidth = 0, portrait` diyen bir
    /// kayda giriyor ve normalize uzay yeniden kurulamıyordu.
    func geometrySnapshot() -> CanonicalSession.Geometry {
        RecordingSnapshot.geometry(layout: layout, keyboard: keyboardView, host: view)
    }

    /// Kullanıcı düğmeye bastı: bellekteki dilim diske düşüyor.
    func captureSlice() {
        // Sonuç **hem** duruma yazılıyor hem duyuruluyor: durum satırı ekran
        // okuyucuya görünmüyor, duyuru da ekranda iz bırakmıyor. İkisi aynı
        // cümleyi iki kanaldan söylüyor.
        func report(_ text: String) {
            suggestionBar.setStatus(text)
            announce(text)
        }
        report(session.capture())
    }

    /// Alan **parola alanı** mı.
    ///
    /// Güvenli alanda hiçbir şey tamponlanmıyor: klavye orada yazılanı belleğe
    /// bile almamalı. Bu bir tercih değil — kayıt özelliğinin var olabilmesinin
    /// koşulu.
    ///
    /// `isSecureTextEntry` `Optional<Bool>`: host söylemiyorsa **güvenli
    /// varsayılıyor** değil, çünkü o zaman çoğu alanda kayıt hiç çalışmazdı.
    /// Söylenmediğinde normal alan sayılıyor; iOS parola alanlarında bunu
    /// bildiriyor.
    var fieldIsSecure: Bool {
        textDocumentProxy.isSecureTextEntry == true
    }

    /// VoiceOver açıldı ya da kapandı — kural oturumda (`voiceOverChanged`).
    @objc func voiceOverStatusChanged() {
        session.voiceOverChanged()
        refreshUI()
    }

    // MARK: - Boşlukta imleç sürükleme

    func beginCursorDrag() {
        cursorDragMoved = false
        cursorDrag = CursorTrackpad(
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            after: textDocumentProxy.documentContextAfterInput ?? "")
    }

    /// - Returns: jest sıfır olmayan bir hareket istediyse `true` — görünüm
    ///   boşluk yazımını buna bakarak bastırıyor.
    func updateCursorDrag(dx: Double, dy: Double, time: TimeInterval) -> Int {
        guard var s = cursorDrag else { return 0 }
        let wasMoving = cursorDragMoved
        let delta = s.update(dx: dx, dy: dy, time: time)
        cursorDrag = s
        guard delta != 0 else { return 0 }
        cursorDragMoved = true

        // İmleç oynamadan **önce** composing kapatılıyor, senkron.
        //
        // Ertelenmiş `readSelection`'a güvenmek yetmiyordu: jest sürerken
        // ikinci bir parmak harf commit edebiliyor ve o harf, seçim geri
        // çağrısı gelmeden hâlâ açık olan eski token'a yazılıyordu.
        // `handleSelection` ayrıca composing'i yalnız `agreesWithHost`
        // başarısızsa kapatıyor — aynı yüzey belgede başka bir yerde de
        // duruyorsa taşınmış imleci ayırt edemez. Koşulsuz kapatmak iki boşluğu
        // birden kapıyor.
        if !wasMoving { session.cursorMoved() }

        // **`withOwnEdit` yok, bilerek.** Kendi düzenlemelerimizi saklamak
        // `textDidChange`'i bastırıyor; burada bastırılmamalı çünkü bağlam,
        // otomatik büyük harf ve adaylar imlecin yeni yerine göre yeniden
        // okunmalı (§8.4).
        textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
        return delta
    }

    /// Tek kelimelik adım — erişilebilirlik eyleminin yolu.
    ///
    /// Sürükleme durumundan **bağımsız**: jest yok, dolayısıyla eksen kilidi de
    /// yok. Ofset hesabı ve kayıt işaretlemesi yine aynı yerden geçiyor.
    @discardableResult
    func stepCursorByWord(_ direction: Int) -> Bool {
        let offset = direction < 0
            ? WordBoundaries.toPreviousWordStart(
                before: textDocumentProxy.documentContextBeforeInput ?? "", count: 1)
            : WordBoundaries.toNextWordStart(
                after: textDocumentProxy.documentContextAfterInput ?? "", count: 1)
        guard offset != 0 else { return false }
        // Sürükleme yolundaki koşulsuz kapatmanın aynısı — tek adımlık olması
        // token'ın hâlâ yerinde durduğu anlamına gelmiyor.
        session.cursorMoved()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        return true
    }

    func endCursorDrag() {
        cursorDrag = nil
        // Jest bitti: bağlam, otomatik büyük harf ve adaylar imlecin **yeni**
        // yerine göre okunmalı.
        //
        // Okuma bir run loop turu **erteleniyor**: proxy son
        // `adjustTextPosition`'ı henüz yansıtmamış olabilir ve senkron okumak
        // tam da kaçınmaya çalıştığımız bayat bağlamı okumak olurdu.
        // `textDidChange` da aynı gerekçeyle erteliyor.
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    /// VoiceOver'a tek seferlik bir bildirim.
    ///
    /// Durum satırı bir `CATextLayer` ve çubuğun `accessibilityElements`
    /// listesinde **yok** — yani ekran okuyucu onu hiç görmüyor. Geçici geri
    /// bildirimin (kaydedildi, kaydedilemedi) VoiceOver karşılığı bu; satırı
    /// öğe yapmak onu kalıcı bir gezinme durağına çevirirdi.
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Belgeye **kendi** düzenlememiz: o sırada gelen `textDidChange` host
    /// uzlaştırmasını çalıştırmıyor (kendi ara hâllerimize bakmak olurdu).
    @discardableResult
    func withOwnEdit<T>(_ body: () -> T) -> T {
        isEditingDocument = true
        defer { isEditingDocument = false }
        return body()
    }

    // MARK: - Host uzlaştırması (§8)

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        checkPasteboard()
        session.dropIfSecure()
        session.resumeAfterSecureField()
        guard !isEditingDocument else { return }
        // §8.4: `selectionDidChange` HİÇ çağrılmıyor; seçim değişimi de dahil
        // her şey buradan geliyor. Ayrıca proxy bu anda henüz yeni durumu
        // yansıtmıyor — okuma bir run loop turu ertelenmeli.
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isEditingDocument else { return }
        DispatchQueue.main.async { [weak self] in self?.readSelection() }
    }

    private func readSelection() {
        guard !isEditingDocument else { return }
        // Hangi koordinatör yazıyorsa o haberdar ediliyor (bkz.
        // `InputSession.selectionChanged`) — imleç oynadıysa token düşüyor.
        selectionNote = session.selectionChanged(textDocumentProxy.selectedText)
        afterTokenBoundary()
        // Host metni değiştirmiş ya da imleç taşınmış olabilir; "karar host
        // metninden okunur" garantisi ancak burada da okunursa geçerli.
        updateAutoCapitalization()
        refreshUI()
    }
}

/// Girdi oturumunun belgeye ve alana açılan penceresi.
extension KeyboardViewController: InputSessionHost {
    var documentBaseline: String {
        (textDocumentProxy.documentContextBeforeInput ?? "")
            + (textDocumentProxy.documentContextAfterInput ?? "")
    }

    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var contextAfterInput: String? { textDocumentProxy.documentContextAfterInput }
    var selectedText: String? { textDocumentProxy.selectedText }
}
