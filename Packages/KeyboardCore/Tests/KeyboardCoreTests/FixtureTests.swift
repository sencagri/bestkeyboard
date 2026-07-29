import Foundation
import Testing
@testable import KBAssembly
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Depoda duran v3 kaydı — plan v8 §2.10.
///
/// ## Neden diskte bir dosya
///
/// Kod içinde kurulan bir fixture şemayla **birlikte** güncelleniyor: bir alan
/// eklendiğinde derleyici onu zorluyor ve test yeşil kalıyor. Diskteki dosya
/// ise donuk; şema geriye dönük uyumsuz değişirse okunamaz hâle geliyor ve
/// karar (migrasyon mu, sürüm artırımı mı) **açıkça** verilmek zorunda kalıyor.
///
/// Dosyayı yenilemek için: `BK_REGENERATE_FIXTURE=1 swift test --filter Fixture`
@Suite("Kayıt fixture'ı")
struct FixtureTests {

    private static let fixtureName = "golden-v3.bkj"

    private static var bundledURL: URL? {
        Bundle.module.url(forResource: "Fixtures/\(fixtureName)",
                          withExtension: nil)
            ?? Bundle.module.url(forResource: fixtureName, withExtension: nil)
    }

    private static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixtureName)")
    }

    /// Fixture'ı üreten yol — golden testinin kullandığının aynısı.
    private func makeJournal() throws -> Data {
        let l = Self.layout
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LanguagePacks")
        let source = DirectoryPackSource(root: root)
        let loaded = try PackLoader.load(layout: l, source: source,
                                         computeHashes: true)
        var coordinator = InputCoordinator(layout: l)
        coordinator.setEngine(.init(decoder: loaded.decoder,
                                    literalChannel: loaded.literalChannel,
                                    expansions: loaded.expansions))

        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer, coordinator: coordinator,
                                     layout: l)
        var descriptor = CanonicalSession(
            attemptID: "fixture-v3", participantID: "fixture",
            sessionOrdinal: 0, condition: .behavior, status: .recording,
            promptID: "f1", promptText: "kalem ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["kalem", "ev"]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engine: .unconfigured(),
            geometry: .init(layoutID: l.id,
                            layoutFingerprint: .known(l.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "fixture", systemVersion: "18"))
        descriptor.engine = .capture(
            loaded: loaded, coordinator: coordinator,
            buildConfiguration: "Debug", appVersion: "fixture",
            build: .init(codeRevision: .known("fixture"),
                         provenance: .known(.init(sourceTree: .clean,
                                                  swiftVersion: "6",
                                                  targetTriple: "t",
                                                  arch: "arm64",
                                                  optimization: "-Onone",
                                                  xcodeVersion: "0"))),
            policy: .behavior,
            calibration: .init(applied: false, strongSamples: 0,
                               biasX: [], biasY: [],
                               hierarchical: .init(globalX: 0, globalY: 0,
                                                   rowX: [], rowY: [],
                                                   keyX: [], keyY: []),
                               sigma: .known(.init(x: [], y: []))))

        try engine.begin(descriptor, at: 0)
        let doc = Doc()
        var id = 0
        var t = 0.0
        for word in ["kalem", "ev"] {
            for ch in word {
                t += 0.1
                let index = l.keyIndex(for: ch)
                let c = index.map { l.keys[$0].center } ?? .init(x: 0.5, y: 0.5)
                try engine.record(.init(touchID: id, phase: .ended,
                                        outcome: .committed,
                                        rawX: c.x * 393, rawY: c.y * 216,
                                        normX: c.x, normY: c.y,
                                        decoderX: c.x, decoderY: c.y,
                                        timestamp: t, majorRadius: 5,
                                        majorRadiusTolerance: 1,
                                        plane: "letters", shift: "off",
                                        hitKind: "letter", key: String(ch),
                                        keyIndex: index))
                try engine.perform(.init(command: .letter(baseKey: String(ch),
                                                          display: String(ch),
                                                          shifted: false),
                                         touchID: id, timestamp: t), into: doc)
                id += 1
            }
            t += 0.1
            try engine.perform(.init(command: .space, timestamp: t), into: doc)
        }
        _ = try engine.finish(.completed, at: t + 1, finalText: doc.text)
        return writer.data
    }

    /// **Asıl kapı.** Depodaki dosya bugünkü kodla okunabiliyor ve
    /// doğrulamadan geçiyor mu?
    @Test("Depodaki v3 kaydı okunuyor ve doğrulanıyor")
    func fixtureLoadsAndValidates() throws {
        if ProcessInfo.processInfo.environment["BK_REGENERATE_FIXTURE"] == "1" {
            try makeJournal().write(to: Self.sourceURL)
            Issue.record("fixture yeniden üretildi: \(Self.sourceURL.path)")
            return
        }
        let url = try #require(Self.bundledURL,
                               "fixture bundle'da yok — Package.swift resources?")
        let data = try Data(contentsOf: url)

        let loaded = try SessionJournal.load(data).get()
        #expect(!loaded.truncatedTail)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(Self.fixtureName))
        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")

        let session = try #require(listing.entries.first).session
        #expect(session.attemptID == "fixture-v3")
        #expect(session.status == .completed)
        #expect(session.finalText == "kalem ev ")

        let findings = SessionValidator.validate(session)
        #expect(findings.isEmpty, "\(findings)")

        let state = SessionEventReducer.reduce(session)
        #expect(state.tokens.count == 2)
        #expect(state.violations.isEmpty)
        #expect(state.unverifiable.isEmpty)

        #expect(try DocumentReconstruction.replay(session) == "kalem ev ")
    }

    private final class Doc: DocumentEditor {
        private(set) var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

    private static let layout: KeyLayout = {
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
}
