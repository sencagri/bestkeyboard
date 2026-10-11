import XCTest
import KBLearning

final class GroupedPhoneTests: XCTestCase {
    func testGroupedPhoneRemainsOneObservedToken() {
        let phone = "+90 (532) 123 45 67"
        XCTAssertEqual(TechnicalTokenKind.classify(phone), .phone)
        XCTAssertEqual(PersonalHistory.tokenize("numaram " + phone + " ara"), ["numaram", phone, "ara"])
        var history = PersonalHistory()
        history.observe(text: phone)
        XCTAssertEqual(history.tokens["+905321234567"]?.surface, phone)
        history.observe(token: "+905321234567", previous: nil)
        XCTAssertEqual(history.tokens["+905321234567"]?.count, 2)
        XCTAssertEqual(history.completions(before: "ara +90 532", after: "", selected: nil).first?.surface, "+905321234567")
        XCTAssertEqual(history.completions(before: "ara +90 532", after: "", selected: nil).first?.prefix, "+90 532")
    }

    func testTurkishDomesticPhoneFormatsPersistAndCompleteWhole() throws {
        for phone in ["0532 123 45 67", "(0532)1234567", "0212 123 45 67"] {
            XCTAssertEqual(TechnicalTokenKind.classify(phone), .phone)
            XCTAssertEqual(PersonalHistory.tokenize("ara " + phone + " şimdi"), ["ara", phone, "şimdi"])
            var history = PersonalHistory()
            history.observe(text: phone)
            history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
            let prefix = phone.hasPrefix("(") ? "(0532)" : String(phone.prefix(8))
            let offer = try XCTUnwrap(history.completions(before: "ara " + prefix, after: "", selected: nil).first)
            XCTAssertEqual(offer.surface, phone)
            XCTAssertEqual(offer.prefix, prefix)
        }
    }

    func testDigitGroupsAndMalformedPhonesDoNotBecomePhoneExceptions() {
        for value in ["4111 1111 1111 1111", "+4111 1111 1111 1111", "+90 (532 1234567", "+00 532 1234567", "+90 abc 5321234567"] {
            XCTAssertNotEqual(TechnicalTokenKind.classify(value), .phone, value)
        }
    }
}
