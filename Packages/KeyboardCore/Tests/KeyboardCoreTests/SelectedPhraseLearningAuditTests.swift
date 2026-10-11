import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class SelectedPhraseLearningAuditTests: XCTestCase {
    func testOutgoingPairPaddingAndRepeatedWitnessPreserveIndependentCounts() throws {
        for suffix in ["", ",", ".", "!", "?", ";", ":", "…"] {
            for padded in [false, true] {
                var observation = HistoryObservation(); var history = PersonalHistory()
                let id = UUID()
                history.observe(text: "önce merhababdünya sonra" + suffix)
                observation.changed(before: "", documentID: id)
                for before in ["önce ", "önce merhababdünya ", "önce merhababdünya sonra" + suffix + " "] {
                    if let event = observation.completed(before: before, documentID: id) { history.observe(event) }
                }
                let before = padded ? "önce" : "önce "
                let selected = padded ? " merhababdünya " : "merhababdünya"
                let after = (padded ? "sonra" : " sonra") + suffix + " "
                // First tap moves the caret; second tap selects the word.
                observation.changed(before: before, documentID: id, after: selected + after)
                let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: selected, after: after, documentID: id))
                let inserted = padded ? " merhaba dünya " : "merhaba dünya"
                for _ in 0..<2 {
                    for event in observation.completedSelection(witness, inserted: inserted,
                        resultingBefore: before + inserted, resultingAfter: after, documentID: id) { history.observe(event) }
                }
                var expected = PersonalHistory()
                expected.observe(text: "önce merhababdünya sonra" + suffix)
                expected.observe(text: "önce merhaba dünya sonra" + suffix)
                XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count))
                XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) })
            }
        }
    }

    func testUnknownOriginKeepsOldCountsAndStaleWitnessDoesNothing() throws {
        for invalid in [false, true] {
            var observation = HistoryObservation(); var history = PersonalHistory()
            let id = UUID()
            history.observe(text: "önce merhababdünya")
            observation.changed(before: "önce merhababdünya ", documentID: id)
            let witness = try XCTUnwrap(observation.selectionReplacement(before: "önce ", selected: "merhababdünya", after: " ", documentID: id))
            let events = observation.completedSelection(witness, inserted: "merhaba dünya",
                resultingBefore: "önce merhaba dünya", resultingAfter: invalid ? "başka" : " ", documentID: id)
            for event in events { history.observe(event) }
            XCTAssertEqual(history.tokens["merhababdünya"]?.count, 1)
            XCTAssertEqual(history.tokens["merhaba"]?.count ?? 0, invalid ? 0 : 1)
            XCTAssertEqual(history.tokens["önce"]?.count, 1)
            if invalid { XCTAssertTrue(events.isEmpty) }
            observation.changed(before: "", documentID: UUID())
            XCTAssertTrue(observation.completedSelection(witness, inserted: "merhaba dünya",
                resultingBefore: "önce merhaba dünya", resultingAfter: " ", documentID: id).isEmpty)
        }
    }

    /// Selected punctuation spans must match independently typed final text.
    func testPunctuationAdjacentSelectionAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_SELECTION_PUNCTUATION_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let contexts = [
            ("", " "), ("önce ", " "), ("önce ", ", "), ("önce ", ". "),
            ("önce ", "! "), ("önce (", ") "), ("önce “", "” "), ("önce «", "» "),
            ("önce '", "' "), ("önce ", "; sonra "), ("önce (", "), sonra "), ("", ", sonra ")
        ]
        var rows: [[String: String]] = []
        for (before, after) in contexts {
            for seeded in [false, true] {
                let input = "merhababdünya", phrase = "merhaba dünya"
                let original = before + input + after
                var observation = HistoryObservation(), history = PersonalHistory(), expected = PersonalHistory()
                if seeded { history.observe(text: original); expected.observe(text: original) }
                let id = UUID()
                observation.changed(before: "", documentID: id)
                var typed = ""
                for character in original {
                    typed.append(character)
                    if character.isWhitespace, let event = observation.completed(before: typed, documentID: id) {
                        history.observe(event)
                    }
                    observation.changed(before: typed, documentID: id)
                }
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = SelectionCursorDocument()
                doc.insertText(original); doc.hostSelects(input)
                XCTAssertNotNil(c.handleSelection(doc.selectedText, into: doc))
                let witness = observation.selectionReplacement(before: before, selected: input, after: after, documentID: id)
                let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
                try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                if let witness {
                    for event in observation.completedSelection(witness, inserted: phrase,
                        resultingBefore: doc.contextBeforeInput!, resultingAfter: doc.contextAfterInput, documentID: id) {
                        history.observe(event)
                    }
                }
                if let event = observation.completed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput) {
                    history.observe(event)
                }
                XCTAssertEqual(doc.text, before + phrase + after)
                expected.observe(text: doc.text)
                let tokensMatch = history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)
                let pairsMatch = history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }
                XCTAssertTrue(tokensMatch, "\(before) | \(after)")
                XCTAssertTrue(pairsMatch, "\(before) | \(after)")
                rows.append(["before": before, "after": after, "seeded": String(seeded),
                    "witness": String(witness != nil), "final_text_exact": String(doc.text == before + phrase + after),
                    "tokens_match": String(tokensMatch), "pairs_match": String(pairsMatch),
                    "actual_old": String(history.tokens[input]?.count ?? 0),
                    "expected_old": String(expected.tokens[input]?.count ?? 0),
                    "actual_first": String(history.tokens["merhaba"]?.count ?? 0),
                    "expected_first": String(expected.tokens["merhaba"]?.count ?? 0)])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }

    func testPunctuationWitnessRejectsTechnicalAndPartialWordSelections() {
        for (before, after) in [("https://", ".com "), ("", "@example.com "), ("user@", ".com "),
                                ("/tmp/", ".txt "), ("", ".swift "), ("prefix", " "),
                                ("", "suffix "), ("", "'den "), ("", "-ler "), ("192.", ".1 ")] {
            var observation = HistoryObservation()
            XCTAssertNil(observation.selectionReplacement(before: before, selected: "merhababdünya", after: after, documentID: UUID()), "\(before) | \(after)")
        }
    }

    func testCursorReturnAfterPhraseAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_PHRASE_CURSOR_RETURN_AUDIT"]
        var rows: [[String: String]] = []
        for after in [" ", ", ", ". ", " sonra ", ", sonra ", " sonra, "] {
            for seeded in [false, true] {
                for viaStart in [false, true] {
                    let id = UUID(), before = "önce ", old = "merhababdünya", phrase = "merhaba dünya"
                    let original = before + old + after, final = before + phrase + after
                    var observation = HistoryObservation(), history = PersonalHistory(), expected = PersonalHistory()
                    if seeded { history.observe(text: original); expected.observe(text: original) }
                    observation.changed(before: "", documentID: id)
                    var typed = ""
                    for character in original {
                        typed.append(character)
                        if character.isWhitespace, let event = observation.completed(before: typed, documentID: id) { history.observe(event) }
                        observation.changed(before: typed, documentID: id)
                    }
                    let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: old, after: after, documentID: id))
                    for event in observation.completedSelection(witness, inserted: phrase,
                        resultingBefore: before + phrase, resultingAfter: after, documentID: id) { history.observe(event) }
                    // Normal post-pick callback with UIKit's insertion caret.
                    if let event = observation.completed(before: before + phrase, documentID: id, after: after) { history.observe(event) }
                    expected.observe(text: final)
                    XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count))
                    XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) })
                    if viaStart { observation.changed(before: "", documentID: id, after: final) }
                    // Cursor moves preserve the complete document. Then only
                    // separators are inserted; no new word occurrence exists.
                    observation.changed(before: final, documentID: id, after: "")
                    var cursor = final, emitted = 0
                    for _ in 0..<3 {
                        cursor += " "
                        if let event = observation.completed(before: cursor, documentID: id, after: "") {
                            emitted += 1; history.observe(event)
                        }
                    }
                    XCTAssertEqual(emitted, 0)
                    XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count))
                    XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) })
                    rows.append(["after": after, "seeded": String(seeded), "via_start": String(viaStart),
                        "events_emitted": String(emitted),
                        "tokens_match": String(history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)),
                        "pairs_match": String(history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }),
                        "actual_world": String(history.tokens["dünya"]?.count ?? 0),
                        "expected_world": String(expected.tokens["dünya"]?.count ?? 0),
                        "actual_next": String(history.tokens["sonra"]?.count ?? 0),
                        "expected_next": String(expected.tokens["sonra"]?.count ?? 0)])
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }

    func testSequentialPhraseSelectionAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SEQUENTIAL_PHRASE_AUDIT"] else {
            throw XCTSkip("Opt-in sequential selected phrase audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for separator in [" ", ", ", "; "] {
            for prefix in ["", "önce "] {
                for seeded in [false, true] {
                    for reverse in [false, true] {
                        let original = prefix + "merhababdünya" + separator + "iyiki sonra "
                        var observation = HistoryObservation(), history = PersonalHistory()
                        if seeded { history.observe(text: original) }
                        let id = UUID()
                        observation.changed(before: "", documentID: id)
                        var typed = ""
                        for character in original {
                            typed.append(character)
                            if character.isWhitespace, let event = observation.completed(before: typed, documentID: id) { history.observe(event) }
                            observation.changed(before: typed, documentID: id)
                        }
                        var coordinator = InputCoordinator(layout: layout)
                        coordinator.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        let doc = SelectionCursorDocument(); doc.insertText(original)
                        let targets = [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki")]
                        for (step, target) in (reverse ? Array(targets.reversed()) : targets).enumerated() {
                            doc.hostSelects(target.0)
                            XCTAssertNotNil(coordinator.handleSelection(doc.selectedText, into: doc))
                            let before = doc.contextBeforeInput!, after = doc.contextAfterInput
                            let witness = try XCTUnwrap(observation.selectionReplacement(before: before, selected: target.0, after: after, documentID: id))
                            let pick = try XCTUnwrap(coordinator.suggestions().first { $0.surface == target.1 })
                            try coordinator.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                            for event in observation.completedSelection(witness, inserted: target.1,
                                resultingBefore: doc.contextBeforeInput!, resultingAfter: doc.contextAfterInput, documentID: id) { history.observe(event) }
                            if let event = observation.completed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput) { history.observe(event) }
                            var expected = PersonalHistory()
                            if seeded { expected.observe(text: original) }
                            expected.observe(text: doc.text)
                            rows.append(["separator": separator, "prefix": prefix, "seeded": String(seeded),
                                "reverse": String(reverse), "step": String(step + 1), "selected": target.0,
                                "text": doc.text,
                                "tokens_match": String(history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)),
                                "pairs_match": String(history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) })])
                        }
                        XCTAssertEqual(doc.text, prefix + "merhaba dünya" + separator + "iyi ki sonra ")
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }

    func testPreviouslyTypedSelectionLearning() throws {
        let output = ProcessInfo.processInfo.environment["KB_SELECTED_PHRASE_LEARNING_AUDIT"]
        let baseline = ProcessInfo.processInfo.environment["KB_SELECTED_PHRASE_LEARNING_BASELINE"] == "1"
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for (input, phrase) in [("merhababdünya", "merhaba dünya"), ("iyiki", "iyi ki"), ("subiç", "su iç")] {
            for leading in ["", "önce "] {
                for seeded in [false, true] {
                    for padding in [false, true] {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        var observation = HistoryObservation(); var history = PersonalHistory()
                        var expected = PersonalHistory()
                        if seeded {
                            history.observe(text: leading + input)
                            expected.observe(text: leading + input)
                        }
                        let doc = SelectionCursorDocument(); let id = UUID()
                        observation.changed(before: "", documentID: id)
                        for ch in leading + input + " " {
                            if ch == " " {
                                c.space(into: doc)
                                if let event = observation.completed(before: doc.contextBeforeInput!, documentID: id) { history.observe(event) }
                            } else {
                                let key = try XCTUnwrap(layout.keyIndex(for: ch))
                                c.insertLetter(ch, touch: .init(down: layout.keys[key].center), into: doc)
                            }
                            observation.changed(before: doc.contextBeforeInput!, documentID: id)
                        }
                        doc.hostSelects(input + (padding ? " " : ""))
                        XCTAssertNotNil(c.handleSelection(doc.selectedText, into: doc))
                        observation.changed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput, selected: doc.selectedText)
                        let witness = try XCTUnwrap(observation.selectionReplacement(before: doc.contextBeforeInput!,
                            selected: doc.selectedText!, after: doc.contextAfterInput, documentID: id))
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == phrase })
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        if !baseline {
                            for event in observation.completedSelection(witness, inserted: phrase + (padding ? " " : ""),
                                resultingBefore: doc.contextBeforeInput!, resultingAfter: doc.contextAfterInput, documentID: id) { history.observe(event) }
                        }
                        if let event = observation.completed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput) { history.observe(event) }
                        observation.changed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput)
                        XCTAssertEqual(doc.text, leading + phrase + " ")
                        expected.observe(text: doc.text)
                        if !baseline {
                            XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count))
                            XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) })
                        }
                        let first = phrase.split(separator: " ").first.map(String.init)!
                        rows.append(["input": input, "phrase": phrase, "leading": leading,
                                     "seeded_prior": String(seeded), "selected_separator": String(padding),
                                     "token_counts_match": String(history.tokens.mapValues(\.count) == expected.tokens.mapValues(\.count)),
                                     "pair_counts_match": String(history.pairs.mapValues { $0.mapValues(\.count) } == expected.pairs.mapValues { $0.mapValues(\.count) }),
                                     "actual_old_count": String(history.tokens[input]?.count ?? 0),
                                     "expected_old_count": String(expected.tokens[input]?.count ?? 0),
                                     "actual_first_count": String(history.tokens[first]?.count ?? 0),
                                     "expected_first_count": String(expected.tokens[first]?.count ?? 0),
                                     "actual_next": history.nextWords(after: "önce").joined(separator: " | "),
                                     "expected_next": expected.nextWords(after: "önce").joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
        print("SELECTED PHRASE LEARNING AUDIT: \(rows.count) observations")
    }
}

/// Unlike the legacy end-only FakeDocument, preserve UIKit's insertion caret
/// after replacing a selection in the middle of the document.
private final class SelectionCursorDocument: DocumentEditor {
    private(set) var text = ""
    private var caret = 0
    private var selection: Range<Int>?
    private func index(_ offset: Int) -> String.Index { text.index(text.startIndex, offsetBy: offset) }
    func insertText(_ value: String) {
        let range = selection ?? caret..<caret
        text.replaceSubrange(index(range.lowerBound)..<index(range.upperBound), with: value)
        caret = range.lowerBound + value.count
        selection = nil
    }
    func deleteBackward() {
        let range = selection ?? max(0, caret - 1)..<caret
        text.removeSubrange(index(range.lowerBound)..<index(range.upperBound))
        caret = range.lowerBound; selection = nil
    }
    func hostSelects(_ word: String) {
        guard let range = text.range(of: word) else { selection = nil; return }
        selection = text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
    }
    var selectedText: String? { selection.map { String(text[index($0.lowerBound)..<index($0.upperBound)]) } }
    var contextBeforeInput: String? { String(text.prefix(selection?.lowerBound ?? caret)) }
    var contextAfterInput: String? { String(text.dropFirst(selection?.upperBound ?? caret)) }
}
