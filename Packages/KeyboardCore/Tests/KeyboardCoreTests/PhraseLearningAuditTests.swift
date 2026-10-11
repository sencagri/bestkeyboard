import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class PhraseLearningAuditTests: XCTestCase {
    func testPickedPhraseLearningMatchesTypedPhrase() throws {
        let output = ProcessInfo.processInfo.environment["KB_PHRASE_LEARNING_AUDIT"]
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
                                if let event = observation.completed(before: doc.text, documentID: id) { history.observe(event) }
                            } else {
                                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                            }
                            observation.changed(before: doc.text, documentID: id)
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
                        if let event = observation.completed(before: doc.text, documentID: id) { history.observe(event) }
                        observation.changed(before: doc.text, documentID: id)
                    }
                    XCTAssertEqual(doc.text, leading + phrase + " ")
                    var expected = PersonalHistory(); expected.observe(text: doc.text)
                    let tokensMatch = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                    let pairsMatch = history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                    let actualNext = history.nextWords(after: "önce")
                    let expectedNext = expected.nextWords(after: "önce")
                    XCTAssertTrue(tokensMatch, "\(mode): \(phrase)")
                    XCTAssertTrue(pairsMatch, "\(mode): \(phrase)")
                    XCTAssertEqual(actualNext, expectedNext)
                    c.backspaceTap(into: doc)
                    rows.append(["mode": mode, "leading": leading, "phrase": phrase,
                                 "token_counts_match": String(tokensMatch), "pair_counts_match": String(pairsMatch),
                                 "actual_tokens": history.tokens.keys.sorted().joined(separator: " | "),
                                 "expected_tokens": expected.tokens.keys.sorted().joined(separator: " | "),
                                 "actual_next": actualNext.joined(separator: " | "),
                                 "expected_next": expectedNext.joined(separator: " | "),
                                 "reopened": c.session.display,
                                 "reopened_tail_correct": String(c.session.display == right)])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("PHRASE LEARNING AUDIT: \(rows.count) observations")
    }

    func testReplacementIsOnceOnlyAndPreservesIndependentEvidence() {
        var observation = HistoryObservation(); var history = PersonalHistory()
        let id = UUID()
        history.observe(text: "önce merhaba dünya")
        observation.changed(before: "", documentID: id)
        if let event = observation.completed(before: "önce ", documentID: id) { history.observe(event) }
        observation.changed(before: "önce merhababdünya", documentID: id)
        for _ in 0..<3 {
            for event in observation.completedReplacement(before: "önce merhababdünya", after: "sonra",
                resultingBefore: "önce merhaba dünya ", resultingAfter: "sonra",
                replacing: "merhababdünya", inserted: "merhaba dünya ", documentID: id) { history.observe(event) }
            XCTAssertNil(observation.completed(before: "önce merhaba dünya ", documentID: id))
        }
        XCTAssertEqual(history.tokens["önce"]?.count, 2)
        XCTAssertEqual(history.tokens["merhaba"]?.count, 2)
        XCTAssertEqual(history.tokens["dünya"]?.count, 2)
        XCTAssertEqual(history.pairs["önce"]?["merhaba"]?.count, 2)
    }

    func testReopenedTypoRetractsOnlyItsObservedOccurrence() {
        var observation = HistoryObservation(); var history = PersonalHistory()
        let id = UUID()
        history.observe(token: "merhababdünya", previous: "önce")
        observation.changed(before: "", documentID: id)
        if let event = observation.completed(before: "önce merhababdünya ", documentID: id) { history.observe(event) }
        observation.changed(before: "önce merhababdünya", documentID: id)
        for event in observation.completedReplacement(before: "önce merhababdünya", after: "",
            resultingBefore: "önce merhaba dünya ", resultingAfter: "", replacing: "merhababdünya",
            inserted: "merhaba dünya ", documentID: id) { history.observe(event) }
        XCTAssertEqual(history.tokens["merhababdünya"]?.count, 1)
        XCTAssertEqual(history.pairs["önce"]?["merhababdünya"]?.count, 1)
        XCTAssertEqual(history.tokens["merhaba"]?.count, 1)
        XCTAssertEqual(history.tokens["dünya"]?.count, 1)
    }

    func testUnverifiedReplacementSnapshotsAreRejected() {
        for mode in ["different_document", "changed_after", "unchanged", "partial_source", "wrong_result"] {
            var observation = HistoryObservation(); let id = UUID()
            observation.changed(before: "", documentID: id)
            let result = observation.completedReplacement(before: "önce merhababdünya", after: "sonra",
                resultingBefore: mode == "unchanged" ? "önce merhababdünya" : (mode == "wrong_result" ? "önce merhaba dünyalar " : "önce merhaba dünya "),
                resultingAfter: mode == "changed_after" ? "başka" : "sonra",
                replacing: mode == "partial_source" ? "dünya" : "merhababdünya", inserted: "merhaba dünya ",
                documentID: mode == "different_document" ? UUID() : id)
            XCTAssertTrue(result.isEmpty, mode)
        }
    }

    func testNilRightContextStillLearnsVerifiedInsertedSpan() {
        for resultAfter: String? in [nil, "changed"] {
            var observation = HistoryObservation(); let id = UUID()
            observation.changed(before: "", documentID: id)
            let events = observation.completedReplacement(before: "önce merhababdünya", after: nil,
                resultingBefore: "önce merhaba dünya ", resultingAfter: resultAfter,
                replacing: "merhababdünya", inserted: "merhaba dünya ", documentID: id)
            XCTAssertEqual(events.count, resultAfter == nil ? 2 : 0)
            if resultAfter == nil { XCTAssertEqual(events.first?.previous, "önce") }
        }
    }
}
