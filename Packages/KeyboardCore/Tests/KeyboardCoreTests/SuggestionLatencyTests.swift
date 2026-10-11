import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime
import KBLearning

final class SuggestionLatencyTests: XCTestCase {
    func testBoundedHistoryCompletionAndObservationLatency() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_HISTORY_LATENCY_AUDIT"] else { throw XCTSkip("Set KB_HISTORY_LATENCY_AUDIT") }
        var inbox = HistoryImportInbox()
        for source in ["WhatsApp", "Telegram", "Metin"] {
            var history = PersonalHistory()
            for i in 0..<PersonalHistory.tokenCapacity {
                history.observe(token: "https://example.com/" + source + "/item" + String(i), previous: nil)
            }
            inbox.append(history, source: source)
        }
        var archive = HistoryArchive()
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { _ in })
        var observations: [Double] = []
        var completions: [Double] = []
        for _ in 0..<30 {
            var start = DispatchTime.now().uptimeNanoseconds
            archive.observe(token: "merhaba", previous: "dünya")
            observations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            start = DispatchTime.now().uptimeNanoseconds
            _ = archive.history.completions(before: "https://example.com/M", after: "", selected: nil)
            completions.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        observations.sort(); completions.sort()
        let result: [String: Any] = ["observation_p95_ms": observations[28], "completion_p95_ms": completions[28],
            "source_count": 3, "entries_per_source": PersonalHistory.tokenCapacity,
            "scope": "Mac Release, full bounded histories, not physical phone"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    func testProductionTypingAndSuggestionLatency() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_LATENCY_AUDIT"] else { throw XCTSkip("Set KB_LATENCY_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var samples: [Double] = []
        let cases = ["merhabadünya", "merhababdünya", "evdeymişsiniz", "yapabilirseniz", "qrmenü", "graphql", "http", "kalemlerimizden"]
        for repetition in 0..<6 {
            for word in cases {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let index = try XCTUnwrap(layout.keyIndex(for: ch))
                    let start = DispatchTime.now().uptimeNanoseconds
                    c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
                    _ = c.suggestions()
                    if repetition > 0 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
                }
            }
        }
        samples.sort()
        let result: [String: Any] = ["samples": samples.count, "p50_ms": samples[samples.count / 2],
            "p95_ms": samples[Int(Double(samples.count - 1) * 0.95)], "max_ms": samples.last!,
            "scope": "Mac host, actual production packs, centered touches, core typing + visible suggestions; not physical iPhone measurement"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
