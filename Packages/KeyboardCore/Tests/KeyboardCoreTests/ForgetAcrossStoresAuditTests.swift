import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBRuntime

final class ForgetAcrossStoresAuditTests: XCTestCase {
    func testForgetVersusHistory() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_FORGET_STORES_AUDIT"] else { throw XCTSkip("Set KB_FORGET_STORES_AUDIT") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["qrmenü", "cepmenü", "pikselköy", "bulutnot"] {
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            let doc = FakeDocument()
            for ch in word {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: key.center), into: doc)
            }
            let pick = try XCTUnwrap(c.suggestions().first)
            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
            XCTAssertTrue(c.personal.isAdmitted(word))
            var history = PersonalHistory()
            // Mirrors the independent history store's completed-token observation.
            history.observe(token: word, previous: "selam")
            let before = history.nextWords(after: "selam")
            XCTAssertTrue(c.forgetPersonal(word))
            XCTAssertFalse(c.personal.isAdmitted(word))
            let restoredHistory = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
            rows.append(["word": word, "personal_after_forget": String(c.personal.isAdmitted(word)),
                "vocabulary_after_forget": String(c.engine!.literalChannel.score(word).isInVocabulary),
                "history_before": before.joined(separator: " | "),
                "history_after": history.nextWords(after: "selam").joined(separator: " | "),
                "history_after_serialization": restoredHistory.nextWords(after: "selam").joined(separator: " | "),
                "recall_after": history.recall(prefix: String(word.prefix(3))).joined(separator: " | ")])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
