import XCTest
import Foundation
import KBGeometry

final class TechnicalKeyCoverageAuditTests: XCTestCase {
    func testDirectKeyCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_KEY_COVERAGE_AUDIT"] else { throw XCTSkip("Set KB_KEY_COVERAGE_AUDIT") }
        let letters = TurkishQ.row1 + TurkishQ.row2 + TurkishQ.row3
        let upper = letters.flatMap { Array(String($0).uppercased(with: Locale(identifier: "tr_TR"))) }
        let symbols = SymbolPlanes.numbers.keys.map(\.char) + SymbolPlanes.symbols.keys.map(\.char)
        let available = Set(letters + upper + symbols + [" ", "\n", ",", "."])
        let probes = (32...126).compactMap { UnicodeScalar($0) }.map { Character(String($0)) } + ["\t", "â", "î", "û"]
        let rows = probes.map { ch in
            ["character": String(ch), "codepoint": String(ch.unicodeScalars.first!.value),
             "direct_key_available": String(available.contains(ch))]
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
