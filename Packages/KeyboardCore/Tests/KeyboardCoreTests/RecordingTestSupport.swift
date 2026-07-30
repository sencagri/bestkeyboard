import Foundation
import KBAssembly
import KBGeometry
import KBRuntime
import KBSessions

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

    /// Basit belge tamponu.
    final class Doc: DocumentEditor {
        private(set) var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

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
}
