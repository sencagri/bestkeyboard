import SwiftUI
import Speech
import AVFoundation
import ActivityKit

/// Klavyenin 🎤 düğmesinin karşı ucu.
///
/// iOS klavye uzantısına mikrofon vermiyor (Tam Erişimle de). Klavye
/// `bestkeyboard://dikte` ile uygulamayı açıyor; burada konuşma Türkçe
/// metne çevriliyor ve ortak klasöre "bekleyen dikte" olarak yazılıyor.
/// Kullanıcı sol üstteki ◀ ile geri dönünce klavye metni kendisi yazıyor.
///
/// Kullanıcı sohbete dönünce kayıt arka planda sürüyor (`audio` arka plan
/// kipi) ve Dinamik Ada'da görünüyor; adadaki "Bitti — yaz" metni açık
/// klavyeye anında gönderiyor (Darwin bildirimi).
@MainActor @Observable
final class DictationSession {
    static let shared = DictationSession()

    var committed = ""
    var partial = ""
    var listening = false
    var error: String?
    /// Son gönderimden sonra metin değişmediyse `true`.
    var sent = false
    /// Yapay zeka tuşu uygulandıysa önceki (konuşulan) metin — "Asıl metne dön".
    var original: String?
    /// "Resmîleştir · Cerebras" gibi; kutunun üstündeki şerit.
    var transformLabel: String?
    var transforming = false

    private var activity: Activity<DictationAttributes>?
    private var elapsedBefore: TimeInterval = 0
    private var runStart: Date?
    private var lastPush = Date.distantPast

    private init() {
        DictationIsland.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: if self.listening { self.stop() } else { await self.start() }
            case .finish: self.finish()
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Her başlatmada artıyor. Durdurulan tanıma, durdurmadan sonra "son hâli"
    /// bir kez daha gönderiyor; o sırada metin zaten kalıcıya alınmış oluyor —
    /// eskiden sona yeniden ekleniyor, "Bitti" deyince cümle iki kez yazılıyordu.
    private var run = 0

    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }

    func start() async {
        guard !listening else { return }
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK else {
            error = "Mikrofon ve konuşma tanıma izni gerekli: Ayarlar › BestKeyboard."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Türkçe konuşma tanıma şu an kullanılamıyor."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // Destekleniyorsa ses telefondan çıkmıyor.
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            req.addsPunctuation = true
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
                req.append(buf)
            }
            engine.prepare()
            try engine.start()
            listening = true
            error = nil
            sent = false
            runStart = Date()
            pushActivity(force: true)
            run += 1
            let thisRun = run
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self, self.run == thisRun else { return }
                    if let result { self.partial = result.bestTranscription.formattedString; self.sent = false }
                    if err != nil || result?.isFinal == true { self.finishSegment() }
                    self.pushActivity()
                }
            }
        } catch {
            self.error = "Mikrofon açılamadı: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        run += 1  // bu tanımadan gelecek geç sonuçlar artık yok sayılıyor
        finishSegment()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishSegment() {
        if !partial.isEmpty { committed = text; partial = "" }
        if let s = runStart { elapsedBefore += Date().timeIntervalSince(s) }
        runStart = nil
        listening = false
        task = nil; request = nil
        pushActivity(force: true)
    }

    /// Durdurur ve metni klavyeye gönderir — ekrandaki düğme de adadaki de.
    func finish() {
        stop()
        guard !text.isEmpty else { endActivity(); return }
        sent = Self.handOff(text)
        if sent { endActivity(done: true) }
    }

    /// Ekran kapanınca: ada da gider, sonraki dikte sıfırdan başlar.
    func close() {
        stop()
        endActivity()
        committed = ""; partial = ""; sent = false; elapsedBefore = 0
        original = nil; transformLabel = nil
    }

    /// Dikte tuşu (tasarım 37): kutudaki metni yapay zeka tuşuyla dönüştürür.
    /// Sonuç kutuya yazılıyor; gönderilen kutuda görünen.
    func transform(_ a: AIAction) async {
        if listening { stop() }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !transforming else { return }
        guard AIService.isConnected else {
            error = AIService.Failure.noKey.localizedDescription
            return
        }
        transforming = true
        error = nil
        defer { transforming = false }
        do {
            let out = try await AILog.measure(origin: .app, action: a.name, source: "Dikte ekranı", text: source,
                                              summarize: { (t: String) in t }) {
                try await AIService.complete(a.render(text: source, clipboard: nil))
            }.value
            if original == nil { original = source }
            committed = out
            partial = ""
            sent = false
            transformLabel = "\(a.name) · \(AIService.provider.title)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func undoTransform() {
        guard let o = original else { return }
        committed = o
        partial = ""
        original = nil
        transformLabel = nil
        sent = false
    }

    // MARK: - Dinamik Ada

    private var state: DictationAttributes.ContentState {
        let words = text.split(separator: " ")
        let tail = (words.count > 8 ? "…" : "") + words.suffix(8).joined(separator: " ")
        return .init(listening: listening,
                     runStart: (runStart ?? Date()).addingTimeInterval(-elapsedBefore),
                     elapsed: elapsedBefore, tail: tail, done: false)
    }

    /// Kısmi sonuçlar saniyede onlarca geliyor; ada saniyede bir güncelleniyor.
    private func pushActivity(force: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard force || Date().timeIntervalSince(lastPush) >= 1 else { return }
        lastPush = Date()
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else if listening {
            activity = try? Activity.request(attributes: DictationAttributes(), content: content)
        }
    }

    private func endActivity(done: Bool = false) {
        guard let a = activity else { return }
        activity = nil
        var s = state; s.done = done
        Task {
            await a.end(ActivityContent(state: s, staleDate: nil),
                        dismissalPolicy: done ? .after(Date().addingTimeInterval(3)) : .immediate)
        }
    }

    /// Metni klavyeye bırakır. Klavye 10 dakika içinde açılırsa yazar; şu an
    /// açıksa Darwin bildirimiyle hemen alıyor.
    static let handOffNotification = "com.sencagri.bestkeyboard.dictation"

    nonisolated static func handOff(_ text: String) -> Bool {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettingsStore.appGroup) else { return false }
        let payload: [String: Any] = ["text": text, "at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard (try? data.write(to: dir.appendingPathComponent("dictation.json"), options: .atomic)) != nil else { return false }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(handOffNotification as CFString), nil, nil, true)
        return true
    }
}

/// Dikte ekranındaki tuşlar: hangi metin tuşları, hangi sırayla (tasarım 38).
enum DictationKeys {
    static let maxCount = 6
    private static let key = "kb.dictation.actions"
    private static var store: UserDefaults { UserDefaults(suiteName: KeyboardSettingsStore.appGroup) ?? .standard }
    static let defaultIDs = ["kibar", "resmi", "cevir", "kisalt", "duzelt", "cevap"]

    static var ids: [String] {
        get {
            // Geri alınan "arapca" varsayılanı yerine İngilizce Çevir.
            guard var list = store.stringArray(forKey: key) else { return defaultIDs }
            if let i = list.firstIndex(of: "arapca") {
                if list.contains("cevir") { list.remove(at: i) } else { list[i] = "cevir" }
            }
            return list
        }
        set { store.set(Array(newValue.prefix(maxCount)), forKey: key) }
    }

    /// Ekrandaki tuşlar: seçili kimlikler sırasıyla, yalnız metin tuşları.
    static func actions(from all: [AIAction]) -> [AIAction] {
        ids.compactMap { id in all.first { $0.id == id && $0.kind == .text } }
    }
}

struct DictationView: View {
    let model: KeyboardSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var session = DictationSession.shared
    @State private var editingKeys = false
    private var sent: Bool { session.sent }
    private var keys: [AIAction] { DictationKeys.actions(from: model.settings.aiActions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Button { session.close(); dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Kapat")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Konuş, yazayım").font(.system(size: 26, weight: .heavy))
                    Text("Türkçe · telefonunda çevriliyor").font(.subheadline).foregroundStyle(BK.sub)
                }
                Spacer()
                micButton
            }

            VStack(alignment: .leading, spacing: 10) {
                if let label = session.transformLabel, !session.transforming {
                    HStack {
                        Text(label).font(.footnote.weight(.bold)).foregroundStyle(BK.purple.ink)
                        Spacer()
                        Button("Asıl metne dön") { session.undoTransform() }
                            .font(.footnote.weight(.bold)).foregroundStyle(BK.accent)
                            .frame(minHeight: 32)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(BK.purple.chip, in: RoundedRectangle(cornerRadius: 12))
                }
                if session.transforming {
                    HStack(spacing: 8) {
                        ProgressView().tint(BK.accent)
                        Text("Hazırlanıyor…").font(.footnote).foregroundStyle(BK.sub)
                    }
                }
                ScrollView {
                    (Text(session.committed.isEmpty ? "" : session.committed + " ")
                     + Text(session.partial).foregroundColor(BK.sub))
                        .font(.system(size: 21))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .opacity(session.transforming ? 0.4 : 1)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .background(BK.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let e = session.error { Text(e).font(.footnote).foregroundStyle(BK.orange.ink) }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    BKSectionTitle(text: "Dönüştür", color: BK.accent)
                    Spacer()
                    Button("Tuşları düzenle") { editingKeys = true }
                        .font(.footnote.weight(.semibold)).foregroundStyle(BK.accent)
                }
                if keys.isEmpty {
                    Text("Tuş seçilmedi — “Tuşları düzenle”den ekle.").font(.footnote).foregroundStyle(BK.sub)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(keys) { a in
                            let on = session.transformLabel?.hasPrefix(a.name + " ·") == true
                            Button { Task { await session.transform(a) } } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: a.icon).font(.system(size: 16, weight: .semibold))
                                    Text(a.name).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                                }
                                .foregroundStyle(on ? .white : BK.purple.ink)
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .background(on ? BK.accent : BK.purple.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(session.text.isEmpty || session.transforming)
                        }
                    }
                }
            }

            Button { session.finish() } label: {
                Text(sent ? "Gönderildi ✓" : "Bitti — klavyeye gönder").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(BK.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(session.text.isEmpty || session.transforming)
            Text(sent ? "Şimdi sol üstteki ◀ ile mesajına dön; klavye metni kendisi yazar."
                      : "Tuşa basınca metin kutuda değişir; beğenmezsen “Asıl metne dön”. Gönderilen, kutuda gördüğün.")
                .font(.footnote).foregroundStyle(BK.sub).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .foregroundStyle(BK.ink)
        .background(BK.ground.ignoresSafeArea())
        .task {
            #if DEBUG
            // `-bkScreen dikte -dikteDemo "metin" [-dikteRun <tuş>] [-dikteKeys]`: mikrofonsuz örnek (ekran görüntüsü).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-dikteDemo"), i + 1 < args.count {
                session.committed = args[i + 1]
                if args.contains("-dikteKeys") { editingKeys = true }
                if let j = args.firstIndex(of: "-dikteRun"), j + 1 < args.count,
                   let a = model.settings.aiActions.first(where: { $0.id == args[j + 1] }) {
                    await session.transform(a)
                }
                return
            }
            #endif
            await session.start()
        }
        .sheet(isPresented: $editingKeys) { DictationKeysSheet(model: model) }
    }

    private var micButton: some View {
        Button {
            if session.listening { session.stop() } else { Task { await session.start() } }
        } label: {
            ZStack {
                if session.listening {
                    Circle().fill(BK.accent.opacity(0.25)).frame(width: 76, height: 76)
                        .phaseAnimator([0.8, 1.0]) { c, k in c.scaleEffect(k) } animation: { _ in .easeInOut(duration: 0.7) }
                }
                Circle().fill(session.listening ? BK.accent : BK.sub).frame(width: 60, height: 60)
                Image(systemName: "mic.fill").font(.system(size: 24)).foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
        }
        .accessibilityLabel(session.listening ? "Dinlemeyi durdur" : "Dinlemeye başla")
    }
}

/// Dikte tuşlarını seç ve sırala (tasarım 38). Tuşlar yapay zeka tuşlarıyla ortak.
struct DictationKeysSheet: View {
    let model: KeyboardSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var ids = DictationKeys.ids
    @State private var addingNew = false

    /// Açık olanlar seçim sırasıyla, ardından kapalı metin tuşları.
    private var rows: [AIAction] {
        let text = model.settings.aiActions.filter { $0.kind == .text }
        return ids.compactMap { id in text.first { $0.id == id } } + text.filter { !ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Dikte ekranının altında hangi tuşlar dursun? Açık olanlar bu sırayla görünür; en çok \(DictationKeys.maxCount) tuş.")
                        .font(.subheadline).foregroundStyle(BK.sub).padding(.horizontal, 4)
                    BKCard(padding: 16) {
                        BKSectionTitle(text: "Ekranda · \(onCount)/\(DictationKeys.maxCount)", color: BK.accent)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, a in
                            VStack(spacing: 0) {
                                Divider().overlay(BK.line)
                                row(a, index: i)
                            }
                        }
                    }
                    Button { addingNew = true } label: {
                        Text("+ Yeni tuş").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(BK.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    Text("Tuşlar Yapay zeka tuşlarınla ortak: burada eklediğin tuş klavyedeki ✦ kartında da çıkar. Burada yalnız metin tuşları listelenir.")
                        .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
                }
                .padding(16)
            }
            .foregroundStyle(BK.ink)
            .bkScreen("Dikte tuşları")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
            .navigationDestination(isPresented: $addingNew) { AIActionEditor(model: model, actionID: nil) }
            .onChange(of: model.settings.aiActions) { old, new in
                // Yeni eklenen metin tuşu yer varsa dikte ekranına da gelsin.
                let added = new.filter { a in a.kind == .text && !old.contains { $0.id == a.id } }
                for a in added where ids.count < DictationKeys.maxCount { ids.append(a.id) }
                DictationKeys.ids = ids
            }
        }
    }

    private var onCount: Int { ids.filter { id in rows.contains { $0.id == id } }.count }

    private func row(_ a: AIAction, index i: Int) -> some View {
        let on = ids.contains(a.id)
        let full = !on && onCount >= DictationKeys.maxCount
        return HStack(spacing: 12) {
            Button {
                guard on, let j = ids.firstIndex(of: a.id), j > 0 else { return }
                ids.swapAt(j, j - 1)
                DictationKeys.ids = ids
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(on && ids.first != a.id ? BK.accent : BK.line)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(a.name) yukarı taşı")
            BKIcon(systemName: a.icon, tint: BK.purple, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.body.weight(.semibold))
                Text(a.prompt).font(.caption).foregroundStyle(BK.sub).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle(a.name, isOn: Binding(get: { on }, set: { v in
                if v { if !full { ids.append(a.id) } } else { ids.removeAll { $0 == a.id } }
                DictationKeys.ids = ids
            }))
            .labelsHidden()
            .tint(BK.green.ink)
            .disabled(full)
        }
        .frame(minHeight: 56)
    }
}
