import XCTest
import KBLearning

final class TechnicalTokenKindTests: XCTestCase {
    func testLongRecognizedAddressesAndInternationalPhonesAreRecallable() {
        for value in ["255.255.255.255:65535", "1234:5678:1234:5678:1234:5678:1234:5678", "+123456789012345"] {
            var h = PersonalHistory()
            h.observe(token: value, previous: nil)
            XCTAssertEqual(h.recall(prefix: String(value.prefix(4))).first, value)
        }
        for value in ["4111111111111111", "[4111111111111111]", "+1234567890123456", "999.999.999.999:99999", "255.255.255.255:+65535"] {
            var h = PersonalHistory()
            h.observe(token: value, previous: nil)
            XCTAssertTrue(h.tokens.isEmpty, value)
        }
    }
}
