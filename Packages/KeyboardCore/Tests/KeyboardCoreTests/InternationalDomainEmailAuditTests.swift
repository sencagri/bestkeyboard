import XCTest
import Foundation
import KBLearning

final class InternationalDomainEmailAuditTests: XCTestCase {
    func testUnicodeDomainCaseArchiveAndForgetKeepMailboxIdentity() throws {
        var history = PersonalHistory()
        for address in ["\"Çağrı Şen\"@ÖRNEK.com", "\"Çağrı Şen\"@örnek.com", "\"çağrı şen\"@örnek.com"] {
            history.observe(text: address)
        }
        history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.tokens.count, 2)
        XCTAssertEqual(history.tokens["\"Çağrı Şen\"@örnek.com"]?.count, 2)
        XCTAssertEqual(history.tokens["\"çağrı şen\"@örnek.com"]?.count, 1)
        XCTAssertEqual(history.completions(before: "\"Çağrı Şen\"@ÖRNEK.c", after: "", selected: nil).first?.surface, "\"Çağrı Şen\"@örnek.com")
        history.forget("\"Çağrı Şen\"@ÖRNEK.com")
        XCTAssertNil(history.tokens["\"Çağrı Şen\"@örnek.com"])
        XCTAssertEqual(history.tokens["\"çağrı şen\"@örnek.com"]?.count, 1)
    }

    func testCombiningMarksAndAsciiRightTailPreserveExactAddress() throws {
        let composed = "\"First Last\"@mail.örnek.com"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        var history = PersonalHistory()
        history.observe(text: decomposed); history.observe(text: composed)
        XCTAssertEqual(history.tokens.count, 1)
        XCTAssertEqual(history.tokens.values.first?.count, 2)
        XCTAssertEqual(PersonalHistory.tokenize(decomposed), [composed])
        let prefix = "\"First Last\"@mail.örnek.c".decomposedStringWithCanonicalMapping
        let offer = try XCTUnwrap(history.completions(before: prefix, after: "m sonra", selected: nil).first)
        XCTAssertEqual(offer.surface, composed)
        XCTAssertEqual(offer.rightToken, "m")
        XCTAssertEqual(offer.replacementBeforeCursor + offer.after, composed + " sonra")
        // Existing cursor-offset contract: Unicode right tails are not edited.
        XCTAssertTrue(history.completions(before: "\"First Last\"@mail.", after: "örnek.com", selected: nil).isEmpty)
    }

    func testInternationalDomainEmailAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_INTERNATIONAL_DOMAIN_EMAIL_AUDIT"]
        var rows: [[String: String]] = []
        for local in ["dev", "çağrı", "\"First Last\"", "\"Çağrı Şen\""] {
            for domain in ["example.com", "örnek.com", "mail.örnek.com", "mail.api.örnek.com"] {
                let surface = local + "@" + domain
                XCTAssertEqual(TechnicalTokenKind.classify(surface), .email)
                let prefix = String(surface.dropLast(2))
                var direct = PersonalHistory(); direct.observe(token: surface, previous: nil)
                let directOffer = direct.completions(before: prefix, after: "", selected: nil).contains { $0.surface == surface && $0.source == .observed }
                for ending in [" ", "; "] {
                    let text = "adres " + surface + ending + "sonra "
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for character in text {
                        before.append(character)
                        observation.changed(before: before, documentID: id)
                        if character.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let count = history.tokens.values.first { $0.surface == surface }?.count ?? 0
                        let exact = history.completions(before: prefix, after: "", selected: nil).contains { $0.surface == surface && $0.source == .observed }
                        XCTAssertEqual(count, 1, surface + mode)
                        XCTAssertTrue(exact, surface + mode)
                        XCTAssertTrue(directOffer, surface)
                        XCTAssertEqual(history.tokens.count, 3, "No fragmented address entries: " + surface + mode)
                        rows.append(["surface": surface, "prefix": prefix, "ending": ending, "mode": mode,
                            "exact_count": String(count), "direct_completion": String(directOffer),
                            "learned_completion": String(exact), "stored": history.tokens.values.map(\.surface).sorted().joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
