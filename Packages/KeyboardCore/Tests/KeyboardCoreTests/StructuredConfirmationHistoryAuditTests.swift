import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class StructuredConfirmationHistoryAuditTests: XCTestCase {
    func testUnchangedStructuredConfirmationDoesNotDuplicateHistory() throws {
        let output = ProcessInfo.processInfo.environment["KB_STRUCTURED_CONFIRM_HISTORY_AUDIT"]
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for value in ["0532 123 45 67", "+90 532 123 45 67", "\"Çağrı Şen\"@örnek.com", "\"First Last\"@[IPv6:2001:db8::1]",
                      "dev@example.com", "https://örnek.com/çağrı", "192.0.2.1", "tcp/ip"] {
            for padding in ["", " ", "\u{00a0}"] {
                for (before, after) in [("", " "), ("önce ", " sonra "), ("önce (", "), sonra ")] {
                    for seeded in [false, true] {
                        var observation = HistoryObservation(), history = PersonalHistory()
                        let id = UUID(), selected = padding + value + padding
                        let original = before + selected + after
                        if seeded { history.observe(text: original) }
                        observation.changed(before: "", documentID: id, after: "")
                        var typed = ""
                        for ch in original {
                            typed.append(ch)
                            observation.changed(before: typed, documentID: id, after: "")
                            if ch.isWhitespace, let event = observation.completed(before: typed, documentID: id, after: "") { history.observe(event) }
                        }
                        let initialTokens = history.tokens.mapValues(\.count)
                        let initialPairs = history.pairs.mapValues { $0.mapValues(\.count) }
                        let phoneIdentity = TechnicalTokenKind.normalizedPhone(value)
                        let initiallyLearned = history.tokens.values.contains {
                            $0.surface == value || (phoneIdentity != nil && TechnicalTokenKind.normalizedPhone($0.surface) == phoneIdentity)
                        }
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        let doc = StructuredHistoryDocument(); doc.insertText(original)
                        var exact = true, counts = true, pairs = true
                        for _ in 0..<3 {
                            doc.hostSelects(selected)
                            c.handleSelection(doc.selectedText, into: doc)
                            let witness = observation.selectionReplacement(before: before, selected: selected, after: after, documentID: id)
                            let pick = try XCTUnwrap(c.suggestions().first { $0.origin == .literal && $0.surface == value })
                            try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                            if let witness {
                                for event in observation.completedSelection(witness, inserted: selected, resultingBefore: doc.contextBeforeInput!, resultingAfter: doc.contextAfterInput, documentID: id) { history.observe(event) }
                            }
                            for _ in 0..<3 {
                                if let event = observation.completed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput) { history.observe(event) }
                                observation.changed(before: doc.contextBeforeInput!, documentID: id, after: doc.contextAfterInput)
                            }
                            exact = exact && doc.text == original
                            counts = counts && history.tokens.mapValues(\.count) == initialTokens
                            pairs = pairs && history.pairs.mapValues { $0.mapValues(\.count) } == initialPairs
                        }
                        // Wrapper spelling is a separate tokenizer policy (e.g.
                        // parenthesized paths). This test requires existing history,
                        // then verifies that confirmation never changes its counts.
                        XCTAssertFalse(initialTokens.isEmpty, value)
                        XCTAssertTrue(exact, value)
                        XCTAssertTrue(counts, value + before + padding)
                        XCTAssertTrue(pairs, value)
                        rows.append(["initial_keys": initialTokens.keys.sorted().joined(separator: " | "), "changed_counts": history.tokens.filter { initialTokens[$0.key] != $0.value.count }.map { "\($0.key):\(initialTokens[$0.key] ?? 0)->\($0.value.count)" }.sorted().joined(separator: " | "), "value": value, "padding": padding, "before": before, "after": after, "seeded": String(seeded),
                                     "initially_learned": String(initiallyLearned), "exact": String(exact), "counts_unchanged": String(counts), "pairs_unchanged": String(pairs)])
                    }
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try e.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
    func testSelectionWitnessExpiresOnActualEditAndFieldChange() {
        let phone = "0532 123 45 67", id = UUID()
        var observation = HistoryObservation()
        observation.changed(before: "", documentID: id, after: "")
        observation.changed(before: "önce ", documentID: id, after: " sonra ", selected: phone + " ")
        XCTAssertNil(observation.completed(before: "önce " + phone + " ", documentID: id, after: " sonra "))
        XCTAssertNotNil(observation.completed(before: "önce " + phone + " sonra " + phone + " ", documentID: id, after: ""))
        observation.changed(before: "önce ", documentID: id, after: "", selected: phone + " ")
        XCTAssertNotNil(observation.completed(before: "önce " + phone + " ", documentID: UUID(), after: ""))
        var unknown = HistoryObservation()
        unknown.changed(before: "", documentID: id, after: nil, selected: phone + " ")
        XCTAssertNotNil(unknown.completed(before: phone + " ", documentID: id, after: nil))
    }

}

private final class StructuredHistoryDocument: DocumentEditor {
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
