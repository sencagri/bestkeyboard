import Foundation
import KBAssembly
import KBGeometry
import KBRuntime
@testable import KBSessions

/// Kayıt testlerinin ortak kurulumu.
///
/// Paketler **süreç başına bir kez** yükleniyor: her testte 2.7 MB trie'yi
/// yeniden ayrıştırmak testi yavaşlatıp hiçbir şey kanıtlamıyor. Motorun
/// gerçek paketlerle kurulması ise önemli — sahte bir motorla koşan kayıt
/// testi, üretimde çalışmayan bir yolu doğrulardı.
enum RecordingTestSupport {

    static let packRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KeyboardCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // KeyboardCore
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repo kökü
        .appendingPathComponent("LanguagePacks")

    static var packSource: PackSource { DirectoryPackSource(root: packRoot) }

    /// Türkçe Q düzeninin ölçüm için yeterli bir yaklaşımı.
    static let layout: KeyLayout = {
        let rows = ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"]
        var keys: [Key] = []
        for (r, row) in rows.enumerated() {
            let w = 1.0 / Double(row.count)
            for (c, ch) in row.enumerated() {
                keys.append(Key(char: ch,
                                center: .init(x: (Double(c) + 0.5) * w,
                                              y: (Double(r) + 0.5) / 3),
                                width: w, height: 1.0 / 3))
            }
        }
        return KeyLayout(id: "tr-q-test", keys: keys,
                         asciiBase: ["ı": "i", "ğ": "g", "ü": "u", "ş": "s",
                                     "ö": "o", "ç": "c"])
    }()

    /// Süreç başına bir kez yüklenen paketler.
    ///
    /// `nonisolated(unsafe)`: `PackLoader.Loaded` `Sendable` değil (mmap'lenmiş
    /// tampon tutuyor) ama burada **değişmez** ve `static let` başlatması
    /// Swift'te zaten tek seferlik ve thread-safe. Paralel testler yalnız
    /// okuyor.
    nonisolated(unsafe) static let loaded: PackLoader.Loaded = {
        // Yükleme başarısızsa test **çökmeli**: sessizce boş bir motorla
        // devam etmek, kayıt testlerini gerçekte olmayan bir davranış üzerinde
        // yeşil gösterirdi.
        try! PackLoader.load(layout: layout, source: packSource,
                             computeHashes: true)
    }()

    static let blankCalibration =
        CanonicalSession.EngineSnapshot.CalibrationSnapshot(
            applied: false, strongSamples: 0, biasX: [], biasY: [],
            hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                keyX: [], keyY: []),
            sigma: .known(.init(x: [], y: [])))

    /// Deneme başlarken bilinen motor olguları.
    ///
    /// Testlerin `.unconfigured()`'ı boş çağırması, native bir kaydı bilinmeyen
    /// derleme ve politikayla üretiyordu; validator onu haklı olarak bozuk
    /// sayıyordu. Tek kaynak burada.
    static func unconfigured(policy: RecordingPolicy = .behavior)
        -> CanonicalSession.EngineSnapshot {
        .unconfigured(buildConfiguration: "Debug", appVersion: "test",
                      build: build, policy: .init(policy))
    }

    static let build = CanonicalSession.EngineSnapshot.BuildManifest(
        codeRevision: .known("test"),
        provenance: .known(.init(sourceTree: .clean, swiftVersion: "6",
                                 targetTriple: "t", arch: "arm64",
                                 optimization: "-Onone", xcodeVersion: "0")))

    /// Yapılandırılmış bir motor kurar.
    @MainActor
    static func engine(writer: SessionJournalWriter,
                       policy: RecordingPolicy = .behavior) -> RecordingEngine {
        RecordingEngine(writer: writer,
                        coordinator: InputCoordinator(layout: layout),
                        layout: layout)
    }

    /// Politika artık **`begin`'den** geliyor; `configure` onu sormuyor.
    @MainActor
    static func configure(_ engine: RecordingEngine) throws {
        try engine.configure(loaded: loaded, calibration: blankCalibration)
    }

    /// Basit belge tamponu — replay'in kullandığı **aynı** tampon.
    typealias Doc = TextBuffer

    /// Tuşun merkezine dokunan bir örnek.
    static func touch(_ id: Int, char: Character,
                      t: TimeInterval) -> CanonicalSession.Touch {
        let index = layout.keyIndex(for: char)
        let c = index.map { layout.keys[$0].center } ?? .init(x: 0.5, y: 0.5)
        return .init(touchID: id, phase: .ended, outcome: .committed,
                     rawX: c.x * 393, rawY: c.y * 216,
                     normX: c.x, normY: c.y, decoderX: c.x, decoderY: c.y,
                     timestamp: t, majorRadius: 5, majorRadiusTolerance: 1,
                     plane: "letters", shift: "off",
                     hitKind: "letter", key: String(char), keyIndex: index)
    }

    // MARK: - Kayıt senaryosu

    /// Bir denemenin tanımı — hedef dizisi ve koşulla.
    static func descriptor(prompt: [String],
                           condition: CanonicalSession.Condition = .behavior)
        -> CanonicalSession {
        CanonicalSession(
            attemptID: "golden", participantID: "p", sessionOrdinal: 0,
            condition: condition, status: .recording,
            promptID: "g", promptText: prompt.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(prompt),
            alignmentSource: condition == .calibrationReplay
                ? .constructed : .sequential,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: unconfigured(policy: condition == .calibrationReplay
                                    ? .calibration : .behavior),
            geometry: .init(layoutID: layout.id,
                            layoutFingerprint: .known(layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "test", systemVersion: "18"))
    }

    /// Kaydı **komutlarla** süren senaryo: harfler kendi dokunmalarıyla,
    /// diğer komutlar zarfsız.
    @MainActor
    final class Script {
        let engine: RecordingEngine
        let doc = Doc()
        private var touchID = 0
        private(set) var t = 0.0

        init(engine: RecordingEngine) { self.engine = engine }

        /// Kelimeyi tuş merkezlerine dokunarak yazar.
        func type(_ word: String, shifted: Bool = false) throws {
            for ch in word {
                t += 0.1
                try engine.record(touch(touchID, char: ch, t: t))
                let display = shifted ? TurkishText.uppercased(ch) : String(ch)
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: display,
                                                          shifted: shifted),
                                         touchID: touchID, timestamp: t),
                                   into: doc)
                touchID += 1
            }
        }

        /// Dokunmasız bir komut.
        @discardableResult
        func command(_ c: ReplayCommand) throws -> CanonicalSession.Action {
            t += 0.1
            return try engine.perform(.init(command: c, timestamp: t), into: doc)
        }
    }

    /// Bir denemeyi kaydeder ve günlüğü döndürür.
    @MainActor
    static func record(prompt: [String],
                       condition: CanonicalSession.Condition = .behavior,
                       calibration: CanonicalSession.EngineSnapshot
                           .CalibrationSnapshot = blankCalibration,
                       _ drive: (Script) throws -> Void) throws -> Data {
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer,
                                     coordinator: InputCoordinator(layout: layout),
                                     layout: layout)
        try engine.begin(descriptor(prompt: prompt, condition: condition), at: 0)
        try engine.configure(loaded: loaded, calibration: calibration)
        let script = Script(engine: engine)
        try drive(script)
        _ = try engine.finish(.completed, at: script.t + 1,
                              finalText: script.doc.text)
        return writer.data
    }

    /// Hedef cümleyi kelime kelime yazıp boşlukla kapatan deneme.
    @MainActor
    static func record(_ words: [String],
                       condition: CanonicalSession.Condition = .behavior,
                       calibration: CanonicalSession.EngineSnapshot
                           .CalibrationSnapshot = blankCalibration) throws -> Data {
        try record(prompt: words, condition: condition, calibration: calibration) {
            for w in words {
                try $0.type(w)
                try $0.command(.space)
            }
        }
    }

    /// Günlüğü **diskten okuyarak** kanonik oturuma katlar — okuyucu yolu da
    /// sınansın diye.
    static func session(from journal: Data) throws -> CanonicalSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        try journal.write(to: dir.appendingPathComponent("g.bkj"))
        let listing = RecordingLibrary.list(in: dir)
        guard listing.failures.isEmpty, let first = listing.entries.first else {
            throw ScriptError.unreadable("\(listing.failures)")
        }
        return first.session
    }

    enum ScriptError: Error { case unreadable(String) }
}

extension TextBuffer {
    /// Host'un yaptığı, bizim bilmediğimiz değişiklik — yalnız testler.
    func hostRewrites(to s: String) { text = s }
}
