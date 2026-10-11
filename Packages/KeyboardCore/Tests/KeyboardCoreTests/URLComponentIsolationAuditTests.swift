import XCTest
import Foundation
import KBLearning

final class URLComponentIsolationAuditTests: XCTestCase {
    func testURLComponentIsolationAudit() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_URL_COMPONENT_ISOLATION_AUDIT"] else { throw XCTSkip("Opt-in URL isolation audit") }
        var rows: [[String: String]] = []
        let saved = ["https://example.com/api/item?q=1#frag", "https://u:p@example.com/api/item",
                     "https://example.com:8443/api/item", "https://other.com/api/item",
                     "http://example.com/api/item", "https://example.com/API/Item",
                     "https://example.com/api/a%20b", "https://örnek.com/api/item"]
        let prefixes = ["http://example.com/ap", "ftp://example.com/ap", "ssh://example.com/ap",
                        "https://example.com:8443/ap", "https://example.com:443/ap", "https://other.com/ap",
                        "https://u@example.com/ap", "https://example.com/ap?q=2", "https://example.com/ap#x",
                        "https://ex", "http://ex", "exa", "other.c", "https://örnek.com/ap",
                        "https://example.com/AP", "https://example.com/api/a%20"]
        for observed in saved {
            var history = PersonalHistory(); history.observe(token: observed, previous: nil)
            XCTAssertTrue(history.tokens.values.contains { $0.surface == observed })
            let known = try XCTUnwrap(URLComponents(string: observed))
            for prefix in prefixes {
                let typed = URLComponents(string: prefix)
                let offers = history.completions(before: prefix, after: "", selected: nil)
                var violations: [String] = []
                var components = 0
                for offer in offers where offer.source != .observed {
                    components += 1
                    let parsed = URLComponents(string: offer.surface)
                    if known.user != nil || known.password != nil { violations.append("credential-source reused") }
                    if parsed?.query != nil || parsed?.fragment != nil || parsed?.user != nil || parsed?.password != nil { violations.append("sensitive component copied") }
                    if offer.source == .urlPath {
                        if typed?.host?.lowercased() != known.host?.lowercased() || typed?.port != known.port { violations.append("authority mismatch") }
                        if parsed?.scheme != typed?.scheme || parsed?.host != typed?.host || parsed?.port != typed?.port { violations.append("typed authority altered") }
                        if parsed?.percentEncodedPath != known.percentEncodedPath { violations.append("path changed") }
                    } else if offer.source == .urlHost {
                        if prefix.contains("://") && (parsed?.scheme != typed?.scheme || parsed?.percentEncodedPath != "" || parsed?.port != nil) { violations.append("host offer imported extra components") }
                    } else { violations.append("unexpected component kind") }
                }
                rows.append(["observed": observed, "prefix": prefix, "component_offers": String(components),
                             "observed_offers": String(offers.filter { $0.source == .observed }.count),
                             "offers": offers.map(\.surface).joined(separator: " | "), "violations": violations.joined(separator: " | ")])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
