import XCTest
import KBDecoder
@testable import KBRuntime

final class CircumflexSuggestionPreferenceTests: XCTestCase {
    private func offers(_ words: [String], typed: String, limit: Int = 3) -> [String] {
        let candidates = words.enumerated().map {
            DecodeResult(word: $0.element, cost: Double($0.offset), emitCount: $0.element.count)
        }
        return SuggestionPresenter(window: 10).surfaces(shown: candidates, typed: typed,
                                                       expansions: nil, limit: limit)
    }

    func testUnaccentedInputPrefersAnExistingUnaccentedAlternative() {
        XCTAssertEqual(offers(["fedakâr", "fedakar"], typed: "fedakkar", limit: 2),
                       ["fedakkar", "fedakar"])
        XCTAssertEqual(offers(["MİLLÎ", "MİLLİ"], typed: "MİLLİİ"),
                       ["MİLLİİ", "MİLLİ", "MİLLÎ"])
        XCTAssertEqual(offers(["SÜKÛNET", "SÜKUNET"], typed: "SÜKUNNET"),
                       ["SÜKUNNET", "SÜKUNET", "SÜKÛNET"])
    }

    func testExplicitCircumflexAndUnrelatedCandidatesKeepTheirOrder() {
        XCTAssertEqual(offers(["fedakâr", "fedakar"], typed: "fedakkâr"),
                       ["fedakkâr", "fedakâr", "fedakar"])
        XCTAssertEqual(offers(["fedakâr"], typed: "fedakkar"), ["fedakkar", "fedakâr"])
        XCTAssertEqual(offers(["sene", "sana"], typed: "sna"), ["sna", "sene", "sana"])
        XCTAssertEqual(offers(["fedakâr", "fedakar"], typed: ""), ["fedakâr", "fedakar"])
    }
}
