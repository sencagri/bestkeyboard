import XCTest
import Foundation
import KBLearning

final class TechnicalSensitiveCaseAuditTests: XCTestCase {
    func testCaseSensitiveCompletionAndForgetIsolation() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SENSITIVE_CASE_AUDIT"] else { throw XCTSkip("Opt-in case isolation audit") }
        let pairs = [
            ("https://örnek.com/ÇağrıDeveloper", "https://örnek.com/çağrıdeveloper"),
            ("https://example.com/API/Item", "https://example.com/api/item"),
            ("https://example.com/?Mode=UPPER", "https://example.com/?mode=lower"),
            ("https://example.com/#SECTION", "https://example.com/#section"),
            ("ÇağrıDeveloper@örnek.com", "çağrıdeveloper@örnek.com"),
            ("Developer@INFO.example", "developer@INFO.example"),
            ("/Users/Çağrı/Project", "/Users/çağrı/project"),
            ("myDeveloper_Value", "mydeveloper_value")
        ]
        var rows: [[String: String]] = []
        for (upper, lower) in pairs {
            for reverse in [false, true] {
                for reload in [false, true] {
                    var history = PersonalHistory()
                    for value in reverse ? [lower, upper] : [upper, lower] { history.observe(token: value, previous: nil) }
                    if reload { history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history)) }
                    for (wanted, other) in [(upper, lower), (lower, upper)] {
                        for cut in [1, 2, 3] {
                            let prefix = String(wanted.dropLast(cut))
                            let offers = history.completions(before: prefix, after: "", selected: nil, limit: 10)
                            let observed = offers.filter { $0.source == .observed }.map(\.surface)
                            var forgotten = history
                            forgotten.forget(wanted)
                            let remaining = Set(forgotten.tokens.values.map(\.surface))
                            rows.append(["wanted": wanted, "other": other, "prefix": prefix,
                                         "reverse": String(reverse), "reload": String(reload),
                                         "distinct": String(history.tokens.count == 2),
                                         "wanted_offered": String(observed.contains(wanted)),
                                         "other_not_offered": String(!observed.contains(other)),
                                         "forget_isolated": String(remaining == Set([other])),
                                         "offers": offers.map(\.surface).joined(separator: " | ")])
                        }
                    }
                }
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
