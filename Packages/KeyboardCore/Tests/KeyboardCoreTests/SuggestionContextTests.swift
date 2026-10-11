import XCTest
import KBRuntime

final class SuggestionContextTests: XCTestCase {
    func testSameTextInAnotherFieldIsNotThePresentedContext() {
        let id = UUID()
        let original = SuggestionContext(documentID: id, before: "kal", selected: nil, after: "")
        XCTAssertEqual(original, SuggestionContext(documentID: id, before: "kal", selected: nil, after: ""))
        XCTAssertNotEqual(original, SuggestionContext(documentID: UUID(), before: "kal", selected: nil, after: ""))
        XCTAssertNotEqual(original, SuggestionContext(documentID: id, before: "kal", selected: nil, after: "em"))
        XCTAssertNotEqual(original, SuggestionContext(documentID: id, before: "kal", selected: "em", after: ""))
        XCTAssertNotEqual(original, SuggestionContext(documentID: id, before: "kal", selected: nil, after: nil))
    }
}
