import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBMorphology

final class QuestionPathAuditTests: XCTestCase {
    func testQuestionRootCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_QUESTION_PATH_AUDIT"] else { throw XCTSkip("Set KB_QUESTION_PATH_AUDIT") }
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        let production = try XCTUnwrap(pack.decoder.lexicon.sources.compactMap(\.morphology).first)
        let baseline = MorphologyAutomaton(roots: ["mi", "nü"].map { Root($0, pos: .noun, lexCost: 4) })
        // Diagnostic counterfactual only: no package/model file is changed.
        let expanded = MorphologyAutomaton(roots: ["mi", "mı", "mu", "mü", "nü"].map { Root($0, pos: .noun, lexCost: 4) })
        func trace(_ a: MorphologyAutomaton, _ word: String) -> (Bool, String) {
            var states = Set(a.startStates()); var prefix = ""
            for ch in word {
                prefix.append(ch)
                states = Set(states.flatMap { a.arcs(from: $0).filter { $0.symbol == ch }.map(\.target) })
                if states.isEmpty { return (false, prefix) }
            }
            return (states.contains { a.isAccepting($0) }, "")
        }
        let words = "mi miyim miydiniz miymiş miymişsiniz miymişler mı mıyım mıydınız mıymış mıymışsınız mıymışlar mu muyum muydunuz muymuş muymuşsunuz muymuşlar mü müyüm müydünüz müymüş müymüşsünüz müymüşler nü nüymüşsünüz".split(separator: " ").map(String.init)
        var rows: [[String: String]] = []
        for word in words {
            let p = trace(production, word), b = trace(baseline, word), e = trace(expanded, word)
            rows.append(["input": word, "production_morphology": String(p.0), "production_dead_prefix": p.1,
                         "production_vocabulary": String(pack.literalChannel.score(word).isInVocabulary),
                         "baseline_two_roots": String(b.0), "expanded_five_roots": String(e.0)])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("QUESTION PATH AUDIT: \(rows.count) forms")
    }
}
