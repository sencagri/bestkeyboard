import XCTest
import KBLearning
import KBFoundation

final class HistoryClosureRegressionTests: XCTestCase {
    private func importHistory(_ history: PersonalHistory, source: String, into archive: inout HistoryArchive) throws {
        var inbox = HistoryImportInbox()
        inbox.append(history, source: source)
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { _ in })
    }

    func testSourceChronologySurvivesRebuildReloadAndRepeatedSource() throws {
        var archive = HistoryArchive()
        for (index, source) in ["WhatsApp", "Telegram", "Metin", "WhatsApp"].enumerated() {
            var history = PersonalHistory()
            history.observe(token: "https://example.com/item\(index)", previous: nil)
            try importHistory(history, source: source, into: &archive)
            archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
            archive.observe(token: "merhaba", previous: nil)
            XCTAssertEqual(archive.history.recall(prefix: "https://example.com/item").first, "https://example.com/item\(index)")
        }
    }

    func testAggregateCountsAreSummedBeforeEviction() throws {
        let target = "https://example.com/target"
        var archive = HistoryArchive(), small = PersonalHistory(), large = PersonalHistory()
        for _ in 0..<2 { small.observe(token: target, previous: nil) }
        for i in 0..<PersonalHistory.tokenCapacity {
            for _ in 0..<3 { large.observe(token: "https://example.com/item\(i)", previous: nil) }
        }
        try importHistory(small, source: "Metin", into: &archive)
        try importHistory(large, source: "Telegram", into: &archive)
        try importHistory(small, source: "WhatsApp", into: &archive)
        archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
        archive.observe(token: "merhaba", previous: nil)
        XCTAssertEqual(archive.history.tokens[target]?.count, 4)
        XCTAssertEqual(archive.history.tokens.count, PersonalHistory.tokenCapacity)
        XCTAssertEqual(archive.history.completions(before: "https://example.com/tar", after: "", selected: nil).first?.surface, target)
    }

    func testAllQuotedMailPrefixesCompleteWithoutCaseFoldingMailbox() throws {
        for address in ["dev@example.com", "\"First.Last\"@example.com", "\"First Last\"@example.com",
                        "\"a b\"@example.com", "\"first@last\"@example.com", "\"First@Last\"@example.com",
                        "\"First Last@Work\"@example.com", "\"First\\\" Last@Work\"@example.com"] {
            var history = PersonalHistory(); history.observe(text: address)
            history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
            for count in 2..<address.count {
                let prefix = String(address.prefix(count)), before = "mail " + prefix
                XCTAssertTrue(history.recall(prefix: prefix, limit: 3).contains(address), prefix)
                let outcomes = history.completions(before: before, after: "", selected: nil).map {
                    String(before.dropLast($0.prefix.count)) + $0.replacementBeforeCursor
                }
                XCTAssertTrue(outcomes.contains("mail " + address), prefix)
            }
        }
    }

    func testCompletedPhoneSeparatorsAreNeverDeleted() {
        for phone in ["+905321234567", "+90 (532) 123 45 67", "05321234567", "0532 123 45 67", "dev@example.com"] {
            var history = PersonalHistory(); history.observe(token: phone, previous: nil)
            for ending in ["", " ", "  ", ".", ". ", ", ", "\n"] {
                let before = "ara " + phone + ending
                for offer in history.completions(before: before, after: "", selected: nil) {
                    XCTAssertEqual(String(before.dropLast(offer.prefix.count)) + offer.replacementBeforeCursor, before)
                }
            }
        }
    }

    func testEveryCursorPositionInCompleteStructuredTokensHasNoRedundantOffer() {
        for surface in ["+905321234567", "+90 532 123 45 67", "+90 (532) 123 45 67", "0532 123 45 67",
                        "dev@example.com", "https://example.com/api", "/usr/local/bin", "\"First Last\"@example.com"] {
            var history = PersonalHistory(); history.observe(token: surface, previous: nil)
            for position in 2..<surface.count {
                let before = "önce " + surface.prefix(position), after = String(surface.dropFirst(position)) + " sonra"
                XCTAssertTrue(history.completions(before: before, after: after, selected: nil).isEmpty, before + "|" + after)
            }
        }
    }

    func testIncompleteMiddlePhoneAndQuotedMailKeepRightTailOnce() throws {
        for (surface, prefix, right) in [("+90 532 123 45 67", "+90 53", " 123 45 67"),
                                         ("\"First Last\"@example.com", "\"Fir", " Last\"@example.com")] {
            var history = PersonalHistory(); history.observe(token: surface, previous: nil)
            let offer = try XCTUnwrap(history.completions(before: prefix, after: right + " sonra", selected: nil).first)
            XCTAssertEqual(offer.rightToken, right)
            XCTAssertEqual(offer.replacementBeforeCursor + offer.after, surface + " sonra")
            XCTAssertFalse(offer.matches(before: prefix, after: right + " changed", selected: nil))
        }
    }

    func testLiveGroupedPhonesMatchBulkWithoutDeletingIndependentEvidence() throws {
        for phone in ["+90 532 123 45 67", "+90 (532) 123 45 67", "0532 123 45 67", "0212 123 45 67",
                      "+905321234567", "05321234567", "(0532)1234567"] {
            for leading in ["", "numaram "] {
                let text = leading + phone + " ara "
                var observation = HistoryObservation(), archive = HistoryArchive(), before = ""
                let id = UUID()
                observation.changed(before: "", documentID: id)
                for ch in text {
                    before.append(ch); observation.changed(before: before, documentID: id)
                    if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { archive.observe(event) }
                }
                archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
                var bulk = PersonalHistory(); bulk.observe(text: text)
                XCTAssertEqual(Set(archive.history.tokens.keys), Set(bulk.tokens.keys), text)
                for (key, stat) in bulk.tokens { XCTAssertEqual(archive.history.tokens[key]?.count, stat.count, text) }
            }
        }
        // Existing typed/imported occurrences of a shorter number survive a
        // new, longer occurrence that passes through the same prefix.
        let partial = "+90 532 123"
        var archive = HistoryArchive(), imported = PersonalHistory()
        archive.observe(token: partial, previous: nil)
        imported.observe(token: partial, previous: nil)
        try importHistory(imported, source: "WhatsApp", into: &archive)
        var observation = HistoryObservation(), before = ""
        let id = UUID(); observation.changed(before: "", documentID: id)
        for ch in "+90 532 123 45 67 " {
            before.append(ch); observation.changed(before: before, documentID: id)
            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { archive.observe(event) }
        }
        XCTAssertEqual(archive.history.tokens["+90532123"]?.count, 2)
        XCTAssertEqual(archive.history.tokens["+905321234567"]?.count, 1)
    }

    func testLivePhonePunctuationAndDocumentSwitchDoNotMergeOccurrences() {
        for ending in [" ", ". ", "\n"] {
            var observation = HistoryObservation(), history = PersonalHistory(), before = ""
            let id = UUID(); observation.changed(before: "", documentID: id)
            let text = "+90 532 123 45 67" + ending
            for ch in text {
                before.append(ch); observation.changed(before: before, documentID: id)
                if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { history.observe(event) }
            }
            XCTAssertEqual(history.tokens.count, 1, ending)
            XCTAssertEqual(history.tokens["+905321234567"]?.surface, "+90 532 123 45 67")
            XCTAssertEqual(history.tokens["+905321234567"]?.count, 1)
            let otherID = UUID(); observation.changed(before: "", documentID: otherID)
            if let event = observation.completed(before: text, documentID: otherID) { history.observe(event) }
            XCTAssertEqual(history.tokens["+905321234567"]?.count, 2)
        }
    }

    func testSeparatePersonalImportsAccumulateAndRetriesSurviveStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var lexicon = PersonalLexicon()
        for (index, context) in ["geldi", "gitti", "durdu"].enumerated() {
            let tokens = ["qrmenü", context]
            _ = lexicon.ingest(tokens: tokens, isKnown: { $0 != "qrmenü" })
            XCTAssertEqual(lexicon.entries["qrmenü"]?.points, index + 1)
            try PersonalLexiconStore.save(lexicon, to: directory)
            lexicon = try PersonalLexiconStore.load(from: directory)
            _ = lexicon.ingest(tokens: tokens, isKnown: { $0 != "qrmenü" })
            XCTAssertEqual(lexicon.entries["qrmenü"]?.points, index + 1)
        }
        XCTAssertTrue(lexicon.isAdmitted("qrmenü"))
        _ = lexicon.forget("qrmenü")
        _ = lexicon.ingest(tokens: ["qrmenü", "geldi"], isKnown: { $0 != "qrmenü" })
        XCTAssertEqual(lexicon.entries["qrmenü"]?.points, 1)
    }

    func testLegacyPersonalStoreMigratesWithoutDroppingWords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = BinaryContainer(magic: 0x3150_4B42, version: 1, headerSize: 24)
        var writer = format.writer { $0.u16(0); $0.u32(1); $0.u32(0) }
        writer.u16(3); writer.u32(7); writer.u16(UInt16("qrmenü".utf8.count)); writer.append(contentsOf: "qrmenü".utf8)
        try Data(format.seal(writer)).write(to: directory.appendingPathComponent(PersonalLexiconStore.fileName))
        let legacy = try PersonalLexiconStore.load(from: directory)
        XCTAssertTrue(legacy.isAdmitted("qrmenü"))
        try PersonalLexiconStore.save(legacy, to: directory)
        XCTAssertEqual(try PersonalLexiconStore.load(from: directory).entries, legacy.entries)
    }
}
