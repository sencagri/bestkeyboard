import XCTest
import Foundation
import KBLearning

final class JoinedEmailBoundaryAuditTests: XCTestCase {
    func testJoinedEmailBoundaryAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_JOINED_EMAIL_AUDIT"]
        var rows: [[String: String]] = []
        for local in ["\"First Last\"", "\"Çağrı Şen\""] {
            for domain in ["example.com", "mail.örnek.com", "[192.0.2.1]", "[IPv6:2001:db8::1]"] {
                let address = local + "@" + domain
                // These are deliberately joined technical strings, not prose
                // separators. Their embedded address was never a whole input.
                for suffix in ["/path", "_backup", "=value", "@other.com", "#fragment", "+tag"] {
                    let input = address + suffix
                    var bulk = PersonalHistory(); bulk.observe(text: input + " ")
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for character in input + " " {
                        before.append(character)
                        observation.changed(before: before, documentID: id)
                        if character.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let phantom = history.tokens.values.first { $0.surface == address }?.count ?? 0
                        let completion = history.completions(before: String(address.dropLast(2)), after: "", selected: nil)
                            .contains { $0.surface == address && $0.source == .observed }
                        XCTAssertEqual(phantom, 0, mode + ": " + input)
                        XCTAssertFalse(completion, mode + ": " + input)
                        rows.append(["input": input, "embedded_address": address, "suffix": suffix, "mode": mode,
                                     "phantom_count": String(phantom), "phantom_observed_completion": String(completion),
                                     "stored": history.tokens.values.map(\.surface).sorted().joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
    func testPrefixedEmailBoundaryAudit() throws {
        let output = ProcessInfo.processInfo.environment["KB_PREFIXED_EMAIL_AUDIT"]
        var rows: [[String: String]] = []
        for local in ["\"First Last\"", "\"Çağrı Şen\""] {
            for domain in ["example.com", "mail.örnek.com", "[192.0.2.1]", "[IPv6:2001:db8::1]"] {
                let address = local + "@" + domain
                // These are deliberately joined technical strings, not prose
                // separators. Their embedded address was never a whole input.
                for prefix in ["path/", "user+", "prefix", "backup_", "other@", "value="] {
                    let input = prefix + address
                    var bulk = PersonalHistory(); bulk.observe(text: input + " ")
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for character in input + " " {
                        before.append(character)
                        observation.changed(before: before, documentID: id)
                        if character.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let phantom = history.tokens.values.first { $0.surface == address }?.count ?? 0
                        let completion = history.completions(before: String(address.dropLast(2)), after: "", selected: nil)
                            .contains { $0.surface == address && $0.source == .observed }
                        XCTAssertEqual(phantom, 0, mode + ": " + input)
                        XCTAssertFalse(completion, mode + ": " + input)
                        rows.append(["input": input, "embedded_address": address, "prefix": prefix, "mode": mode,
                                     "phantom_count": String(phantom), "phantom_observed_completion": String(completion),
                                     "stored": history.tokens.values.map(\.surface).sorted().joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output { try encoder.encode(rows).write(to: URL(fileURLWithPath: output)) }
    }
}
