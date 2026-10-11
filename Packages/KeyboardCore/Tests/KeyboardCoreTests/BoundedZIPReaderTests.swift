import XCTest
import Foundation
import KBFoundation

final class BoundedZIPReaderTests: XCTestCase {
    private func fixture(_ name: String) -> Data { Data(base64Encoded: fixtures[name]!)! }
    private func read(_ data: Data) -> Data? { BoundedZIPReader.firstEntry(in: data) { $0 == "chat.txt" } }
    func testStoredDeflateAndEmpty() {
        XCTAssertEqual(read(fixture("stored")), Data("hello chat".utf8))
        XCTAssertEqual(read(fixture("deflated")), Data(String(repeating: "hello chat", count: 40).utf8))
        XCTAssertEqual(read(fixture("empty")), Data())
    }
    func testEveryTruncationRejectsWithoutTrap() {
        for name in ["stored", "deflated"] {
            let data = fixture(name)
            for end in 0..<data.count { XCTAssertNil(read(Data(data.prefix(end))), "\(name): \(end)") }
        }
    }
    func testMalformedDirectoryAndLocalHeader() {
        let original = fixture("stored")
        let central = original.range(of: Data([0x50,0x4b,0x01,0x02]))!.lowerBound
        for offset in [central + 28, central + 30, central + 32, central + 42, 26, 28] {
            var data = original
            data[offset] = 0xff; data[offset + 1] = 0xff
            XCTAssertNil(read(data), "offset \(offset)")
        }
        var badSignature = original; badSignature[0] = 0
        XCTAssertNil(read(badSignature))
        var encrypted = original; encrypted[6] = 1; encrypted[central + 8] = 1
        XCTAssertNil(read(encrypted))
    }
    func testIntegrityAndAllocationLimits() {
        var badPayload = fixture("stored"); badPayload[38] ^= 1
        XCTAssertNil(read(badPayload))
        var large = fixture("deflated")
        let central = large.range(of: Data([0x50,0x4b,0x01,0x02]))!.lowerBound
        for i in 0..<4 { large[central + 24 + i] = 0xff }
        XCTAssertNil(read(large))
        var wrongSize = fixture("deflated"); wrongSize[central + 24] -= 1
        XCTAssertNil(read(wrongSize))
    }
    private let fixtures: [String: String] = [
        "stored": "UEsDBBQAAAAAAIusSl1BxKaACgAAAAoAAAAIAAAAY2hhdC50eHRoZWxsbyBjaGF0UEsBAhQDFAAAAAAAi6xKXUHEpoAKAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAGNoYXQudHh0UEsFBgAAAAABAAEANgAAADAAAAAAAA==",
        "deflated": "UEsDBBQAAAAIAIusSl3dw9OeEQAAAJABAAAIAAAAY2hhdC50eHTLSM3JyVdIzkgsyRhlDQIWAFBLAQIUAxQAAAAIAIusSl3dw9OeEQAAAJABAAAIAAAAAAAAAAAAAACAAQAAAABjaGF0LnR4dFBLBQYAAAAAAQABADYAAAA3AAAAAAA=",
        "empty": "UEsDBBQAAAAIAIusSl0AAAAAAgAAAAAAAAAIAAAAY2hhdC50eHQDAFBLAQIUAxQAAAAIAIusSl0AAAAAAgAAAAAAAAAIAAAAAAAAAAAAAACAAQAAAABjaGF0LnR4dFBLBQYAAAAAAQABADYAAAAoAAAAAAA="
    ]
}
