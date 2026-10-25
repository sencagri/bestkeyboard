import XCTest
import KBAssembly
import KBGeometry
import KBRuntime

final class AccidentalBoundaryContinuationTests: XCTestCase {
    func testContinuingAfterPrematureSpaceRestoresOriginalKnownWord() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (prefix, tail) in [("mühendisl", "ik"), ("değerlendirilmesi", "ni"), ("eczanelerd", "en")] {
            for offset in [-0.18, 0.0, 0.18] {
                for explicitChoice in [false, true] {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    func type(_ text: String) throws {
                        for ch in text {
                            let index = try XCTUnwrap(layout.keyIndex(for: ch))
                            let key = layout.keys[index]
                            c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                                       y: key.center.y + offset * key.height)), into: doc)
                        }
                    }
                    try type(prefix)
                    if explicitChoice {
                        let pick = try XCTUnwrap(c.candidates().first)
                        c.pickSuggestion(pick.word, into: doc)
                    } else { c.space(into: doc) }
                    let committedPrefix = String(doc.text.dropLast())
                    c.backspaceTap(into: doc)
                    try type(tail)
                    let expected = (explicitChoice ? committedPrefix : prefix) + tail
                    XCTAssertEqual(doc.text, expected, "\(prefix) + stray space + delete + \(tail), offset=\(offset), explicit=\(explicitChoice)")
                    c.space(into: doc)
                    XCTAssertEqual(doc.text, expected + " ")
                }
            }
        }
    }
    func testDeletingDuplicateAfterMixedBoundaryRestoresTypedPrefix() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (prefix, tail) in [("sevgii", "lim"), ("sevgilii", "m"), ("buluşalıı", "m")] {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                func type(_ text: String) throws {
                    for ch in text {
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(
                            x: key.center.x + offset * key.width,
                            y: key.center.y + offset * key.height)), into: doc)
                    }
                }
                try type(prefix)
                c.space(into: doc)
                c.newline(into: doc)
                c.backspaceTap(into: doc)
                c.backspaceTap(into: doc)
                c.backspaceTap(into: doc)
                try type(tail)
                let expected = String(prefix.dropLast()) + tail
                XCTAssertEqual(doc.text, expected, "prefix=\(prefix), offset=\(offset)")
                c.space(into: doc)
                XCTAssertEqual(doc.text, expected + " ")
            }
        }
    }

    func testEditingReopenedAutomaticCorrectionRestoresTypingButExplicitChoiceStays() throws {
        let layout = TurkishQ.layout()
        for explicit in [false, true] {
            var c = try TestLexicon.coordinator(["kalem": 9000], layout: layout)
            c.correction.oovTheta = -1000
            let doc = FakeDocument()
            for ch in "kalm" {
                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                c.insertLetter(ch, touch: .init(down: key.center), into: doc)
            }
            if explicit { c.pickSuggestion("kalem", into: doc) }
            else { XCTAssertEqual(c.space(into: doc).kind, .autocorrect) }
            XCTAssertEqual(doc.text, "kalem ")
            c.backspaceTap(into: doc)
            XCTAssertEqual(doc.text, "kalem")
            c.backspaceTap(into: doc)
            XCTAssertEqual(doc.text, explicit ? "kale" : "kal")
            if !explicit {
                XCTAssertEqual(c.session.literal, "kal")
                XCTAssertFalse(c.session.isDetached)
            }
        }
    }

}
