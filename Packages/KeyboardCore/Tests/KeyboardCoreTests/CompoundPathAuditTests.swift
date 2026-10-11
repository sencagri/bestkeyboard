import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBMorphology

final class CompoundPathAuditTests: XCTestCase {
    func testCompoundPaths() throws {
        guard let path=ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_AUDIT"] else {throw XCTSkip("Set KB_COMPOUND_PATH_AUDIT")}
        let pack=try PackLoader.load(layout:TurkishQ.layout(),source:RecordingTestSupport.packSource)
        let production=try XCTUnwrap(pack.decoder.lexicon.sources.compactMap(\.morphology).first)
        // Synthetic test-only harmony seeds; not actual pronunciations or pack edits.
        let harmonySeeds: [String: String]
        if let encoded = ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_HARMONY_SEEDS"] {
            harmonySeeds = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
        } else { harmonySeeds = [:] }
        let softKRoots = Set((ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_SOFT_K_ROOTS"] ?? "").split(separator: ",").map(String.init))
        let dropRoots = Set((ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_DROP_VOWEL_ROOTS"] ?? "").split(separator: ",").map(String.init))
        let isolated: MorphologyAutomaton
        if let roots = ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_NOUN_ROOTS"] {
            isolated = MorphologyAutomaton(roots: roots.split(separator: ",").map {
                Root(String($0), pos: .noun, lexCost: 4,
                     finalAlternation: softKRoots.contains(String($0)) ? .kToĞ : nil,
                     dropsVowel: dropRoots.contains(String($0)),
                     pronunciation: harmonySeeds[String($0)])
            })
        } else if let roots = ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_VERB_ROOTS"] {
            isolated = MorphologyAutomaton(roots: roots.split(separator: ",").map {
                Root(String($0), pos: .verb, lexCost: 4, dropsVowel: dropRoots.contains(String($0)))
            })
        } else {
            isolated = MorphologyAutomaton(roots:[
                Root("gel",pos:.verb,lexCost:4,aoristClass:.ir),
                Root("yap",pos:.verb,lexCost:4,aoristClass:.ar),
                Root("oku",pos:.verb,lexCost:4,aoristClass:.ir),
                Root("söyle",pos:.verb,lexCost:4,aoristClass:.ir)])
        }
        func trace(_ a:MorphologyAutomaton,_ word:String)->(Bool,String,String) {
            var states=Set(a.startStates());var prefix=""
            for ch in word {
                prefix.append(ch)
                let next=Set(states.flatMap{a.arcs(from:$0).filter{$0.symbol==ch}.map(\.target)})
                if next.isEmpty {return(false,prefix,Set(states.map{String(describing:$0.continuation)}).sorted().joined(separator:" | "))}
                states=next
            }
            return(states.contains{a.isAccepting($0)},"","")
        }
        func acceptedContinuations(_ a: MorphologyAutomaton, _ word: String) -> String {
            var states = Set(a.startStates())
            for ch in word {
                states = Set(states.flatMap { a.arcs(from: $0).filter { $0.symbol == ch }.map(\.target) })
            }
            return Set(states.filter { a.isAccepting($0) }.map { String(describing: $0.continuation) }).sorted().joined(separator: " | ")
        }
        let defaultWords="gelse gelseniz gelseydi gelseydiniz gelseymiş gelseymişsiniz gelmese gelmeseniz gelmeseydi gelmeseymişsiniz gelmez gelmezsiniz gelmezmişsiniz gelemez gelemezsiniz gelemezmişsiniz gelemem gelemeyiz gelemedim gelemeyeceğim yapamazdı yapamazdınız yapamazmışsınız yapmadınız yapamazsınız okuyamazmışsınız okuyamadımmışsınız söyleyemezmişsiniz söyleyemedimmişsiniz".split(separator:" ").map(String.init)
        let words: [String]
        if let input = ProcessInfo.processInfo.environment["KB_COMPOUND_PATH_CORPUS"] {
            words = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        } else { words = defaultWords }
        var rows:[[String:String]]=[]
        for word in words {
            let p=trace(production,word),i=trace(isolated,word)
            rows.append(["input":word,"production_morphology":String(p.0),"isolated_morphology":String(i.0),
                "production_vocabulary":String(pack.literalChannel.score(word).isInVocabulary),
                "production_accepting_continuations":acceptedContinuations(production,word),
                "isolated_accepting_continuations":acceptedContinuations(isolated,word),
                "production_dead_prefix":p.1,
                "isolated_dead_prefix":i.1,"isolated_continuations_before_dead_prefix":i.2])
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("COMPOUND PATH AUDIT: \(rows.count) surfaces")
    }
}
