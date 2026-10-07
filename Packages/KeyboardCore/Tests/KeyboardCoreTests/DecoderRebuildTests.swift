import Foundation
import Testing
import KBAssembly
import KBDecoder
import KBGeometry
import KBLexicon
import KBRuntime
import KBSessions
import KBSpatial

/// Decoder'ın **yeniden kurulumu** — `Decoder.with(spatial:)` / `with(lexicon:)`.
///
/// Kalibrasyon uygulanınca decoder yeni bir uzamsal modelle yeniden kuruluyor.
/// Bu dört yerde elle yazılıyordu ve yalnız `InputCoordinator` bigram paketini,
/// bağlamı ve dil durumunu taşıyordu: kayıt motoru ve replay fabrikası onları
/// düşürüyordu, yani kalibre bir kayıtta `F_ctx` sessizce kapalıydı.
@MainActor
@Suite("Decoder yeniden kurulumu")
struct DecoderRebuildTests {

    /// Gerçek paketlere sentetik bir bigram paketi ekleyen kaynak.
    ///
    /// Depoda `.bkg` yok; olmadan "bigram düştü mü" sorusu sorulamaz (düşecek
    /// bir şey yok).
    private struct WithBigrams: PackSource {
        let base: PackSource
        let bigrams: Data

        func read(_ name: String, _ ext: String) -> (url: URL, data: Data)? {
            if name == "tr-TR", ext == "bkg" {
                return (URL(fileURLWithPath: "/synthetic/tr-TR.bkg"), bigrams)
            }
            return base.read(name, ext)
        }
    }

    /// `ev → kalem` çiftine sınıra dayanan negatif delta veren paket.
    private static func bigramPack() throws -> Data {
        let (bytes, _) = try BigramPackBuilder().build(
            unigrams: ["ev": 1_000, "kalem": 10, "masa": 1_000_000],
            bigrams: [BigramCount(context: "ev", word: "kalem", count: 50)])
        return Data(bytes)
    }

    private static func source(withBigrams: Bool) throws -> PackSource {
        let base = RecordingTestSupport.packSource
        return withBigrams ? WithBigrams(base: base, bigrams: try bigramPack()) : base
    }

    private static var layout: KeyLayout { RecordingTestSupport.layout }

    /// Sıfır olmayan, tuş başına farklı bir kalibrasyon — sıfır sapma
    /// uygulanmasa da fark üretmez ve yeniden kurulum yolu hiç koşmazdı.
    private static var calibration: CanonicalSession.EngineSnapshot.CalibrationSnapshot {
        let n = layout.keys.count
        return .init(
            applied: true, strongSamples: 100,
            biasX: (0..<n).map { Double($0 % 5) * 0.004 - 0.008 },
            biasY: (0..<n).map { Double($0 % 3) * 0.005 - 0.005 },
            hierarchical: .init(globalX: 0, globalY: 0, rowX: [], rowY: [],
                                keyX: [], keyY: []),
            sigma: .known(.init(x: Array(repeating: 0.05, count: n),
                                y: Array(repeating: 0.06, count: n))))
    }

    /// Kalibre motorla `words`'ü yazan bir kayıt alır ve oturuma katlar.
    private static func record(_ words: [String], source: PackSource) throws
        -> CanonicalSession {
        let l = layout
        let loaded = try PackLoader.load(layout: l, source: source, computeHashes: true)
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer,
                                     coordinator: InputCoordinator(layout: l),
                                     layout: l)
        let descriptor = CanonicalSession(
            attemptID: "rebuild", participantID: "p", sessionOrdinal: 0,
            condition: .behavior, status: .recording,
            promptID: "r", promptText: words.joined(separator: " "),
            promptSource: .builtin, split: "train",
            promptTokens: .known(words), alignmentSource: .sequential,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: RecordingTestSupport.unconfigured(),
            geometry: .init(layoutID: l.id, layoutFingerprint: .known(l.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "test", systemVersion: "18"))
        try engine.begin(descriptor, at: 0)
        try engine.configure(loaded: loaded, calibration: calibration)

        let doc = RecordingTestSupport.Doc()
        var id = 0, t = 0.0
        for word in words {
            for ch in word {
                t += 0.1
                try engine.record(RecordingTestSupport.touch(id, char: ch, t: t))
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writer.data.write(to: dir.appendingPathComponent("r.bkj"))
        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        return try #require(listing.entries.first).session
    }

    /// Kayıttaki son `word` adayının maliyeti.
    private static func recordedCost(of word: String, in s: CanonicalSession) -> Double? {
        s.actions.reversed().lazy
            .compactMap { $0.candidates.value?.first { $0.word == word }?.cost }
            .first
    }

    @Test("with(spatial:) değişebilir durumun tamamını taşıyor")
    func withSpatialCarriesState() throws {
        let loaded = try PackLoader.load(layout: Self.layout,
                                         source: try Self.source(withBigrams: true))
        var d = loaded.decoder
        d.contextWord = "ev"
        d.languageModel.previous = 1
        d.languageModel.prior = [1: 0.5]

        var model = SpatialModel(layout: Self.layout)
        var shifted = model.calib[0]
        shifted.biasX = 0.01
        model.setCalibration(shifted, at: 0)
        let fresh = d.with(spatial: model)

        #expect(fresh.bigrams != nil)
        #expect(fresh.contextWord == "ev")
        #expect(fresh.languageModel.previous == 1)
        #expect(fresh.languageModel.prior == [1: 0.5])
        #expect(fresh.beamWidth == d.beamWidth)
        #expect(fresh.spatial.calib[0].biasX == 0.01)
        #expect(fresh.lexicon.sources.count == d.lexicon.sources.count)

        let relexed = d.with(lexicon: LexiconSet(sources: Array(d.lexicon.sources.prefix(1))))
        #expect(relexed.bigrams != nil)
        #expect(relexed.contextWord == "ev")
        #expect(relexed.lexicon.sources.count == 1)
    }

    /// **Kayıt motoru**: kalibrasyon uygulandıktan sonra da `F_ctx` çalışıyor.
    ///
    /// Kanıt kayıttaki aday maliyeti: `ev` bağlamında `kalem`, paket varken
    /// paketsiz kayda göre **ucuz** olmalı. Bigram düşseydi iki maliyet
    /// birebir aynı çıkardı.
    @Test("Kalibre kayıtta bigram paketi düşmüyor")
    func calibratedRecordingKeepsBigrams() throws {
        let with = try Self.record(["ev", "kalem"], source: try Self.source(withBigrams: true))
        let without = try Self.record(["ev", "kalem"], source: try Self.source(withBigrams: false))
        #expect(with.engine.configuration.value?.calibration.applied == true)

        let a = try #require(Self.recordedCost(of: "kalem", in: with))
        let b = try #require(Self.recordedCost(of: "kalem", in: without))
        #expect(a < b - 1, "bigram uygulanmadı: \(a) ↔ \(b)")
    }

    /// **Replay**: kalibrasyonu uygulayan fabrika da paketi taşıyor ve kayıt
    /// birebir yeniden üretiliyor.
    @Test("Kalibre kaydın replay'i bigram paketini taşıyor")
    func calibratedReplayKeepsBigrams() throws {
        let source = try Self.source(withBigrams: true)
        let s = try Self.record(["ev", "kalem"], source: source)

        let built = try ReplayEngineFactory.make(for: s, layout: Self.layout, packs: source)
        #expect(built.coordinator.engine?.decoder.bigrams != nil)

        let report = try GoldenReplay.run(s, layout: Self.layout, packs: source)
        #expect(report.divergences.isEmpty, "\(report.divergences)")
    }
}
