import XCTest
@testable import KBRuntime

final class TechnicalInflectionTests: XCTestCase {
    func testRegularSuffixChainsProtectAlternateReadingsWithoutArbitraryPrefixMatches() {
        for word in ["facebooklerimizden", "chatgptlarımızdan", "googlelerimizden", "graphqlden", "httpde",
                     "httpste", "iphonelerimizden", "mqttye", "shopifylerimizden",
                     "spotifylerimizden", "sqllarımızdan", "graphqlümüzdeymiş"] {
            XCTAssertTrue(TechnicalVocabulary.contains(word), word)
        }
        for word in ["httpmerhaba", "sqlxyz", "mqttyeabc", "googlelerimizdenxyz", "kalen"] {
            XCTAssertFalse(TechnicalVocabulary.contains(word), word)
        }
    }
}
