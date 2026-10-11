import XCTest
import KBLearning

final class QuotedEmailLearningRegressionTests: XCTestCase {
    private func live(_ text: String, archive: HistoryArchive = HistoryArchive()) -> HistoryArchive {
        var archive = archive, observation = HistoryObservation(), before = ""
        let id = UUID(); observation.changed(before: "", documentID: id)
        for ch in text {
            before.append(ch); observation.changed(before: before, documentID: id)
            if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { archive.observe(event) }
        }
        return archive
    }
    private func assertCounts(_ actual: PersonalHistory, _ expected: PersonalHistory, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label, file: file, line: line)
        XCTAssertEqual(actual.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label, file: file, line: line)
    }

    func testQuotedEmailsAndOrdinaryQuotesMatchWholeTextLearning() throws {
        for sample in ["dev@example.com", "\"First.Last\"@example.com", "\"First@Last\"@example.com",
                       "\"First Last\"@example.com", "\"First Middle Last\"@example.com",
                       "\"First Last@Work\"@example.com", "\"First\\\" Last\"@example.com",
                       "\"Call +90 532 123 45 67\"@example.com", "\"o o\"@example.com",
                       "\"merhaba dünya\"", "\"First Last\""] {
            for leading in ["", "mail ", "selam\nmail "] {
                for ending in [" ", ", "] {
                    let text = leading + sample + ending
                    let archive = try HistoryArchive.decode(JSONEncoder().encode(live(text)))
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    assertCounts(archive.history, bulk, text)
                    if TechnicalTokenKind.classify(sample) == .email {
                        XCTAssertTrue(archive.history.tokens.values.contains { $0.surface == sample }, text)
                    }
                }
            }
        }
    }

    func testIndependentTypedAndImportedWordsAndPairsSurviveRetraction() throws {
        let prior = "mail First\nFirst Middle\nFirst Last\no o"
        var archive = HistoryArchive(), inbox = HistoryImportInbox(), imported = PersonalHistory()
        archive.observe(text: prior); imported.observe(text: prior)
        inbox.append(imported, source: "WhatsApp")
        try HistoryImportTransaction.consume(&archive, inbox: inbox, writeArchive: { _ in }, writeInbox: { _ in })
        let text = "mail \"First Middle Last\"@example.com "
        var expected = archive.history; expected.observe(text: text)
        archive = live(text, archive: archive)
        archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
        assertCounts(archive.history, expected, text)
        XCTAssertEqual(archive.sourceHistories["WhatsApp"]?.tokens.mapValues(\.count), imported.tokens.mapValues(\.count))
    }

    func testDocumentSwitchDoesNotRetractPriorDocumentWords() {
        var observation = HistoryObservation(), history = PersonalHistory()
        let first = UUID(), second = UUID()
        observation.changed(before: "", documentID: first)
        if let event = observation.completed(before: "mail \"First ", documentID: first) { history.observe(event) }
        XCTAssertEqual(history.tokens["first"]?.count, 1)
        if let event = observation.completed(before: "mail \"First Last\"@example.com ", documentID: second) { history.observe(event) }
        XCTAssertEqual(history.tokens["first"]?.count, 1)
        XCTAssertEqual(history.pairs["mail"]?["first"]?.count, 1)
    }

    func testLegacyEmailPunctuationMigratesAndMergesWithoutLosingCounts() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "dev@example.com,": ["count": 2, "seq": 1, "surface": "dev@example.com,"],
                "dev@example.com": ["count": 3, "seq": 2, "surface": "dev@example.com"]
            ], "pairs": [:], "seq": 2
        ])
        var history = try JSONDecoder().decode(PersonalHistory.self, from: data)
        XCTAssertEqual(history.tokens.count, 1)
        XCTAssertEqual(history.tokens["dev@example.com"]?.count, 5)
        XCTAssertEqual(history.tokens["dev@example.com"]?.surface, "dev@example.com")
        history.forget("dev@example.com,")
        XCTAssertTrue(history.tokens.isEmpty)
    }

    func testEmailProseSuffixIsExcludedWhileMailboxAndURLPunctuationRemain() {
        for email in ["dev@example.com", "dev+one@example.com", "dev@[192.0.2.1]", "dev@[IPv6:2001:db8::1]"] {
            for ending in [",", ".", ";", ":", "!", "?", "…", "。"] {
                XCTAssertEqual(PersonalHistory.tokenize(email + ending), [email])
                var history = PersonalHistory(); history.observe(text: email + ending)
                XCTAssertEqual(history.completions(before: String(email.prefix(5)), after: "", selected: nil).first?.surface, email)
            }
        }
        let url = "https://example.com/query?mail=dev@example.com,"
        XCTAssertEqual(PersonalHistory.tokenize(url), [url])
        XCTAssertEqual(PersonalHistory.tokenize("\"First, Last\"@example.com,"), ["\"First, Last\"@example.com"])
        XCTAssertEqual(PersonalHistory.tokenize("notes@draft,"), ["notes@draft,"])
    }
}
