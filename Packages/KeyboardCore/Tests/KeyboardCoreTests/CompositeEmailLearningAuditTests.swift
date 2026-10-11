import XCTest
import Foundation
import KBLearning

final class CompositeEmailLearningAuditTests: XCTestCase {
    func testCompositeEmailLearningAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_COMPOSITE_EMAIL_AUDIT"] else {
            throw XCTSkip("Opt-in composite email learning audit")
        }
        var rows: [[String: String]] = []
        for local in ["dev", "\"Çağrı Şen\"", "\"First @ Last\"", "\"First\\\" Last\""] {
            for domain in ["example.com", "mail.örnek.com", "[192.0.2.1]", "[IPv6:2001:db8::1]"] {
                let address = local + "@" + domain
                XCTAssertEqual(TechnicalTokenKind.classify(address), .email)
                for (left, right) in [("", ""), ("\"", "\""), ("'", "'"), ("“", "”"), ("«", "»"), ("(", ")"), ("(“", "”)")] {
                    for suffix in ["", ",", ";"] {
                        let text = "adres " + left + address + right + suffix + " sonra "
                        var bulk = PersonalHistory(); bulk.observe(text: text)
                        var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                        let id = UUID(); observation.changed(before: "", documentID: id)
                        for character in text {
                            before.append(character)
                            observation.changed(before: before, documentID: id)
                            if character.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                        }
                        for (mode, history) in [("bulk", bulk), ("live", live)] {
                            let count = history.tokens.values.first { $0.surface == address }?.count ?? 0
                            let surfaces = history.tokens.values.map(\.surface).sorted()
                            let exactSurfaces = surfaces == ["adres", address, "sonra"].sorted()
                            let hit = history.completions(before: String(address.dropLast(2)), after: "", selected: nil)
                                .contains { $0.surface == address && $0.source == .observed }
                            rows.append(["address": address, "left": left, "right": right, "suffix": suffix, "mode": mode,
                                "count": String(count), "surfaces_exact": String(exactSurfaces), "completion_exact": String(hit),
                                "stored": surfaces.joined(separator: " | ")])
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
