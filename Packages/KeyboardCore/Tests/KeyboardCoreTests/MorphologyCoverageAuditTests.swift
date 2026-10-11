import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBMorphology
import KBRuntime

final class MorphologyCoverageAuditTests: XCTestCase {
    func testProductionMorphologyCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_MORPH_AUDIT"] else { throw XCTSkip("Set KB_MORPH_AUDIT") }
        let layout=TurkishQ.layout()
        let pack=try PackLoader.load(layout:layout,source:RecordingTestSupport.packSource)
        let morphology=try XCTUnwrap(pack.decoder.lexicon.sources.compactMap(\.morphology).first)
        func accepts(_ word: String) -> Bool {
            var states=Set(morphology.startStates())
            for ch in word {
                states=Set(states.flatMap { morphology.arcs(from:$0).filter { $0.symbol == ch }.map(\.target) })
                if states.isEmpty { return false }
            }
            return states.contains { morphology.isAccepting($0) }
        }
        let groups:[(String,[String])] = [
            ("passive",["yazdı","yazıldı","yazılıyordu","yazılmadı","yazılmayacak","yazılmayacakmışsınız","yazılacaktınız","yazılmış","yazılmıştınız","yazılabilecek","yazılabilecekmişsiniz","okundu","okunuyordu","okunmamış","okunmayacakmışız","söylendi","söyleniyordu","söylenmemişsiniz"]),
            ("ability_aorist",["yapar","yapabilir","yapabilirim","yapabilirseniz","yapabiliyorum","yapabildim","gelebilir","gelebilirim","gelebilirseniz","gelebileceğim","yaptırır","yaptırırım","yaptırırsanız"]),
            ("person_repetition_probe",["gelmiştim","gelmişlerdi","gelmişimdim","gelmişindim","geldimdim","geldindin","geldikdik","geldimdimdim","yaptımdım","yaptımdımdım"]),
            ("positive_controls",["evlerimizden","kitabımızın","geliyordunuz","geleceğim"])
        ]
        var rows:[[String:String]]=[]
        for (group,words) in groups { for word in words {
            var c=InputCoordinator(layout:layout)
            c.setEngine(.init(decoder:pack.decoder,literalChannel:pack.literalChannel))
            let doc=FakeDocument()
            for ch in word { let i=try XCTUnwrap(layout.keyIndex(for:ch));c.insertLetter(ch,touch:.init(down:layout.keys[i].center),into:doc) }
            let known=pack.literalChannel.score(word).isInVocabulary
            let report=c.space(into:doc)
            rows.append(["group":group,"input":word,"morphology_accepts":String(accepts(word)),"vocabulary_accepts":String(known),"output":doc.text,"decision":report.kind.rawValue])
        }}
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("MORPHOLOGY AUDIT: \(rows.count) probes")
    }
}
