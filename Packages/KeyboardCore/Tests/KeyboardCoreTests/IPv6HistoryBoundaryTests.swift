import XCTest
import Foundation
import KBLearning

final class IPv6HistoryBoundaryTests: XCTestCase {
    func testIPv6ColonBoundariesPreserveAddressIdentity() throws {
        let addresses = ["::", "::1", "::ffff:192.0.2.1", "2001:db8::", "fe80::", "0:0::1",
                         "[::1]", "[::1]:443", "::/0", "2001:db8::/32", "FE80::1", "2001:DB8::A"]
        for address in addresses {
            XCTAssertEqual(TechnicalTokenKind.classify(address), .ipv6, address)
            XCTAssertEqual(PersonalHistory.tokenize(address), [address], address)
            for suffix in ["", ",", "!", "…"] {
            XCTAssertEqual(PersonalHistory.tokenize(address + suffix), [address], address + suffix)
            for prefix in ["", "önce ", "önce\n"] {
                for gap in [" ", "\n"] {
                    let text = prefix + address + suffix + gap + "sonra "
                    var expected = PersonalHistory()
                    expected.observe(text: prefix)
                    expected.observe(token: address, previous: prefix == "önce " ? "önce" : nil)
                    expected.observe(token: "sonra", previous: gap == " " ? address : nil)
                    var bulk = PersonalHistory(); bulk.observe(text: text)
                    var live = PersonalHistory(), observation = HistoryObservation(), before = ""
                    let id = UUID(); observation.changed(before: "", documentID: id)
                    for ch in text {
                        before.append(ch)
                        observation.changed(before: before, documentID: id)
                        if ch.isWhitespace, let event = observation.completed(before: before, documentID: id) { live.observe(event) }
                    }
                    for (mode, history) in [("bulk", bulk), ("live", live)] {
                        let label = address + " " + mode + " " + prefix.debugDescription + " " + gap.debugDescription
                        XCTAssertEqual(history.tokens.mapValues(\.count), expected.tokens.mapValues(\.count), label)
                        XCTAssertEqual(history.pairs.mapValues { $0.mapValues(\.count) }, expected.pairs.mapValues { $0.mapValues(\.count) }, label)
                    }
                }
            }
            }
        }
    }
}
