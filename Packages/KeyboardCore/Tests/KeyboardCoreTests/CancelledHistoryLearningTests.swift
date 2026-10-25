import XCTest
import KBLearning

final class CancelledHistoryLearningTests: XCTestCase {
    func testConfirmedDeletionRetractsOnlyCurrentOccurrence() throws {
        for token in ["18.300", "uşağumm", "https://example.com/typo"] {
            for historicalCount in [0, 2] {
                var archive = HistoryArchive()
                for _ in 0..<historicalCount { archive.observe(token: token, previous: "önce") }
                var observation = HistoryObservation()
                let id = UUID()
                var before = "önce "
                observation.changed(before: "", documentID: id, after: "")
                for ch in token + " \n" {
                    before.append(ch)
                    observation.changed(before: before, documentID: id, after: "")
                    if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: "") {
                        archive.observe(event)
                    }
                }
                XCTAssertEqual(archive.history.tokens[token]?.count, historicalCount + 1)
                // Separators alone do not cancel the completed occurrence.
                for step in 0..<3 {
                    observation.expectBackwardDeletion(before: before, after: "", documentID: id)
                    before.removeLast()
                    observation.changed(before: before, documentID: id, after: "")
                    archive.retract(observation.takeCancelledOccurrences())
                    if step < 2 { XCTAssertEqual(archive.history.tokens[token]?.count, historicalCount + 1) }
                }
                XCTAssertEqual(archive.history.tokens[token]?.count ?? 0, historicalCount, token)
                let reloaded = try HistoryArchive.decode(JSONEncoder().encode(archive))
                XCTAssertEqual(reloaded.history.tokens[token]?.count ?? 0, historicalCount, token)
            }
        }
    }

    func testUnconfirmedEditsCursorMovesAndDocumentChangesDoNotRetract() throws {
        for mode in ["unknown-edit", "cursor", "document", "selection", "cancelled-command"] {
            var history = PersonalHistory()
            var observation = HistoryObservation()
            let id = UUID(), text = "önce 18.300 "
            observation.changed(before: "", documentID: id, after: "")
            history.observe(try XCTUnwrap(observation.completed(before: text, documentID: id, after: "")))
            if mode != "unknown-edit" && mode != "cursor" {
                observation.expectBackwardDeletion(before: text, after: "", documentID: id)
            }
            if mode == "cancelled-command" { observation.cancelExpectedDeletion() }
            observation.changed(before: "önce 18.30", documentID: mode == "document" ? UUID() : id,
                after: mode == "cursor" ? "0 " : "", selected: mode == "selection" ? "0 " : nil)
            XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty, mode)
            XCTAssertEqual(history.tokens["18.300"]?.count, 1, mode)
        }
    }

    func testDelayedRepeatedDeletionRetractsOnceAndPreservesImportedSource() throws {
        var imported = PersonalHistory()
        imported.observe(token: "18.300", previous: nil)
        var archive = HistoryArchive(), inbox = HistoryImportInbox()
        inbox.append(imported, source: "test-source")
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { _ in })
        var observation = HistoryObservation()
        let id = UUID(), text = "önce 18.300 "
        observation.changed(before: "", documentID: id, after: "")
        archive.observe(try XCTUnwrap(observation.completed(before: text, documentID: id, after: "")))
        XCTAssertEqual(archive.history.tokens["18.300"]?.count, 2)
        // The host returns the same snapshot for two actual delete commands.
        observation.expectBackwardDeletion(before: text, after: "", documentID: id)
        observation.expectBackwardDeletion(before: text, after: "", documentID: id)
        observation.changed(before: "önce 18.30", documentID: id, after: "")
        let cancelled = observation.takeCancelledOccurrences()
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertTrue(archive.retract(cancelled))
        XCTAssertFalse(archive.retract(cancelled))
        XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty)
        XCTAssertEqual(archive.history.tokens["18.300"]?.count, 1)
        XCTAssertEqual(archive.sourceHistories["test-source"]?.tokens["18.300"]?.count, 1)
        XCTAssertEqual(try HistoryArchive.decode(JSONEncoder().encode(archive)).history.tokens["18.300"]?.count, 1)
    }

    func testReopenedPrefixNeedsConfirmedContinuationAndCanCloseUnchanged() throws {
        for mode in ["continued", "separator", "unknown", "cancelled", "document"] {
            var archive = HistoryArchive(), observation = HistoryObservation()
            let id = UUID()
            observation.changed(before: "", documentID: id, after: "")
            archive.observe(try XCTUnwrap(observation.completed(before: "seni sev ", documentID: id, after: "")))
            observation.expectBackwardDeletion(before: "seni sev ", after: "", documentID: id)
            observation.changed(before: "seni sev", documentID: id, after: "")
            XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty)
            let suffix = mode == "separator" ? " " : "i"
            if mode != "unknown" { observation.expectInsertion(suffix, before: "seni sev", after: "", documentID: id) }
            let result = mode == "cancelled" ? "seni sevx" : "seni sev" + suffix
            observation.changed(before: result, documentID: mode == "document" ? UUID() : id, after: "")
            archive.retract(observation.takeCancelledOccurrences())
            if mode == "separator", let event = observation.completed(before: result, documentID: id, after: "") {
                archive.observe(event)
            }
            XCTAssertEqual(archive.history.tokens["sev"]?.count ?? 0, mode == "continued" ? 0 : 1, mode)
            XCTAssertEqual(archive.history.pairs["seni"]?["sev"]?.count ?? 0, mode == "continued" ? 0 : 1, mode)
        }
    }

    func testTechnicalContinuationAfterAccidentalBoundaryMatchesCleanHistory() throws {
        for (stem, suffix) in [("v2", ".1"), ("192.168", ".1.10"),
                               ("https://example.com", "/docs"), ("Ankara", "'ya"),
                               ("İstanbul", "’a"), ("test", "@example.com"),
                               ("dosya", "_adi"), ("kalem", ".")] {
            for separator in [" ", " \n"] {
                func run(_ interrupted: Bool) throws -> PersonalHistory {
                    var observation = HistoryObservation(), archive = HistoryArchive()
                    let id = UUID()
                    var before = ""
                    observation.changed(before: before, documentID: id, after: "")
                    func insert(_ text: String) {
                        for ch in text {
                            observation.expectInsertion(String(ch), before: before, after: "", documentID: id)
                            archive.retract(observation.takeCancelledOccurrences())
                            before.append(ch)
                            observation.changed(before: before, documentID: id, after: "")
                            archive.retract(observation.takeCancelledOccurrences())
                            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: "") {
                                archive.observe(event)
                            }
                        }
                    }
                    insert("önce " + stem)
                    if interrupted {
                        insert(separator)
                        for _ in separator {
                            observation.expectBackwardDeletion(before: before, after: "", documentID: id)
                            before.removeLast()
                            observation.changed(before: before, documentID: id, after: "")
                            archive.retract(observation.takeCancelledOccurrences())
                        }
                    }
                    insert(suffix + " ")
                    return try HistoryArchive.decode(JSONEncoder().encode(archive)).history
                }
                let clean = try run(false), edited = try run(true)
                XCTAssertEqual(edited.tokens.mapValues(\.count), clean.tokens.mapValues(\.count), stem + suffix)
                XCTAssertEqual(edited.pairs.mapValues { $0.mapValues(\.count) }, clean.pairs.mapValues { $0.mapValues(\.count) }, stem + suffix)
            }
        }
    }

    func testRepeatedPunctuationUndoMatchesCleanHistory() throws {
        for (stem, suffix) in [("canım", "!"), ("kalem", "."), ("Ankara", "'ya"),
                               ("İstanbul", "’a"), ("192.168", ".1.10"),
                               ("https://example.com", "/docs"), ("test", "@example.com"),
                               ("dosya", "_adi"), ("gardaş", "😂")] {
            for closeSuffix in [false, true] {
                for keepSuffix in [false, true] {
                    func run(_ interrupted: Bool) throws -> PersonalHistory {
                        var observation = HistoryObservation(), archive = HistoryArchive()
                        let id = UUID()
                        var before = ""
                        observation.changed(before: before, documentID: id, after: "")
                        func insert(_ text: String) {
                            for ch in text {
                                observation.expectInsertion(String(ch), before: before, after: "", documentID: id)
                                archive.retract(observation.takeCancelledOccurrences())
                                before.append(ch)
                                observation.changed(before: before, documentID: id, after: "")
                                archive.retract(observation.takeCancelledOccurrences())
                                if ch.isWhitespace, let event = observation.completed(before: before, documentID: id, after: "") {
                                    archive.observe(event)
                                }
                            }
                        }
                        func remove(_ count: Int) {
                            for _ in 0..<count {
                                observation.expectBackwardDeletion(before: before, after: "", documentID: id)
                                before.removeLast()
                                observation.changed(before: before, documentID: id, after: "")
                                archive.retract(observation.takeCancelledOccurrences())
                            }
                        }
                        // Independent earlier occurrences must survive every retry.
                        insert("önce " + stem + " sonra " + stem)
                        if interrupted {
                            for _ in 0..<3 {
                                insert(" \n")
                                remove(2)
                                insert(suffix)
                                if closeSuffix { insert(" \n"); remove(2) }
                                remove(suffix.count)
                            }
                        }
                        insert((keepSuffix ? suffix : "") + " ")
                        return try HistoryArchive.decode(JSONEncoder().encode(archive)).history
                    }
                    let clean = try run(false), edited = try run(true)
                    let label = "\(stem)\(suffix), closed=\(closeSuffix), retained=\(keepSuffix)"
                    XCTAssertEqual(edited.tokens.mapValues(\.count), clean.tokens.mapValues(\.count), label)
                    XCTAssertEqual(edited.pairs.mapValues { $0.mapValues(\.count) }, clean.pairs.mapValues { $0.mapValues(\.count) }, label)
                }
            }
        }
    }

    func testDelayedInsertionSnapshotsRetractOnlyReopenedOccurrence() throws {
        for (stem, chunks) in [("sev", ["i", "y", "o", "rum"]),
                               ("192.168", [".", "1", ".10"]),
                               ("Ankara", ["'", "y", "a"])] {
            for mode in ["complete", "intermediate", "continued-intermediate", "mismatch", "changed-after", "changed-document", "selected"] {
                let mismatch = mode == "mismatch"
                let shouldCancel = ["complete", "intermediate", "continued-intermediate"].contains(mode)
                var archive = HistoryArchive(), observation = HistoryObservation()
                let id = UUID(), body = "önce " + stem
                archive.observe(token: stem, previous: "önce")
                observation.changed(before: "", documentID: id, after: "")
                archive.observe(try XCTUnwrap(observation.completed(before: body + " ", documentID: id, after: "")))
                observation.expectBackwardDeletion(before: body + " ", after: "", documentID: id)
                observation.changed(before: body, documentID: id, after: "")
                // Several actual insertion commands see the same stale host proxy.
                for chunk in chunks {
                    observation.expectInsertion(chunk, before: body, after: "", documentID: id)
                }
                if mode == "intermediate" || mode == "continued-intermediate" {
                    observation.changed(before: body + chunks[0], documentID: id, after: "")
                }
                if mode == "continued-intermediate" {
                    observation.expectInsertion("z", before: body + chunks[0], after: "", documentID: id)
                }
                let result = body + (mismatch ? "x" : chunks.joined()) + (mode == "continued-intermediate" ? "z" : "")
                observation.changed(before: result, documentID: mode == "changed-document" ? UUID() : id,
                    after: mode == "changed-after" ? "other" : "", selected: mode == "selected" ? "selection" : nil)
                let cancelled = observation.takeCancelledOccurrences()
                XCTAssertEqual(cancelled.count, shouldCancel ? 1 : 0, stem)
                archive.retract(cancelled)
                XCTAssertEqual(archive.history.tokens[stem.lowercased()]?.count, shouldCancel ? 1 : 2, stem)
                XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty)
            }
        }
    }

    func testIntermediateDeletionAcknowledgementsRetainCancellationEvidence() throws {
        for token in ["18.300", "uşağumm", "https://example.com/typo"] {
            for variant in 0..<4 {
                let continueDeleting = variant % 2 == 1
                let partialRemovesLetter = variant >= 2
                var archive = HistoryArchive(), observation = HistoryObservation()
                let id = UUID(), body = "önce " + token, start = "önce " + token + " "
                archive.observe(token: token, previous: "önce")
                observation.changed(before: "", documentID: id, after: "")
                archive.observe(try XCTUnwrap(observation.completed(before: start, documentID: id, after: "")))
                observation.expectBackwardDeletion(before: start, after: "", documentID: id)
                observation.expectBackwardDeletion(before: start, after: "", documentID: id)
                if partialRemovesLetter {
                    observation.expectBackwardDeletion(before: start, after: "", documentID: id)
                }
                let intermediate = String(body.dropLast(partialRemovesLetter ? 1 : 0))
                observation.changed(before: intermediate, documentID: id, after: "")
                var cancelled = observation.takeCancelledOccurrences()
                XCTAssertEqual(cancelled.count, partialRemovesLetter ? 1 : 0)
                if continueDeleting {
                    observation.expectBackwardDeletion(before: intermediate, after: "", documentID: id)
                }
                let deletedLetters = 1 + (partialRemovesLetter ? 1 : 0) + (continueDeleting ? 1 : 0)
                observation.changed(before: String(body.dropLast(deletedLetters)), documentID: id, after: "")
                cancelled += observation.takeCancelledOccurrences()
                XCTAssertEqual(cancelled.count, 1, token)
                archive.retract(cancelled)
                XCTAssertEqual(archive.history.tokens[token]?.count, 1, token)
                XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty)
            }
        }
    }

    func testReplacementAfterUnacknowledgedDeletesRetractsOnlyEditedOccurrence() throws {
        for (old, replacement) in [("bellimi", "belli mi"), ("gereğininn", "gereğinin"), ("12500", "1250")] {
            for mode in ["final", "partial", "additional", "mismatch", "right", "document", "selection"] {
                var archive = HistoryArchive(), observation = HistoryObservation()
                let id = UUID(), body = "önce " + old
                archive.observe(token: old, previous: "önce")
                observation.changed(before: "", documentID: id, after: "")
                archive.observe(try XCTUnwrap(observation.completed(before: body + " ", documentID: id, after: "")))
                observation.expectBackwardDeletion(before: body + " ", after: "", documentID: id)
                observation.changed(before: body, documentID: id, after: "")
                for _ in old { observation.expectBackwardDeletion(before: body, after: "", documentID: id) }
                observation.expectInsertion(replacement, before: body, after: "", documentID: id)
                if mode == "partial" { observation.changed(before: "önce ", documentID: id, after: "") }
                if mode == "additional" { observation.expectInsertion(" ", before: body, after: "", documentID: id) }
                let final = mode == "mismatch" ? "başka metin" : "önce " + replacement + (mode == "additional" ? " " : "")
                observation.changed(before: final, documentID: mode == "document" ? UUID() : id,
                    after: mode == "right" ? "changed" : "", selected: mode == "selection" ? "x" : nil)
                let cancelled = observation.takeCancelledOccurrences()
                let valid = ["final", "partial", "additional"].contains(mode)
                XCTAssertEqual(cancelled.count, valid ? 1 : 0, "\(old), \(mode)")
                archive.retract(cancelled)
                XCTAssertEqual(archive.history.tokens[old]?.count, valid ? 1 : 2, "\(old), \(mode)")
                XCTAssertTrue(observation.takeCancelledOccurrences().isEmpty)
            }
        }
    }

    func testPhraseCompletionAfterCoalescedReplacementRetractsEditedOccurrence() throws {
        for partial in [false, true] {
            var archive = HistoryArchive(), observation = HistoryObservation()
            let id = UUID(), body = "bellimi"
            archive.observe(token: body, previous: nil)
            observation.changed(before: "", documentID: id, after: "")
            archive.observe(try XCTUnwrap(observation.completed(before: body + " ", documentID: id, after: "")))
            observation.expectBackwardDeletion(before: body + " ", after: "", documentID: id)
            observation.changed(before: body, documentID: id, after: "")
            for _ in body { observation.expectBackwardDeletion(before: body, after: "", documentID: id) }
            observation.expectInsertion("belli mi", before: body, after: "", documentID: id)
            if partial { observation.changed(before: "belli mi", documentID: id, after: "") }
            observation.expectInsertion(" ", before: partial ? "belli mi" : body, after: "", documentID: id)
            for event in observation.completedReplacement(before: body, after: "", resultingBefore: "belli mi ",
                resultingAfter: "", replacing: body, inserted: "belli mi ", documentID: id) { archive.observe(event) }
            archive.retract(observation.takeCancelledOccurrences())
            XCTAssertEqual(archive.history.tokens[body]?.count, 1, "partial=\(partial)")
            XCTAssertEqual(archive.history.tokens["belli"]?.count, 1)
            XCTAssertEqual(archive.history.tokens["mi"]?.count, 1)
        }
    }

}
