import XCTest
@testable import KBRuntime

final class DocumentEditPlanTests: XCTestCase {
    func testStalePlanDoesNotDeleteHostText() {
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce kalen")
        let plan = DocumentEditPlan(snapshot: .init(doc), target: .suffix("kalen"), replacement: "kalem")
        doc.hostRewrites(to: "başka kalen")
        XCTAssertFalse(plan.apply(to: doc))
        XCTAssertEqual(doc.text, "başka kalen")
    }

    func testSuffixCannotConsumeSelectionOrWrongSuffix() {
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce kalen")
        doc.hostSelects("kalen")
        XCTAssertFalse(DocumentEditPlan(snapshot: .init(doc), target: .suffix("kalen"), replacement: "kalem").apply(to: doc))
        XCTAssertEqual(doc.text, "önce kalen")
        doc.hostRewrites(to: "önce başka")
        XCTAssertFalse(DocumentEditPlan(snapshot: .init(doc), target: .suffix("kalen"), replacement: "kalem").apply(to: doc))
        XCTAssertEqual(doc.text, "önce başka")
    }

    func testGraphemeReplacementPreservesSurroundings() {
        let doc = FakeDocument()
        doc.hostRewrites(to: "önce 👩🏽‍💻a")
        XCTAssertTrue(DocumentEditPlan(snapshot: .init(doc), target: .suffix("👩🏽‍💻a"), replacement: "güzel").apply(to: doc))
        XCTAssertEqual(doc.text, "önce güzel")
        doc.hostSelects("güzel")
        XCTAssertTrue(DocumentEditPlan(snapshot: .init(doc), target: .selection("güzel"), replacement: "güzel").apply(to: doc))
        XCTAssertNil(doc.selectedText)
        doc.insertText("!")
        XCTAssertEqual(doc.text, "önce güzel!")
    }
}
