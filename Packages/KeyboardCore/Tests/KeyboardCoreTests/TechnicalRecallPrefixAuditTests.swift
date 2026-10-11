import XCTest
import Foundation
import KBLearning

/// Models the app's TypingHistory.recall guard; core history is production code.
/// Does not run UIKit or tap the suggestion bar.
final class TechnicalRecallPrefixAuditTests: XCTestCase {
    func testEveryTechnicalPrefix() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_TECH_PREFIX_AUDIT"] else {
            throw XCTSkip("Set KB_TECH_PREFIX_AUDIT")
        }
        let tokens = ["192.168.1.10", "10.0.0.1/24", "127.0.0.1:8080", "fe80::abcd", "2001:db8::1",
                      "tcp/ip", "https://example.com/api", "dev@example.com", "foo.bar()", ".env.local",
                      "./src/main.swift", "../src/main.swift", "/usr/local/bin", "user_id", "getUserById"]
        var rows: [[String: String]] = []
        for token in tokens {
            var h = PersonalHistory(); h.observe(text: token)
            for length in 2..<token.count {
                let raw = String(token.prefix(length))
                let normalized = PersonalHistory.tokenize(raw).last ?? ""
                let direct = h.recall(prefix: raw).first ?? ""
                let routed = !normalized.isEmpty && raw.hasSuffix(normalized)
                    ? h.recall(prefix: normalized).first ?? "" : ""
                rows.append(["token": token, "prefix": raw, "normalized": normalized,
                    "stored": h.tokens.values.map(\.surface).sorted().joined(separator: " | "),
                    "direct": direct, "routed": routed,
                    "lost_by_routing": String(!direct.isEmpty && routed.isEmpty)])
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
