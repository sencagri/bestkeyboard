import XCTest
import KBLearning

final class HistoryCompletionTests: XCTestCase {
    func testHostPathAndPortComponentsAreExplicitConstructedOffers() throws {
        var history = PersonalHistory()
        history.observe(token: "https://example.com/api?secret=value", previous: nil)
        history.observe(token: "10.0.0.1:8080", previous: nil)
        let cases: [(String, String, PersonalHistory.Completion.Source)] = [
            ("example.c", "example.com", .urlHost),
            ("http://example.com/a", "http://example.com/api", .urlPath),
            ("10.0.0.2:80", "10.0.0.2:8080", .port)]
        for (prefix, expected, source) in cases {
            let offer = try XCTUnwrap(history.completions(before: prefix, after: "", selected: nil).first)
            XCTAssertEqual(offer.surface, expected)
            XCTAssertEqual(offer.source, source)
        }
        for prefix in ["http://other.com/a", "http://example.com/API", "http://example.com:8443/a", "10.0.0.2:70", "10.0.0.2/24:80", "fe80::80", "example"] {
            XCTAssertTrue(history.completions(before: prefix, after: "", selected: nil).isEmpty, prefix)
        }
    }

    func testMiddleCompletionPreservesExistingTailWithoutDuplicatingIt() throws {
        var h = PersonalHistory()
        h.observe(token: "dev@example.com", previous: nil)
        let hit = try XCTUnwrap(h.completions(before: "mail dev@ex", after: ".com sonra", selected: nil).first)
        XCTAssertEqual(hit.literalSurface, "dev@ex.com")
        XCTAssertEqual(hit.rightToken, ".com")
        XCTAssertEqual(hit.replacementBeforeCursor + hit.after, "dev@example.com sonra")
        XCTAssertTrue(h.completions(before: "dev@ex", after: ".org", selected: nil).isEmpty)
        XCTAssertFalse(hit.matches(before: "mail dev@ex", after: ".org sonra", selected: nil))
    }
    func testComponentsReuseOnlyDomainAndPreserveTypedLocalPartAndScheme() throws {
        var h = PersonalHistory()
        h.observe(token: "old@example.com", previous: nil)
        h.observe(token: "https://example.org:8443/Secret?key=value", previous: nil)
        let email = try XCTUnwrap(h.completions(before: "NEW@exa", after: "", selected: nil).first)
        XCTAssertEqual(email.surface, "NEW@example.com")
        XCTAssertEqual(email.source, .emailDomain)
        let url = try XCTUnwrap(h.completions(before: "http://Exa", after: "", selected: nil).first)
        XCTAssertEqual(url.surface, "http://Example.org")
        XCTAssertEqual(url.source, .urlHost)
        XCTAssertTrue(h.completions(before: "http://example.org/new", after: "", selected: nil).isEmpty)
        XCTAssertTrue(h.completions(before: "http://exa:80", after: "", selected: nil).isEmpty)
    }

    func testObservedAddressRanksBeforeConstructedAndDomainsAreDeduplicated() {
        var h = PersonalHistory()
        for token in ["a@example.com", "b@example.com", "NEW@example.net"] { h.observe(token: token, previous: nil) }
        let results = h.completions(before: "NEW@exa", after: "", selected: nil)
        XCTAssertEqual(results.map(\.surface), ["NEW@example.net", "NEW@example.com"])
        XCTAssertEqual(results.first?.source, .observed)
        XCTAssertTrue(h.completions(before: "https://new@exa", after: "", selected: nil).isEmpty)
    }

    func testDotBoundaryMultipleOffersAndStaleGuard() throws {
        var h = PersonalHistory()
        for value in ["192.168.1.1", "192.168.1.2", "192.168.2.1"] { h.observe(token: value, previous: nil) }
        let offers = h.completions(before: "sunucu 192.168.", after: "", selected: nil)
        XCTAssertEqual(offers.count, 3)
        let first = try XCTUnwrap(offers.first)
        XCTAssertEqual(first.prefix, "192.168.")
        XCTAssertTrue(first.matches(before: "sunucu 192.168.", after: "", selected: nil))
        XCTAssertFalse(first.matches(before: "diğer 192.168.", after: "", selected: nil))
        XCTAssertFalse(first.matches(before: "sunucu 192.168.", after: "", selected: "x"))
    }

    func testMiddleOfTokenAndUnknownContextDoNotOfferDestructiveCompletion() {
        var h = PersonalHistory()
        h.observe(token: "dev@example.com", previous: nil)
        XCTAssertTrue(h.completions(before: "dev@exa", after: "mple.com", selected: nil).isEmpty)
        XCTAssertTrue(h.completions(before: "dev@exa", after: nil, selected: nil).isEmpty)
        XCTAssertTrue(h.completions(before: "dev@exa", after: "", selected: "mple.com").isEmpty)
        XCTAssertEqual(h.completions(before: "dev@exa", after: " next", selected: nil).first?.surface, "dev@example.com")
    }
}
