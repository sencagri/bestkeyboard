import XCTest
import Foundation
import KBLearning

final class AddressLiteralEmailAuditTests: XCTestCase {
    func testQuotedLiteralMiddleCompletionKeepsRightTailAndProse() throws {
        var cases = 0
        for local in ["\"First Last\"", "\"First @ Last\"", "\"First\\\" Last\""] {
            for domain in ["[192.0.2.1]", "[IPv6:2001:db8::1]"] {
                let address = local + "@" + domain
                var history = PersonalHistory(); history.observe(text: address)
                XCTAssertEqual(history.tokens.values.map(\.surface), [address])
                let chars = Array(address)
                for index in 2..<(chars.count - 1) where chars[index].isLetter || chars[index].isNumber {
                    let prefix = String(chars[..<index]), tail = String(chars[(index + 1)...])
                    let offer = try XCTUnwrap(history.completions(before: "adres " + prefix, after: tail + " sonra", selected: nil)
                        .first { $0.surface == address && $0.source == .observed }, "\(address) at \(index)")
                    XCTAssertEqual(offer.rightToken, tail)
                    XCTAssertEqual("adres " + offer.replacementBeforeCursor + offer.after, "adres " + address + " sonra")
                    cases += 1
                }
            }
        }
        print("ADDRESS LITERAL MIDDLE COMPLETIONS: \(cases)")
    }

    func testMalformedLiteralAndJoinedRightTextAreNotConsumed() {
        for domain in ["[999.0.2.1]", "[192.0.2]", "[192.0.2.1", "192.0.2.1]", "[IPv6:bad::bad::bad]", "[IPv6:2001:db8::1", "[192.0.2.1]extra"] {
            XCTAssertNotEqual(TechnicalTokenKind.classify("\"First Last\"@" + domain), .email, domain)
        }
        let address = "\"First Last\"@[192.0.2.1]"
        var history = PersonalHistory(); history.observe(text: address)
        for tail in ["2.1]extra", "2.1]/path", "2.1]@other"] {
            XCTAssertTrue(history.completions(before: "\"First Last\"@[192.0.", after: tail, selected: nil).isEmpty, tail)
        }
        XCTAssertTrue(history.completions(before: "\"First Last\"@[192.0.", after: "2.9]", selected: nil).isEmpty)
    }

    func testAddressLiteralEmailAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_ADDRESS_LITERAL_EMAIL_AUDIT"]
        var rows: [[String: String]] = []
        for local in ["dev", "\"First.Last\"", "\"First Last\"", "\"First Middle Last\""] {
            for domain in ["example.com", "[192.0.2.1]", "[IPv6:2001:db8::1]"] {
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
