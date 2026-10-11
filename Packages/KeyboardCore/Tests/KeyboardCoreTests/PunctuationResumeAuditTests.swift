import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBRuntime

final class PunctuationResumeAuditTests: XCTestCase {
    func testResumeAfterDeletingBoundary() throws {
        guard let path=ProcessInfo.processInfo.environment["KB_PUNCT_RESUME_AUDIT"] else { throw XCTSkip("Set KB_PUNCT_RESUME_AUDIT") }
        let layout=TurkishQ.layout()
        let pack=try PackLoader.load(layout:layout,source:RecordingTestSupport.packSource)
        let words=[("ev","deymişsiniz"),("sokak","taydım"),("gel","emiyormuşsunuz"),
                   ("yazıl","mayacakmışsınız"),("qr","menü"),("kitap","çıklarımızdan"),
                   ("ev","lerimizden"),("kalem","lerimizden"),("çocuk","larımızdan"),("okun","mayacakmışız")]
        let modes = ProcessInfo.processInfo.environment["KB_PUNCT_MODES"]?.split(separator: ",").map(String.init) ?? ["direct","space_backspace","period_backspace","comma_backspace"]
        var rows:[[String:String]]=[]
        for (stem,suffix) in words {
            for mode in modes {
                var c=InputCoordinator(layout:layout)
                c.setEngine(.init(decoder:pack.decoder,literalChannel:pack.literalChannel))
                let doc=FakeDocument()
                func type(_ word:String) throws {
                    for ch in word {let i=try XCTUnwrap(layout.keyIndex(for:ch));c.insertLetter(ch,touch:.init(down:layout.keys[i].center),into:doc)}
                }
                try type(stem)
                if mode != "direct" {
                    if mode == "space_backspace" {c.space(into:doc)}
                    else if mode == "double_space_backspace" { c.space(into: doc); c.space(into: doc); c.backspaceTap(into: doc) }
                    else if mode == "triple_space_backspace" { c.space(into: doc); c.space(into: doc); c.space(into: doc); c.backspaceTap(into: doc); c.backspaceTap(into: doc) }
                    else if mode == "digit_backspace" { c.insertSymbol("1", into: doc) }
                    else if mode == "hyphen_backspace" { c.insertSymbol("-", into: doc) }
                    else if mode == "apostrophe_backspace" { c.insertSymbol("’", into: doc) }
                    else if mode == "emoji_backspace" { c.insertText("🙂", into: doc) }
                    else if mode == "zwj_backspace" { c.insertText("👨‍👩‍👧‍👦", into: doc) }
                    else if mode == "flag_backspace" { c.insertText("🇹🇷", into: doc) }
                    else {c.insertSymbol(mode == "period_backspace" ? "." : ",",into:doc)}
                    c.backspaceTap(into:doc)
                }
                let resumed=c.session.display
                try type(suffix)
                let before=doc.text
                let first=c.suggestions().first?.surface ?? ""
                let report=c.space(into:doc)
                rows.append(["input":stem+suffix,"stem":stem,"suffix":suffix,"mode":mode,
                    "resumed_display":resumed,"before_space":before,"first_suggestion":first,
                    "output":doc.text,"decision":report.kind.rawValue])
            }
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("PUNCTUATION RESUME AUDIT: \(rows.count) sequences")
    }
}
