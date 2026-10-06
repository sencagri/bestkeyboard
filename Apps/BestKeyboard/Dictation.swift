import SwiftUI
import Speech
import AVFoundation

/// Klavyenin 🎤 düğmesinin karşı ucu.
///
/// iOS klavye uzantısına mikrofon vermiyor (Tam Erişimle de). Klavye
/// `bestkeyboard://dikte` ile uygulamayı açıyor; burada konuşma Türkçe
/// metne çevriliyor ve ortak klasöre "bekleyen dikte" olarak yazılıyor.
/// Kullanıcı sol üstteki ◀ ile geri dönünce klavye metni kendisi yazıyor.
@Observable
final class DictationSession {
    var committed = ""
    var partial = ""
    var listening = false
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

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
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                Task { @MainActor in
                    if let result { self.partial = result.bestTranscription.formattedString }
                    if err != nil || result?.isFinal == true { self.finishSegment() }
                }
            }
        } catch {
            self.error = "Mikrofon açılamadı: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        finishSegment()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishSegment() {
        if !partial.isEmpty { committed = text; partial = "" }
        listening = false
        task = nil; request = nil
    }

    /// Metni klavyeye bırakır. Klavye 10 dakika içinde açılırsa yazar.
    static func handOff(_ text: String) -> Bool {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettingsStore.appGroup) else { return false }
        let payload: [String: Any] = ["text": text, "at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return (try? data.write(to: dir.appendingPathComponent("dictation.json"), options: .atomic)) != nil
    }
}

struct DictationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = DictationSession()
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Konuş, yazayım").font(.system(size: 28, weight: .heavy))
                    Text("Türkçe · telefonunda çevriliyor").foregroundStyle(BK.sub)
                }
                Spacer()
                Button { session.stop(); dismiss() } label: {
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

            Button {
                session.stop()
                sent = DictationSession.handOff(session.text)
            } label: {
                Text(sent ? "Gönderildi ✓" : "Bitti — klavyeye gönder").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(BK.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(session.text.isEmpty)
            Text(sent ? "Şimdi sol üstteki ◀ ile mesajına dön; klavye metni kendisi yazar."
                      : "Bitince sol üstteki ◀ ile mesajına dön; klavye metni kendisi yazar.")
                .font(.footnote).foregroundStyle(BK.sub).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .foregroundStyle(BK.ink)
        .background(BK.ground.ignoresSafeArea())
        .task { await session.start() }
    }
}
