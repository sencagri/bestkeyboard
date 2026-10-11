import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBRuntime

final class PersonalCapacityAuditTests: XCTestCase {
    func testExplicitChoiceAtCapacity() throws {
        guard let path=ProcessInfo.processInfo.environment["KB_PERSONAL_CAPACITY_AUDIT"] else {throw XCTSkip("Set KB_PERSONAL_CAPACITY_AUDIT")}
        let layout=TurkishQ.layout()
        let pack=try PackLoader.load(layout:layout,source:RecordingTestSupport.packSource)
        let letters=Array("abcdefghijklmnopqrstuvwxyz")
        func word(_ i:Int)->String {"qx"+String(letters[i/676])+String(letters[(i/26)%26])+String(letters[i%26])+"menü"}
        var rows:[[String:String]]=[]
        for (mode,count,weakFirst) in [("room",511,true),("full_three_points",512,false),("full_four_points",512,true)] {
            var personal=PersonalLexicon()
            for i in 0..<count {
                if weakFirst {personal.observe(word(i),confidence:.weak)}
                personal.observe(word(i),confidence:.strong)
            }
            var c=InputCoordinator(layout:layout)
            c.setEngine(.init(decoder:pack.decoder,literalChannel:pack.literalChannel))
            c.replacePersonalLexicon(personal)
            func pickOriginal() throws {
                let doc=FakeDocument()
                c.invalidateComposing()
                for ch in "qrmenü" {let i=try XCTUnwrap(layout.keyIndex(for:ch));c.insertLetter(ch,touch:.init(down:layout.keys[i].center),into:doc)}
                let item=try XCTUnwrap(c.suggestions().first)
                XCTAssertEqual(item.surface,"qrmenü")
                try c.perform(.suggestionPick(id:item.id,surface:item.surface,origin:item.origin),touch:nil,into:doc)
                XCTAssertEqual(doc.text,"qrmenü ")
            }
            for attempt in 1...3 {
                try pickOriginal()
                rows.append(["mode":mode,"step":"pick_\(attempt)","count":String(c.personal.count),
                    "admitted":String(c.personal.isAdmitted("qrmenü")),
                    "points":String(c.personal.entries["qrmenü"]?.points ?? 0),
                    "oldest_retained":String(c.personal.isAdmitted(word(0)))])
            }
            if mode == "full_four_points" {
                c.forgetPersonal(word(0))
                try pickOriginal()
                rows.append(["mode":mode,"step":"forget_old_then_pick","admitted":String(c.personal.isAdmitted("qrmenü"))])
            }
            c.forgetPersonal("qrmenü")
            rows.append(["mode":mode,"step":"forget_target","admitted":String(c.personal.isAdmitted("qrmenü")),
                "engine_knows_target":String(c.engine?.literalChannel.score("qrmenü").isInVocabulary ?? false)])
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("PERSONAL CAPACITY AUDIT: \(rows.count) checkpoints")
    }
}
