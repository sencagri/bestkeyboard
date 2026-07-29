import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBDecoder
import KBRuntime

/// Gerçek yazım kaydı — sözleşme §12.
///
/// ## Neden kalibrasyon UYGULANMADAN kaydediyor
///
/// İlk tasarım ürün yolunu (kalibrasyon açık) kullanacaktı. Bu, ölçülmek istenen
/// şeyi ölçüm setinin içine gömüyordu: *"kalibrasyon işe yarıyor mu"* sorusu,
/// kalibrasyonun zaten açık olduğu bir kayıtla sorulamaz.
///
/// Çözüm daha basit ve daha güçlü: **ham modelle kaydet, kalibrasyonu replay'de
/// uygula.** Tek bir kayıttan §8.6'nın üç kolu da (kalsız / global / hiyerarşik)
/// offline ölçülebilir ve kayıt hiçbirine taraf olmaz.
///
/// Öğrenme de kapalı: bu `InputCoordinator` örneği kendine ait, `.bkl`'ye hiç
/// yazmıyor ve `applyCalibration()` hiç çağrılmıyor. Kullanıcının gerçek profili
/// hedefli yazım örnekleriyle kirlenmiyor.
final class RecorderViewController: UIViewController {

    private let prompt: PromptCorpus.Prompt
    private let condition: TypingSession.Condition
    private let posture: TypingSession.Posture
    private let participantID: String
    private let sessionOrdinal: Int
    private let onFinish: () -> Void

    init(prompt: PromptCorpus.Prompt, condition: TypingSession.Condition,
         posture: TypingSession.Posture, participantID: String,
         sessionOrdinal: Int, onFinish: @escaping () -> Void) {
        self.prompt = prompt
        self.condition = condition
        self.posture = posture
        self.participantID = participantID
        self.sessionOrdinal = sessionOrdinal
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Durum

    private let layout = TurkishQ.layout()
    private var input: InputCoordinator!
    private var shift = ShiftPolicy()
    private var session: TypingSession!

    /// Belge tamponu — host yok.
    private var buffer = ""
    /// Hangi hedef kelimedeyiz. `calibrationReplay`'de UI ilerletir, yani
    /// hizalama çıkarım değil **kayıt** olur (§12.4).
    private var wordIndex = 0
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var nextActionID = 0
    /// `touchesEnded` kaydı commit'ten önce geldiği için son dokunmanın kimliği
    /// burada tutulup commit'e bağlanır.
    private var lastTouchID: Int?
    private var engineReady = false

    // MARK: - Görünüm

    private let promptLabel = UILabel()
    private let progressLabel = UILabel()
    private let typedLabel = UILabel()
    private let logLabel = UILabel()
    private let statusLabel = UILabel()
    private let suggestionStack = UIStackView()
    private var keyboardView: KeyboardView!
    private var keyLog: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = condition == .calibrationReplay ? "Kalibrasyon kaydı" : "Davranış kaydı"
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = .init(title: "Vazgeç", style: .plain,
                                                 target: self, action: #selector(abort))
        navigationItem.rightBarButtonItem = .init(title: "Kaydet", style: .done,
                                                 target: self, action: #selector(complete))

        input = InputCoordinator(layout: layout)
        buildViews()
        startSession()
        loadEngine()
    }

    // MARK: - Oturum yaşam döngüsü

    private func startSession() {
        session = TypingSession(
            attemptID: Self.attemptID(),
            participantID: participantID,
            sessionOrdinal: sessionOrdinal,
            condition: condition,
            promptID: prompt.id,
            promptText: prompt.text,
            promptSource: prompt.id.hasPrefix("manual") ? .manual : .builtin,
            split: prompt.split.rawValue,
            alignmentSource: condition == .calibrationReplay ? .constructed : .sequential,
            startedAt: Date(),
            posture: posture,
            engine: Self.blankEngineSnapshot(),
            geometry: geometrySnapshot())
        // §12.6: deneme BAŞLAR BAŞLAMAZ diske düşer. Yalnız tamamlananları
        // saklamak seçim yanlılığıdır — vazgeçilen deneme de sayılmalı.
        persist()
    }

    private func persist() {
        session.finalText = buffer
        try? SessionStore.save(session)
    }

    @objc private func abort() {
        session.status = .aborted
        session.endedAt = Date()
        persist()
        onFinish()
    }

    @objc private func complete() {
        session.status = .completed
        session.endedAt = Date()
        persist()
        onFinish()
    }

    private static func attemptID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone(identifier: "UTC")
        let suffix = String(format: "%04x", UInt32.random(in: 0..<0xFFFF))
        return "\(f.string(from: Date()))Z-\(suffix)"
    }

    // MARK: - Motor

    /// Paket yüklenmeden yazmaya **başlanmaz**: aksi hâlde aynı denemenin ilk ve
    /// ikinci yarısı farklı modelle çalışır ve replay tekrarlanamaz olur.
    private func loadEngine() {
        statusLabel.text = "paket yükleniyor…"
        keyboardView.isUserInteractionEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let loaded = try? PackLoader.load(layout: self.layout, bundle: .main)
            DispatchQueue.main.async {
                guard let loaded else {
                    self.statusLabel.text = "paket yüklenemedi — kayıt geçersiz"
                    self.session.status = .invalid
                    self.persist()
                    return
                }
                self.input.setEngine(.init(decoder: loaded.decoder,
                                           literalChannel: loaded.literalChannel,
                                           expansions: loaded.expansions))
                self.session.engine = self.engineSnapshot(loaded)
                self.session.geometry = self.geometrySnapshot()
                self.engineReady = true
                self.keyboardView.isUserInteractionEnabled = true
                self.startTime = CFAbsoluteTimeGetCurrent()
                self.statusLabel.text = loaded.report
                self.persist()
                self.refresh()
            }
        }
    }

    private func engineSnapshot(_ loaded: PackLoader.Loaded) -> TypingSession.EngineSnapshot {
        .init(buildConfiguration: Self.buildConfiguration,
              appVersion: Self.appVersion,
              packs: loaded.packs.map { .init(name: $0.name, sha256: $0.sha256, bytes: $0.bytes) },
              beamWidth: loaded.decoder.beamWidth,
              oovTheta: input.oovTheta,
              suggestionWindow: input.suggestionWindow,
              autoCorrectsOutOfVocabulary: loaded.literalChannel.autoCorrectsOutOfVocabulary,
              // Kayıt **kalibrasyonsuz** modelle; kalibrasyon replay'de uygulanır.
              calibration: .init(applied: false, strongSamples: 0,
                                 globalX: 0, globalY: 0, rowX: [], rowY: [],
                                 keyX: [], keyY: [], biasX: [], biasY: []),
              learningFrozen: true)
    }

    private static func blankEngineSnapshot() -> TypingSession.EngineSnapshot {
        .init(buildConfiguration: buildConfiguration, appVersion: appVersion,
              packs: [], beamWidth: 0, oovTheta: 0, suggestionWindow: 0,
              autoCorrectsOutOfVocabulary: false,
              calibration: .init(applied: false, strongSamples: 0, globalX: 0, globalY: 0,
                                 rowX: [], rowY: [], keyX: [], keyY: [], biasX: [], biasY: []),
              learningFrozen: true)
    }

    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        let b = i?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func geometrySnapshot() -> TypingSession.Geometry {
        let b = keyboardView?.bounds ?? .zero
        let f = keyboardView?.convert(keyboardView.bounds, to: nil) ?? .zero
        return .init(layoutID: layout.id,
                     boundsX: b.minX, boundsY: b.minY,
                     boundsWidth: b.width, boundsHeight: b.height,
                     frameInScreenX: f.minX, frameInScreenY: f.minY,
                     frameInScreenWidth: f.width, frameInScreenHeight: f.height,
                     safeAreaBottom: view.safeAreaInsets.bottom,
                     screenScale: UIScreen.main.scale,
                     interfaceOrientation: "portrait",
                     deviceModel: UIDevice.current.model,
                     systemVersion: UIDevice.current.systemVersion)
    }

    // MARK: - Görünüm kurulumu

    private func buildViews() {
        for (l, size, weight) in [(promptLabel, 22.0, UIFont.Weight.semibold),
                                  (progressLabel, 12.0, .regular),
                                  (typedLabel, 17.0, .regular),
                                  (logLabel, 12.0, .regular),
                                  (statusLabel, 11.0, .regular)] {
            l.font = size == 12.0 || size == 11.0
                ? .monospacedSystemFont(ofSize: size, weight: weight)
                : .systemFont(ofSize: size, weight: weight)
            l.numberOfLines = 0
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
        }
        progressLabel.textColor = .secondaryLabel
        statusLabel.textColor = .tertiaryLabel
        logLabel.textColor = .secondaryLabel
        typedLabel.textColor = .label

        suggestionStack.axis = .horizontal
        suggestionStack.distribution = .fillEqually
        suggestionStack.spacing = 4
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestionStack)
        // Öneri çubuğu **yalnız davranış kipinde** var ve dokunulabilir.
        // Kalibrasyon kipinde görünmez bir çubuk göstermek "gerçek davranış"
        // taklidi olurdu; ya gerçek ya hiç.
        for _ in 0..<3 {
            let b = UIButton(type: .system)
            b.titleLabel?.font = .systemFont(ofSize: 16)
            b.addTarget(self, action: #selector(pickSuggestion(_:)), for: .touchUpInside)
            suggestionStack.addArrangedSubview(b)
        }
        suggestionStack.isHidden = condition == .calibrationReplay

        keyboardView = KeyboardView(layout: layout)
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.showsGlobeKey = false
        keyboardView.onKeyCommit = { [weak self] hit in self?.handle(hit) }
        keyboardView.onKeyRepeat = { [weak self] hit, stage in self?.handleRepeat(hit, stage) }
        keyboardView.onTouchRecord = { [weak self] r in self?.record(r) }
        view.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            promptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            promptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            progressLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            progressLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            typedLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 14),
            typedLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            typedLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            logLabel.topAnchor.constraint(equalTo: typedLabel.bottomAnchor, constant: 14),
            logLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            logLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            statusLabel.bottomAnchor.constraint(equalTo: suggestionStack.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: promptLabel.trailingAnchor),

            suggestionStack.bottomAnchor.constraint(equalTo: keyboardView.topAnchor, constant: -6),
            suggestionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            suggestionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            suggestionStack.heightAnchor.constraint(equalToConstant: 44),

            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            keyboardView.heightAnchor.constraint(equalToConstant: 216),
        ])
        refresh()
    }

    // MARK: - Dokunma kaydı

    private func record(_ r: KeyboardView.TouchRecord) {
        var t = TypingSession.Touch(
            touchID: r.touchID, phase: r.phase.rawValue, outcome: r.outcome.rawValue,
            rawX: r.raw.x, rawY: r.raw.y,
            normX: r.normalized?.x, normY: r.normalized?.y,
            decoderX: nil, decoderY: nil,
            timestamp: r.timestamp,
            majorRadius: r.majorRadius, majorRadiusTolerance: r.majorRadiusTolerance,
            plane: String(describing: r.plane),
            shift: shift.isUppercase ? (shift.mode == .locked ? "locked" : "shifted") : "off",
            hitKind: nil, key: nil, keyIndex: nil)

        switch r.hit {
        case let .letter(index, point):
            t.hitKind = "letter"
            t.key = String(layout.keys[index].char)
            t.keyIndex = index
            // Decoder'a **fiilen verilen** nokta. Ham noktayla aynı olmayabilir
            // (normalizasyon bounds origin'ini de çıkarıyor) ve replay'in
            // birebir eşleşmesi için gereken bu değerdir.
            t.decoderX = point.x
            t.decoderY = point.y
        case let .symbol(ch):
            t.hitKind = "symbol"; t.key = String(ch)
        case let .function(fk):
            t.hitKind = "function"; t.key = String(describing: fk)
        case nil:
            break
        }
        session.touches.append(t)
        if r.phase == .ended || r.phase == .cancelled { lastTouchID = r.touchID }
    }

    private func log(_ kind: String, commit: TypingSession.Action.Commit? = nil,
                     suggestions: [TypingSession.Action.Suggestion]? = nil) {
        let a = TypingSession.Action(
            actionID: nextActionID, t: CFAbsoluteTimeGetCurrent() - startTime,
            kind: kind, touchID: lastTouchID,
            targetWordIndex: wordIndex,
            targetWord: wordIndex < prompt.words.count ? prompt.words[wordIndex] : nil,
            suggestions: suggestions, commit: commit, textAfter: buffer)
        nextActionID += 1
        session.actions.append(a)
    }

    /// Eylemden **sonra** alınan aday anlık görüntüsü.
    ///
    /// Sıra bağlayıcı (§12.7): önce girdi işlenir, sonra adaylar okunur. Ters
    /// sırada kaydedilen top-3 bir önceki prefix'e ait olurdu.
    private func suggestionSnapshot() -> [TypingSession.Action.Suggestion] {
        guard engineReady else { return [] }
        let shown = Set(input.suggestionSurfaces())
        return input.candidates(topK: 5).map {
            .init(word: $0.word, cost: $0.cost,
                  source: Int($0.source), language: Int($0.language),
                  shown: shown.contains($0.word))
        }
    }

    // MARK: - Tuş işleme

    private func handle(_ hit: KeyboardView.KeyHit) {
        guard engineReady else { return }
        switch hit {
        case let .letter(index, point):
            let ch = layout.keys[index].char
            let t = TouchSample(down: point, timestamp: CFAbsoluteTimeGetCurrent())
            if shift.isUppercase {
                input.insertUppercaseLetter(
                    ch, uppercase: InputCoordinator.uppercase(ch, locale: "tr"),
                    touch: t, into: self)
                keyLog.append("⇧" + String(ch))
            } else {
                input.insertLetter(ch, touch: t, into: self)
                keyLog.append(String(ch))
            }
            shift.didEmitLetter()
            log("letter", suggestions: suggestionSnapshot())

        case let .symbol(ch):
            let r = input.insertSymbol(ch, into: self)
            keyLog.append(String(ch))
            shift.didInterruptChain()
            log("symbol", commit: commitRecord(r))

        case let .function(fk):
            switch fk {
            case .space:
                // Kalibrasyon kipinde düzeltme **kapalı**: `fieldProtectsLiteral`
                // `θ`'yı sonsuza çekiyor, yani karar noktası kuruluyor ama asla
                // düzeltme uygulanmıyor. Kullanıcı kendi hatasını görmediği için
                // düzeltmeye de çalışmaz; dokunma dağılımı temiz kalır (§12.3).
                let r = input.space(into: self,
                                    fieldProtectsLiteral: condition == .calibrationReplay)
                keyLog.append("␣")
                shift.didInterruptChain()
                if wordIndex < prompt.words.count { wordIndex += 1 }
                log("space", commit: commitRecord(r))
            case .backspace:
                input.backspaceTap(into: self)
                keyLog.append("⌫")
                session.hadBackspace = true
                shift.didInterruptChain()
                log("backspace", suggestions: suggestionSnapshot())
            case .ret:
                input.newline(into: self)
                keyLog.append("⏎")
                log("newline")
            case .shift:
                shift.tapShift(at: CACurrentMediaTime())
                keyLog.append("⇧")
                log("shift")
            case .numbers: keyboardView.plane = .numbers; shift.didInterruptChain(); log("plane.numbers")
            case .symbols: keyboardView.plane = .symbols; shift.didInterruptChain(); log("plane.symbols")
            case .letters: keyboardView.plane = .letters; shift.didInterruptChain(); log("plane.letters")
            case .globe: break
            }
        }
        syncKeyboardState()
        refresh()
        persist()
    }

    private func handleRepeat(_ hit: KeyboardView.KeyHit, _ stage: KeyboardView.RepeatStage) {
        guard case .function(.backspace) = hit, engineReady else { return }
        switch stage {
        case .character: input.backspaceRepeat(into: self)
        case .word: input.deleteWord(into: self)
        }
        session.hadBackspace = true
        keyLog.append("⌫·")
        log("backspaceRepeat")
        refresh()
        persist()
    }

    @objc private func pickSuggestion(_ sender: UIButton) {
        guard engineReady, let word = sender.title(for: .normal), !word.isEmpty else { return }
        let r = input.pickSuggestion(word, into: self)
        keyLog.append("[\(word)]")
        if wordIndex < prompt.words.count { wordIndex += 1 }
        log("suggestionPick", commit: commitRecord(r))
        refresh()
        persist()
    }

    /// `TokenCommitReport` → kayıt.
    ///
    /// `θ` sonsuz olabiliyor (`fieldProtectsLiteral` ya da kanalın koruma
    /// kararı). JSON sonsuzu taşıyamaz; `nil` + `literalProtected` ile
    /// kaydediliyor — "ölçülmedi" ile "korundu" ayrı şeyler.
    private func commitRecord(_ r: InputCoordinator.TokenCommitReport)
        -> TypingSession.Action.Commit {
        let protected = (r.theta?.isFinite == false)
        let target = wordIndex > 0 && wordIndex - 1 < prompt.words.count
            ? PromptCorpus.turkishLowercased(prompt.words[wordIndex - 1])
                .trimmingCharacters(in: .punctuationCharacters)
            : nil
        return .init(
            kind: r.kind.rawValue, literal: r.literal,
            displayBefore: r.displayBefore, committed: r.committed,
            delta: r.delta?.isFinite == true ? r.delta : nil,
            theta: r.theta?.isFinite == true ? r.theta : nil,
            bestCost: r.bestCost, bestWord: r.bestWord,
            language: r.language.map(Int.init),
            touchCount: r.touchCount, casingApplied: r.casingApplied,
            literalProtected: protected,
            // §12.5: hedefli kayıtta niyet gözlemden değil **protokolden**
            // biliniyor; üretimin `.weak` kuralı burada geçerli değil.
            labelSource: condition == .calibrationReplay ? "protocol" : "production",
            confidence: condition == .calibrationReplay ? "strong" : "weak",
            targetWord: target,
            matchesTarget: target.map { PromptCorpus.turkishLowercased(r.literal) == $0 })
    }

    private func syncKeyboardState() {
        keyboardView.isUppercase = shift.isUppercase
        keyboardView.isShiftLocked = shift.mode == .locked
    }

    // MARK: - Çizim

    private func refresh() {
        switch condition {
        case .calibrationReplay:
            // Hedef **kelime kelime**: hangi dokunmanın hangi kelimeye ait
            // olduğu böylece bir çıkarım değil, UI durumunun kaydı oluyor.
            promptLabel.text = wordIndex < prompt.words.count
                ? prompt.words[wordIndex] : "— bitti —"
            progressLabel.text = "\(min(wordIndex + 1, prompt.words.count))/\(prompt.words.count)"
                + " · yazıp boşluğa bas · yazdığın GÖRÜNMÜYOR (bilerek)"
            // Yazılan metin gizli: kullanıcı kendi hatasını görürse düzeltmeye
            // çalışır ve düzeltme sonrası harfler daha dikkatli basılır.
            typedLabel.text = String(repeating: "•", count: input.session.literal.count)
        case .behavior:
            promptLabel.text = prompt.text
            progressLabel.text = "kelime \(min(wordIndex + 1, prompt.words.count))/\(prompt.words.count)"
            typedLabel.text = buffer + (input.session.literal.isEmpty ? "" : "")
            let s = input.suggestionSurfaces()
            for (i, b) in suggestionStack.arrangedSubviews.enumerated() {
                let btn = b as? UIButton
                btn?.setTitle(i < s.count ? s[i] : "", for: .normal)
                btn?.isHidden = i >= s.count
            }
        }
        logLabel.text = keyLog.suffix(60).joined(separator: " ")
    }
}

// MARK: - Belge tamponu

extension RecorderViewController: DocumentEditor {
    func insertText(_ text: String) { buffer += text }
    func deleteBackward() { if !buffer.isEmpty { buffer.removeLast() } }
    var contextBeforeInput: String? { buffer }
    var contextAfterInput: String? { "" }
    /// Kayıt ekranında seçim yok — host yok, imleç daima sonda.
    var selectedText: String? { nil }
}

// MARK: - SwiftUI sarmalayıcı

struct RecorderView: UIViewControllerRepresentable {
    let prompt: PromptCorpus.Prompt
    let condition: TypingSession.Condition
    let posture: TypingSession.Posture
    let participantID: String
    let sessionOrdinal: Int
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> RecorderViewController {
        RecorderViewController(prompt: prompt, condition: condition, posture: posture,
                               participantID: participantID, sessionOrdinal: sessionOrdinal,
                               onFinish: onFinish)
    }
    func updateUIViewController(_ vc: RecorderViewController, context: Context) {}
}

// MARK: - Liste ekranı

/// Kayıt oturumlarının listesi — §12'nin 3 adımının birincisi.
///
/// Abort oranı burada **görünür**: yalnız tamamlananları göstermek, kullanıcıya
/// da analize de tarafsız bir popülasyon varmış izlenimi verirdi (§12.6).
struct RecordingListView: View {
    @State private var sessions: [TypingSession] = []
    @State private var showingNew = false
    @State private var active: ActiveRecording?
    @State private var confirmDeleteAll = false

    /// Kararlı ve anonim katılımcı kimliği. Cihaz başına bir kez üretilir;
    /// birden çok katılımcının verisi sonradan birleştirilebilsin diye var.
    @AppStorage("participantID") private var participantID = ""

    private struct ActiveRecording: Identifiable {
        let id = UUID()
        let prompt: PromptCorpus.Prompt
        let condition: TypingSession.Condition
        let posture: TypingSession.Posture
        let ordinal: Int
    }

    var body: some View {
        List {
            Section {
                if sessions.isEmpty {
                    Text("Henüz kayıt yok. Sağ üstteki + ile başla.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions, id: \.attemptID) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(s.promptText).lineLimit(1)
                            Spacer()
                            Text(statusMark(s.status)).foregroundStyle(color(s.status))
                        }
                        Text("\(s.condition.rawValue) · \(s.split) · "
                             + "\(s.touches.count) dokunma · \(s.actions.count) eylem")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    for i in idx { try? SessionStore.delete(sessions[i].attemptID) }
                    reload()
                }
            } header: {
                Text("Kayıtlar — \(completedCount)/\(sessions.count) tamamlandı")
            } footer: {
                Text("Vazgeçilen denemeler de kayıtta kalır: yalnız tamamlananları "
                     + "saklamak seçim yanlılığı üretir (§12.6).")
            }

            Section("Tuş kapsayışı") {
                let missing = PromptCorpus.underCovered(PromptCorpus.all,
                                                        layout: TurkishQ.layout())
                if missing.isEmpty {
                    Text("Korpustaki her tuş ≥ 20 kez geçiyor.").font(.caption)
                } else {
                    Text("Eşiğin (20) altında: " + missing.map(String.init).joined(separator: " "))
                        .font(.caption)
                    Text("q, w, x Türkçede yok — bu üç tuşun kendi katmanı açılmaz, "
                         + "satır ve global katmandan beslenirler.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Tüm kayıtları sil", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("Kayıtlar ham dokunma koordinatı içerir ve kişisel veridir; "
                     + "yedeğe gitmez, cihaz kilitliyken korunur (§12.9).")
            }
        }
        .navigationTitle("Yazım kayıtları")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewRecordingSheet { prompt, condition, posture in
                showingNew = false
                active = ActiveRecording(prompt: prompt, condition: condition,
                                         posture: posture, ordinal: sessions.count)
            }
        }
        .fullScreenCover(item: $active) { rec in
            NavigationStack {
                RecorderView(prompt: rec.prompt, condition: rec.condition,
                             posture: rec.posture,
                             participantID: participantID,
                             sessionOrdinal: rec.ordinal) {
                    active = nil
                    reload()
                }
                .ignoresSafeArea(.keyboard)
            }
        }
        .alert("Tüm kayıtlar silinsin mi?", isPresented: $confirmDeleteAll) {
            Button("Sil", role: .destructive) { try? SessionStore.deleteAll(); reload() }
            Button("Vazgeç", role: .cancel) {}
        }
        .onAppear {
            if participantID.isEmpty { participantID = UUID().uuidString.prefix(8).lowercased() }
            reload()
        }
    }

    private var completedCount: Int { sessions.filter { $0.status == .completed }.count }
    private func reload() { sessions = SessionStore.load() }

    private func statusMark(_ s: TypingSession.Status) -> String {
        switch s {
        case .completed: return "tamam"
        case .aborted: return "vazgeçildi"
        case .interrupted: return "kesildi"
        case .invalid: return "geçersiz"
        case .inProgress: return "yarım"
        }
    }
    private func color(_ s: TypingSession.Status) -> Color {
        s == .completed ? .green : (s == .invalid ? .red : .orange)
    }
}

/// Yeni kayıt — §12'nin 2. adımı: koşul, duruş ve hedef seçimi.
struct NewRecordingSheet: View {
    let onStart: (PromptCorpus.Prompt, TypingSession.Condition, TypingSession.Posture) -> Void

    @State private var condition: TypingSession.Condition = .calibrationReplay
    @State private var hands: TypingSession.Posture.Hands = .twoThumbs
    @State private var mobility: TypingSession.Posture.Mobility = .seated
    @State private var useManual = false
    @State private var manualText = ""
    @State private var selected: PromptCorpus.Prompt = PromptCorpus.all[0]
    @Environment(\.dismiss) private var dismiss

    private var unsupported: [Character] {
        PromptCorpus.unsupportedCharacters(in: manualText, layout: TurkishQ.layout())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Koşul", selection: $condition) {
                        Text("Kalibrasyon").tag(TypingSession.Condition.calibrationReplay)
                        Text("Davranış").tag(TypingSession.Condition.behavior)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(condition == .calibrationReplay
                         ? "Hedef kelime kelime gelir, yazdığın GÖRÜNMEZ ve düzeltme "
                           + "uygulanmaz. Kendi hatanı göremediğin için düzeltmeye "
                           + "çalışmazsın — dokunma dağılımı temiz kalır."
                         : "Gerçek klavye: öneriler dokunulabilir, düzeltme uygulanır. "
                           + "Karar davranışını ölçmek için.")
                }

                Section("Duruş") {
                    Picker("El", selection: $hands) {
                        Text("İki başparmak").tag(TypingSession.Posture.Hands.twoThumbs)
                        Text("Tek başparmak").tag(TypingSession.Posture.Hands.oneThumb)
                        Text("İşaret parmağı").tag(TypingSession.Posture.Hands.indexFinger)
                    }
                    Picker("Hareket", selection: $mobility) {
                        Text("Otururken").tag(TypingSession.Posture.Mobility.seated)
                        Text("Ayakta").tag(TypingSession.Posture.Mobility.standing)
                        Text("Yürürken").tag(TypingSession.Posture.Mobility.walking)
                    }
                }

                Section("Hedef") {
                    Toggle("Kendi cümlemi yazayım", isOn: $useManual)
                    if useManual {
                        TextField("hedef cümle", text: $manualText, axis: .vertical)
                            .lineLimit(2...5)
                            .autocorrectionDisabled()
                        if !unsupported.isEmpty {
                            Text("Bu klavyede yazılamayan karakter: "
                                 + unsupported.map(String.init).joined(separator: " "))
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Picker("Cümle", selection: $selected) {
                            ForEach(PromptCorpus.all) { p in
                                Text("\(p.id) · \(p.text)").tag(p)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Yeni kayıt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Başla") {
                        let p = useManual
                            ? PromptCorpus.Prompt(id: "manual-\(UUID().uuidString.prefix(4))",
                                                  text: manualText.trimmingCharacters(in: .whitespaces),
                                                  split: .dev)
                            : selected
                        onStart(p, condition,
                                .init(hands: hands, mobility: mobility))
                    }
                    .disabled(useManual && (manualText.trimmingCharacters(in: .whitespaces).isEmpty
                                            || !unsupported.isEmpty))
                }
            }
        }
    }
}
