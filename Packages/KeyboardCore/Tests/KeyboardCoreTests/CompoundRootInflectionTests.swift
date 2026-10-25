import XCTest
import KBMorphology
import KBAssembly
import KBGeometry

final class CompoundRootInflectionTests: XCTestCase {
    func testProductionCompoundRootsRecognizeOrdinaryInflections() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for word in ["anaokulundan", "anaokullarımızdan", "ayakucuna", "ayakuçlarında",
                     "buzdolaplarımız", "işyerlerinde", "acemborum", "acemboruları", "deveboyunlarında",
                     "yeryüzleri", "yeryüzlerinde", "yeryüzümüzden",
                     "güveyfeneri", "güveyfenerini", "güveyfenerleri", "güveyfenerlerinden",
                     "hasekiküpesi", "hasekiküpesini", "hasekiküpeleri", "hasekiküpelerinden",
                     "havvaanaeli", "havvaanaelini", "havvaanaelleri", "havvaanaellerinden",
                     "tavuskuyruğu", "tavuskuyruğunu", "tavuskuyrukları", "tavuskuyruklarından"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }

    func testReviewedCompoundStemsDoNotDoubleTheirPossessiveSuffix() throws {
        let roots = [
            Root("güveyfeneri", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "güveyfener"),
            Root("hasekiküpesi", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "hasekiküpe"),
            Root("havvaanaeli", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "havvaanael"),
            Root("tavuskuyruğu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "tavuskuyruk")
        ]
        for word in ["güveyfenerleri", "hasekiküpeleri", "havvaanaelleri", "tavuskuyrukları"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["güveyfeneriler", "güveyfeneriye", "hasekiküpesiler", "hasekiküpesiye",
                     "havvaanaeliler", "havvaanaeliye", "tavuskuyruğular", "tavuskuyruğuya"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }

    func testReviewedHeadCompoundsAndProperPlaceKeepPossessiveCaseBuffer() throws {
        let roots = [
            Root("bacabaşı", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "bacabaş"),
            Root("borazancıbaşı", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "borazancıbaş"),
            Root("beşikdüzü", pos: .proper, lexCost: 4, features: .possessiveCompound, compoundStem: "beşikdüz")
        ]
        let decoded = try RootPack(data: Data(RootPack.build(roots: roots))).roots
        XCTAssertEqual(decoded.last?.pos, .proper)
        for word in ["bacabaşı", "bacabaşını", "bacabaşları", "bacabaşlarından",
                     "borazancıbaşı", "borazancıbaşını", "borazancıbaşları", "borazancıbaşlarından",
                     "beşikdüzü", "beşikdüzüne", "beşikdüzünde", "beşikdüzünden"] {
            XCTAssertTrue(accepts(word, roots: decoded), word)
        }
        for word in ["bacabaşılar", "bacabaşıya", "borazancıbaşılar", "borazancıbaşıya",
                     "beşikdüzüye", "beşikdüzüde", "beşikdüzüden"] {
            XCTAssertFalse(accepts(word, roots: decoded), word)
        }
    }

    func testWaterCompoundRetainsYForPossessionButNotPlural() throws {
        let roots = [Root("arapsuyu", pos: .proper, lexCost: 4,
                          features: .possessiveCompound, compoundStem: "arapsu"),
                     Root("acemborusu", pos: .noun, lexCost: 4,
                          features: .possessiveCompound, compoundStem: "acemboru")]
        let decoded = try RootPack(data: Data(RootPack.build(roots: roots))).roots
        for word in ["arapsuyu", "arapsuyuna", "arapsuyunda", "arapsuyundan",
                     "arapsuyunun", "arapsuyum", "arapsuyumuz", "arapsuları",
                     "acemborum", "acemboruları"] {
            XCTAssertTrue(accepts(word, roots: decoded), word)
        }
        for word in ["arapsum", "arapsumuz", "arapsuyuya", "arapsuyuda",
                     "arapsuyular", "arapsuyları", "acemborusum"] {
            XCTAssertFalse(accepts(word, roots: decoded), word)
        }
    }

    func testV2PackStillLoadsPronunciationWithoutCompoundMetadata() throws {
        // Frozen v2 record: sql, noun, lexical cost 4, pronunciation seküel.
        let bytes = try XCTUnwrap(Data(base64Encoded: "QktSMQIAAAABAAAAAwAAAAYAAwAAAAAAGcd3vEf357plAAAAawAAAGwAAABxAAAAcwAAAPwAAAAAAAAAAwAAAAQAAwACAAAAAAAAgEAAAAAABgAAAAQAAAABAAUAAAACAA=="))
        let roots = try RootPack(data: bytes).roots
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(String(roots[0].surface), "sql")
        XCTAssertEqual(roots[0].pronunciation, "seküel")
        XCTAssertNil(roots[0].compoundStem)
    }

    func testCompoundPackRejectsTruncatedAndOutOfAlphabetStem() throws {
        let root = Root("ayakucu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "ayakuç")
        var bytes = RootPack.build(roots: [root])
        XCTAssertEqual(try RootPack(data: Data(bytes)).roots.first?.compoundStem, "ayakuç")
        XCTAssertThrowsError(try RootPack(data: Data(bytes.dropLast()), verifyChecksum: false))
        bytes[bytes.count - 2] = 255
        bytes[bytes.count - 1] = 255
        XCTAssertThrowsError(try RootPack(data: Data(bytes), verifyChecksum: false))
    }

    private func accepts(_ word: String, roots: [Root]) -> Bool {
        let morphology = MorphologyAutomaton(roots: roots)
        var states = Set(morphology.startStates())
        for letter in word {
            states = Set(states.flatMap { morphology.arcs(from: $0).filter { $0.symbol == letter }.map(\.target) })
        }
        return states.contains { morphology.isAccepting($0) }
    }

    func testCompoundPossessionPluralAndCaseUseTheUnderlyingStem() throws {
        let roots = [
            Root("anaokulu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "anaokul"),
            Root("ayakucu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "ayakuç"),
            Root("buzdolabı", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "buzdolap"),
            Root("acemborusu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "acemboru"),
            Root("deveboynu", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "deveboyun"),
            Root("kuşsesi", pos: .noun, lexCost: 4, features: .possessiveCompound, compoundStem: "kuşses")
        ]
        let decoded = try RootPack(data: Data(RootPack.build(roots: roots))).roots
        for word in ["anaokulu", "anaokulundan", "anaokulumuzda", "anaokulları", "anaokullarımızdan",
                     "ayakucuna", "ayakucumuzda", "ayakuçları", "ayakuçlarında",
                     "buzdolabında", "buzdolabımız", "buzdolapları", "buzdolaplarınızda",
                     "acemborusu", "acemborusundan", "acemborum", "acemboruları", "acemborularımız",
                     "deveboynuna", "deveboynum", "deveboyunları", "deveboyunlarında",
                     "kuşsesim", "kuşsesleri", "anaokulların"] {
            XCTAssertTrue(accepts(word, roots: decoded), word)
        }
        for word in ["anaokul", "anaokuldan", "anaokulular", "anaokullar", "anaokullarda",
                     "ayakuc", "ayakucları", "ayakucular", "ayakucuya",
                     "buzdolab", "buzdolabları", "buzdolabılar", "buzdolabıya",
                     "acemborus", "acemborusum", "acemborusular", "acemborular",
                     "deveboyn", "deveboynları", "deveboyunlar", "deveboynuya", "kuşsem"] {
            XCTAssertFalse(accepts(word, roots: decoded), word)
        }
    }
}
