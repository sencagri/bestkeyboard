import XCTest
import KBLearning

final class TechnicalCaseIdentityTests: XCTestCase {
    func testHostFoldingPreservesMailboxAndPathCaseAcrossReload() throws {
        var history = PersonalHistory()
        for value in ["Smith@INFO.example", "Smith@info.example", "smith@info.example",
                      "https://INFO.example/Page", "HTTPS://info.example/Page", "https://info.example/page"] {
            history.observe(token: value, previous: nil)
        }
        history = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.tokens.count, 4)
        XCTAssertEqual(history.tokens["Smith@info.example"]?.count, 2)
        XCTAssertEqual(history.tokens["https://info.example/Page"]?.count, 2)
        XCTAssertEqual(history.recall(prefix: "Smith@INFO"), ["Smith@info.example"])
        XCTAssertEqual(history.recall(prefix: "https://INFO.example/P"), ["HTTPS://info.example/Page"])
        XCTAssertEqual(history.recall(prefix: "https://INFO.example/p"), ["https://info.example/page"])
        history.forget("Smith@INFO.example")
        XCTAssertNil(history.tokens["Smith@info.example"])
        XCTAssertNotNil(history.tokens["smith@info.example"])
    }

    func testLegacyKeysMergeCountsWithoutFoldingSensitiveParts() throws {
        let legacy = #"{"tokens":{"dev@INFO.example":{"count":2,"seq":1,"surface":"dev@INFO.example"},"dev@info.example":{"count":3,"seq":2,"surface":"dev@info.example"}},"pairs":{},"seq":2,"pairTotal":0}"#
        let history = try JSONDecoder().decode(PersonalHistory.self, from: Data(legacy.utf8))
        XCTAssertEqual(history.tokens.count, 1)
        XCTAssertEqual(history.tokens["dev@info.example"]?.count, 5)
    }
}
