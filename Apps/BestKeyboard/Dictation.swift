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

struct DictationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = DictationSession.shared
    private var sent: Bool { session.sent }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Konuş, yazayım").font(.system(size: 28, weight: .heavy))
                    Text("Türkçe · telefonunda çevriliyor").foregroundStyle(BK.sub)
                }
                Spacer()
                Button { session.close(); dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Kapat")
            }
            ScrollView {
                (Text(session.committed.isEmpty ? "" : session.committed + " ")
                 + Text(session.partial).foregroundColor(BK.sub))
                    .font(.system(size: 22))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(18)
            .frame(maxHeight: .infinity)
            .background(BK.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let e = session.error { Text(e).font(.footnote).foregroundStyle(BK.orange.ink) }

            VStack(spacing: 14) {
                Button {
                    if session.listening { session.stop() } else { Task { await session.start() } }
                } label: {
                    ZStack {
                        if session.listening {
                            Circle().fill(BK.accent.opacity(0.25)).frame(width: 130, height: 130)
                                .phaseAnimator([0.75, 1.0]) { c, k in c.scaleEffect(k) } animation: { _ in .easeInOut(duration: 0.7) }
                        }
                        Circle().fill(session.listening ? BK.accent : BK.sub).frame(width: 92, height: 92)
                        Image(systemName: "mic.fill").font(.system(size: 34)).foregroundStyle(.white)
                    }
                    .frame(height: 130)
                }
                .accessibilityLabel(session.listening ? "Dinlemeyi durdur" : "Dinlemeye başla")
                Text(session.listening ? "Dinliyorum — durdurmak için dokun" : "Devam etmek için dokun")
                    .font(.subheadline).foregroundStyle(BK.sub)
            }
            .frame(maxWidth: .infinity)

            Button { session.finish() } label: {
                Text(sent ? "Gönderildi ✓" : "Bitti — klavyeye gönder").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(BK.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(session.text.isEmpty)
            Text(sent ? "Şimdi sol üstteki ◀ ile mesajına dön; klavye metni kendisi yazar."
                      : "◀ ile mesajına dönüp konuşmaya devam edebilirsin; bitince adadaki “Bitti — yaz”a bas.")
                .font(.footnote).foregroundStyle(BK.sub).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .foregroundStyle(BK.ink)
        .background(BK.ground.ignoresSafeArea())
        .task { await session.start() }
    }
}
