import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class PhraseReopenLearningAuditTests: XCTestCase {
    func testRepeatedPhraseReopenLearning() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_PHRASE_REOPEN_LEARNING_AUDIT"] else { throw XCTSkip("Opt-in repeated learning audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for (left, right) in [("merhaba", "dünya"), ("iyi", "ki"), ("su", "iç"), ("qrmenüden", "aç")] {
            for leading in ["", "önce "] {
                for mode in ["typed", "missing_space_pick", "mistap_pick"] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    var personal = PersonalLexicon(); personal.observe("qrmenü", confidence: .strong)
                    c.replacePersonalLexicon(personal)
                    var observation = HistoryObservation(); var history = PersonalHistory()
                    let id = UUID(); let doc = FakeDocument()
                    observation.changed(before: "", documentID: id)
                    func type(_ text: String) throws {
                        for ch in text {
                            if ch == " " {
                                c.space(into: doc)
                                if let event = observation.completed(before: doc.text, documentID: id, after: "") { history.observe(event) }
                            } else {
                                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                            }
                            observation.changed(before: doc.text, documentID: id, after: "")
                        }
                    }
                    try type(leading)
                    let phrase = left + " " + right
                    if mode == "typed" { try type(phrase + " ") }
                    else {
                        try type(left + (mode == "mistap_pick" ? "b" : "") + right)
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
                        let before = doc.text
                        let replacing = c.session.display
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        for event in observation.completedReplacement(before: before, after: "", resultingBefore: doc.text,
                            resultingAfter: "", replacing: replacing, inserted: phrase + " ", documentID: id) { history.observe(event) }
                        if let event = observation.completed(before: doc.text, documentID: id, after: "") { history.observe(event) }
                        observation.changed(before: doc.text, documentID: id, after: "")
                    }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let originalArchive = try encoder.encode(history)
                    var expected = PersonalHistory(); expected.observe(text: leading + phrase + " ")
                    for cycle in 1...8 {
                        observation.expectBackwardDeletion(before: doc.text, after: "", documentID: id)
                        c.backspaceTap(into: doc)
                        observation.changed(before: doc.text, documentID: id, after: "")
                        c.space(into: doc)
                        var emitted = 0
                        // UIKit can issue repeated refresh callbacks for one boundary.
                        for _ in 0..<3 {
                            if let event = observation.completed(before: doc.text, documentID: id, after: "") {
                                emitted += 1; history.observe(event)
                            }
                            observation.changed(before: doc.text, documentID: id, after: "")
                        }
                        let tokensMatch = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                        let pairsMatch = history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                        rows.append(["phrase": phrase, "mode": mode, "leading": leading, "cycle": String(cycle),
                                     "tokens_match": String(tokensMatch), "pairs_match": String(pairsMatch),
                                     "archive_unchanged": String(try encoder.encode(history) == originalArchive),
                                     "events": String(emitted), "text_exact": String(doc.text == leading + phrase + " ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
