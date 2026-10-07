import UIKit
import KBGeometry
import KBFoundation

/// Yapay zeka kartının klavyeden istediği her şey — kartın belgeye, panoya ve
/// yuvaya erişimi yalnız bu yoldan.
@MainActor
protocol AICardHost: AnyObject {
    var textDocumentProxy: UITextDocumentProxy { get }
    var hasFullAccess: Bool { get }
    /// Klavye hâlâ ekranda mı (cevap geldiğinde gösterilebilir mi).
    var isOnScreen: Bool { get }
    /// Pano içeriği okunabilir mi (Tam Erişim var, alan parola alanı değil).
    var clipboardAllowed: Bool { get }
    var clipboard: ClipboardWatcher { get }
    var aiActions: [AIAction] { get }
    @discardableResult func openURL(_ url: URL) -> Bool
    func showToast(_ text: String)
    func openAICard()
    func closeAICard()
    /// Kartın içeriği değişti; yükseklik yeniden ölçülsün.
    func aiCardHeightChanged()
    /// Belgeye kendi düzenlememiz (`textDidChange` bastırılsın).
    @discardableResult func withOwnEdit<T>(_ body: () -> T) -> T
    /// Metni kayda geçen yoldan (token sınırı) yazar.
    func insertAtBoundary(_ text: String)
    /// Yazılmakta olan token kapansın (kart belgeye dokunacak).
    func closeComposition()
    /// Kart belgeyi değiştirdi: token sınırı ve otomatik büyük harf yeniden.
    func didEditFromCard()
}

/// Yapay zeka kartı (tasarım 21–29): kaynak metin, tuşun çalışması, sonucun
/// belgeye ya da uygulamaya gitmesi. Görünüm `AIPanel`; klavye yalnız kartı
/// açıp kapatıyor ve `/komut` öneriyor.
@MainActor
final class AICardController {
    /// Kartın işlediği metin nereden: seçim, pano (çoğu zaman karşıdan gelen
    /// mesaj) ya da imleçten önceki cümle. Kartta kaynağa dokununca sıradakine
    /// geçiliyor.
    enum SourceKind { case selection, clipboard, sentence }

    private weak var host: AICardHost?
    private(set) weak var panel: AIPanel?
    private var task: Task<Void, Never>?
    private var sources: [(kind: SourceKind, text: String)] = []
    private var sourceIndex = 0
    private var last: (action: AIAction, result: String?, image: UIImage?)?
    /// Kartta önizlenen, uygulamaya gönderilmeyi bekleyen çıkarım.
    private var pending: Extraction?

    init(host: AICardHost) { self.host = host }

    private var source: (kind: SourceKind, text: String) {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex] : (.sentence, "")
    }

    /// Kartın kaynağı — kartta ve günlükte aynı etiket.
    private var sourceLabel: String {
        switch source.kind {
        case .selection: return AILog.Source.selection
        case .clipboard: return AILog.Source.clipboard
        case .sentence: return AILog.Source.typed
        }
    }

    // MARK: Açma / kapama

    func makePanel(theme: KeyboardTheme) -> AIPanel {
        let p = AIPanel(actions: host?.aiActions ?? [], theme: theme)
        p.onSourceTap = { [weak self] in
            guard let self, self.sources.count > 1 else { return }
            self.sourceIndex = (self.sourceIndex + 1) % self.sources.count
            self.showPick()
        }
        p.onRun = { [weak self] a in self?.run(a) }
        p.onClose = { [weak self] in self?.host?.closeAICard() }
        p.onReplace = { [weak self] in self?.applyResult(replace: true) }
        p.onAppend = { [weak self] in self?.applyResult(replace: false) }
        p.onCopy = { [weak self] in self?.copyResult() }
        p.onSticker = { [weak self] in self?.saveSticker() }
        p.onAgain = { [weak self] in
            guard let self else { return }
            if let last = self.last, last.image != nil { self.run(last.action) } else { self.showPick() }
        }
        p.onHeightChange = { [weak self] in self?.host?.aiCardHeightChanged() }
        p.onAdd = { [weak self] in self?.sendPending(edit: false) }
        p.onEdit = { [weak self] in self?.sendPending(edit: true) }
        panel = p
        return p
    }

    /// Kart yuvaya yerleşti.
    func didOpen() {
        captureSources()
        showPick()
    }

    /// Kart kapandı. Kullanıcı kapattıysa süren istek iptal (vazgeçti, sorun
    /// değil). Klavye gizlendiyse istek bitiyor ve sonucu "ekranda değildi"
    /// diye günlüğe düşüyor — iki durum günlükte ayrı.
    func didClose(byUser: Bool) {
        if byUser { task?.cancel() }
        task = nil
        last = nil
        panel = nil
    }

    private func showPick() {
        panel?.show(.pick(source: source.text, label: sourceLabel, canSwitch: sources.count > 1))
    }

    /// Kaynaklar öncelik sırasıyla: seçim → **yeni** kopyalanmış pano metni
    /// → imleçten önceki cümle → eski pano metni.
    private func captureSources() {
        guard let host else { return }
        let allowed = host.clipboardAllowed
        host.clipboard.check(allowed: allowed)
        let proxy = host.textDocumentProxy
        let sel = proxy.selectedText ?? ""
        let sentence = Self.lastSentence(proxy.documentContextBeforeInput ?? "")
        let clip = (host.clipboard.string(allowed: allowed) ?? "")
            .trimmed
        let fresh = host.clipboard.textIsFresh
        var list: [(kind: SourceKind, text: String)] = []
        if !sel.isEmpty { list.append((.selection, sel)) }
        if fresh, !clip.isEmpty { list.append((.clipboard, clip)) }
        if !sentence.isEmpty { list.append((.sentence, sentence)) }
        if !fresh, !clip.isEmpty { list.append((.clipboard, clip)) }
        sources = list
        sourceIndex = 0
    }

    /// İmleçten önceki son cümle (., !, ? ya da satır sonundan sonrası).
    static func lastSentence(_ before: String) -> String {
        let enders = Punctuation.sentenceTerminators.union(["\n"])
        var s = Substring(before)
        while let l = s.last, l.isWhitespace || enders.contains(l) { s = s.dropLast() }
        if let i = s.lastIndex(where: { enders.contains($0) }) { s = s[s.index(after: i)...] }
        return s.trimmed
    }

    // MARK: Çalıştırma

    /// `/çe` yazılıp öneriden seçildi (komut kelimesi silinmiş olarak).
    func run(command a: AIAction) {
        if a.runsHere {
            if panel == nil { host?.openAICard() }
            run(a)
        } else {
            captureSources()
            launchExternally(a, text: source.text)
        }
    }

    private func run(_ a: AIAction) {
        if a.kind.isStructured { runStructured(a); return }
        guard a.runsHere else { let t = source.text; host?.closeAICard(); launchExternally(a, text: t); return }
        guard let host else { return }
        let prompt = a.render(text: source.text, clipboard: host.clipboard.string(allowed: host.clipboardAllowed))
        let text = source.text, label = sourceLabel
        last = (a, nil, nil)
        panel?.show(.loading(a.workingText))
        start {
            let r = try await AIService.run(a, prompt: prompt, origin: .keyboard, source: label, text: text)
            return (r.id, { me in
                me.last = (a, r.value.text, r.value.image)
                me.panel?.show(r.value.image.map(AIPanel.State.image) ?? .text(r.value.text ?? ""))
            })
        }
    }

    /// Hatırlatıcı / Takvim / Kişi (tasarım 26, 28, 29): mesajdan çıkarılıp
    /// kartta önizleniyor. Eklemeyi **uygulama** yapıyor — iOS klavye
    /// eklentisine Hatırlatıcılar, Takvim ve Kişiler izni vermiyor; klavyenin
    /// içinde metin alanı da olamadığı için "Düzenle" de uygulamada açılıyor.
    private func runStructured(_ a: AIAction) {
        guard AIService.isConnected else {
            panel?.show(.error(AIService.Failure.noKey.localizedDescription))
            return
        }
        let text = source.text
        // Metin yoksa modele gitmeye gerek yok; ne yapılacağını söyle.
        guard !text.trimmed.isEmpty else {
            panel?.show(.error(AIService.Failure.nothingFound(what: "", source: "").localizedDescription))
            return
        }
        let label = sourceLabel
        last = (a, nil, nil)
        panel?.show(.loading(a.workingText))
        start {
            let r = try await AIService.extract(a.kind, from: text, template: a.prompt,
                                                origin: .keyboard, action: a.name, source: label)
            return (r.id, { me in
                me.pending = r.value
                me.panel?.show(Self.panelState(r.value))
            })
        }
    }

    /// Görevi başlatır; cevap geldiğinde kart hâlâ ekrandaysa gösterir. Değilse
    /// (klavye kapandı ya da iOS indirdi) günlüğe işleniyor — sabah "klavye
    /// kapandı, cevap yok" buydu. Kartı kullanıcı kapattıysa görev iptal: o bir
    /// sorun değil, işaretlenmiyor.
    private func start(_ work: @escaping () async throws -> (UUID, (AICardController) -> Void)) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do {
                let (id, present) = try await work()
                if Task.isCancelled { return }
                guard let self, self.host?.isOnScreen == true, self.panel != nil else {
                    AILog.update(id, status: .dismissed, detail: "Cevap geldiğinde klavye ekranda değildi; sonuç gösterilemedi.")
                    return
                }
                present(self)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.panel?.show(.error(error.localizedDescription))
            }
        }
    }

    /// Çıkarımın kart görünümü (tasarım 26, 28, 29).
    static func panelState(_ e: Extraction) -> AIPanel.State {
        switch e {
        case let .events(plan):
            return .events(calendar: plan.calendar, rows: plan.items.map(AIPanel.EventRow.init))
        case let .contact(d):
            return .contact(name: d.displayName, organization: d.organization, phones: d.phones, emails: d.emails)
        case let .reminders(plan):
            return .reminders(list: plan.list, rows: plan.items.map { (title: $0.title, when: AIService.trWhen($0.due)) })
        }
    }

    // MARK: Sonuç

    /// Çıkarımı uygulamaya gönderir (`Handoff.link`): veri ortak klasörde,
    /// adreste tek kullanımlık kimlik; "Düzenle"de `edit=1`.
    private func sendPending(edit: Bool) {
        guard let pending, let host else { return }
        let host_: DeepLink.Host, json: Data?, info: String
        var extra: [URLQueryItem] = []
        switch pending {
        case let .reminders(plan):
            let dest = TodoDestination.current
            host_ = .reminder; json = try? JSONEncoder().encode(plan)
            extra.append(URLQueryItem(name: DeepLink.Param.destination, value: dest.rawValue))
            let what = plan.items.count > 1 ? "\(plan.items.count) maddeyi" : "maddeyi"
            info = edit ? "\(what) düzenlemen için hazırladı" : "\(what) ekliyor (\(dest.title))"
        case let .events(plan):
            host_ = .event; json = try? JSONEncoder().encode(plan)
            info = edit ? "etkinliği düzenlemen için hazırladı" : "etkinliği Takvim’e ekliyor"
        case let .contact(d):
            host_ = .contact; json = try? JSONEncoder().encode(d)
            info = edit ? "kişiyi düzenlemen için hazırladı" : "kişiyi Kişiler’e ekliyor"
        }
        guard let json, let link = Handoff.link(host_, payload: json, edit: edit, extra: extra) else { return }
        guard host.openURL(link.url) else {
            if let id = link.id { Handoff.purge(id) }
            panel?.show(.error(CommonText.fullAccess(open: CommonText.app)))
            return
        }
        panel?.show(.info(title: edit ? "Uygulamada düzenle" : "Ekleniyor",
                          message: "BestKeyboard açıldı ve \(info). \(CommonText.backToChat)."))
    }

    /// Değiştir: seçim varsa yerine yazılıyor (proxy seçimi kendisi siliyor);
    /// yoksa imleçten önceki cümle siliniyor. Belgede cümle hâlâ duruyor mu
    /// diye yeniden bakılıyor — bayat bir sonuçla başka bir şeyi silmemek için.
    private func applyResult(replace: Bool) {
        guard let result = last?.result, let host else { return }
        let proxy = host.textDocumentProxy
        host.closeComposition()
        if !replace || source.kind == .clipboard {
            // Ekle — ya da pano kaynağı: belgede silinecek bir şey yok, sonuç imlece.
            host.withOwnEdit { proxy.insertText(result.spaced(after: proxy.documentContextBeforeInput)) }
        } else if source.kind == .selection, !(proxy.selectedText ?? "").isEmpty {
            host.withOwnEdit { proxy.insertText(result) }
        } else if let before = proxy.documentContextBeforeInput,
                  !source.text.isEmpty, let r = before.range(of: source.text, options: .backwards) {
            let tail = before[r.lowerBound...]
            host.withOwnEdit {
                for _ in 0..<tail.count { proxy.deleteBackward() }
                proxy.insertText(result)
            }
        } else {
            host.insertAtBoundary(result)
        }
        host.closeAICard()
        host.didEditFromCard()
    }

    private func copyResult() {
        guard let host, host.hasFullAccess, let last else { return }
        if let img = last.image { host.clipboard.put(image: img) }
        else if let t = last.result { host.clipboard.put(string: t) }
        panel?.flashCopied()
    }

    /// Resmi stüdyoya çıkartma olarak kaydeder — oradan WhatsApp/Telegram
    /// paketine ve Mesajlar çekmecesine giriyor.
    private func saveSticker() {
        guard let img = last?.image, let png = img.scaled(maxSide: 512).pngData() else { return }
        if MediaStore.add(kind: .sticker, data: png, thumb: img) != nil { panel?.flashSticker() }
        else { host?.showToast(CommonText.fullAccess(failed: "Kaydedilemedi")) }
    }

    /// Yapay zeka tuşu — uygulamada açılan tür (kestirme ya da sohbet uygulaması).
    ///
    /// Metin: seçim, yoksa imleçten önceki **cümle** (bağlam host'a göre
    /// kırpılmış olabilir). İstem şablonla birleşiyor; `q` alan uygulamada
    /// kutuya hazır geliyor, almayanda panoya konup "yapıştır" deniyor.
    private func launchExternally(_ action: AIAction, text: String) {
        guard let host else { return }
        let launch: AIAction.ExternalLaunch
        do {
            launch = try action.externalLaunch(text: text, clipboard: host.clipboard.string(allowed: host.clipboardAllowed))
        } catch {
            host.showToast(error.localizedDescription)
            return
        }
        if let copy = launch.pasteboard, host.hasFullAccess { host.clipboard.put(string: copy) }
        guard host.openURL(launch.url) else {
            host.showToast(CommonText.fullAccess(open: launch.appName))
            return
        }
        if launch.pasteboard != nil { host.showToast(PasteHint.prompt(in: launch.appName)) }
    }
}
