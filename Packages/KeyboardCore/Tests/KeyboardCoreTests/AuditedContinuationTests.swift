import XCTest
import KBMorphology
import KBAssembly
import KBGeometry

final class AuditedContinuationTests: XCTestCase {
    func testOccupationalDerivationContinuesIntoCopula() {
        let roots = [Root("ütü", pos: .noun, lexCost: 4)]
        for word in ["ütücü", "ütücüymüşüm", "ütücüymüşüz", "ütücülerimizden"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        XCTAssertFalse(accepts("ütüçıymışım", roots: roots))
    }

    func testAllQuestionVowelsWithoutOrdinaryNounCases() {
        let roots = ["mi", "mı", "mu", "mü"].map { Root($0, pos: .noun, lexCost: 4, features: .questionParticle) }
        for word in ["miyim", "mıyım", "muyum", "müyüm", "mıymışsınız", "muymuşsunuz", "müydünüz", "miydiniz", "midir"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["miler", "mıya", "muyumuz", "müde", "miimiş"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }
    func testIrregularEatingAndSayingKeepTheirDifferentConverbVowels() {
        let roots = [Root("ye", pos: .verb, lexCost: 4, features: .narrowBeforeY),
                     Root("de", pos: .verb, lexCost: 4, features: .narrowBeforeYA)]
        for word in ["yiyebileceksiniz", "yiyemeyeceksiniz", "yiyerek", "yiyince", "yiyip", "yiyiniz",
                     "diyeceksiniz", "diyebildiklerimiz", "diyerek", "deyince", "deyip", "deyiniz", "diyelim", "diyeyim"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["yeyebileceksiniz", "yeyip", "diyip", "diyince", "diyiniz", "deyeceksiniz", "yi", "di"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }
    func testLexicalHarmonyAndDoublingSurvivePackRoundTrip() throws {
        let roots = [Root("saat", pos: .noun, lexCost: 4, features: .inverseHarmony),
                     Root("kontrol", pos: .noun, lexCost: 4, features: .inverseHarmony),
                     Root("sır", pos: .noun, lexCost: 4, features: .doublesConsonant),
                     Root("ret", pos: .noun, lexCost: 4, finalAlternation: .tToD, features: .doublesConsonant)]
        let decoded = try RootPack(data: Data(RootPack.build(roots: roots))).roots
        XCTAssertEqual(decoded.map(\.features), roots.map(\.features))
        for word in ["saatlerimiz", "saatim", "kontrolümüzdekiler", "sırrımdakiler", "sırlar", "reddi", "retler"] {
            XCTAssertTrue(accepts(word, roots: decoded), word)
        }
        for word in ["saatlarımız", "saatım", "kontrolumuzdakiler", "sırım", "sırr", "sırrlar", "reti", "red", "redd"] {
            XCTAssertFalse(accepts(word, roots: decoded), word)
        }
    }

    func testWaterLinkingYDoesNotCreateStandaloneStemOrDoubleBuffers() {
        let roots = [Root("su", pos: .noun, lexCost: 4, features: .vowelLinkY)]
        for word in ["su", "suya", "suyu", "suyun", "suyum", "suyumuzdakiler", "suyunuzunki", "suyla", "sular"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["suy", "sum", "sunuz", "susumuz", "suyyu", "suylar"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }

    func testDemonstrativeAndCompoundBoundaries() {
        let roots = [Root("şu", pos: .noun, lexCost: 4, features: .demonstrativeN),
                     Root("bu", pos: .noun, lexCost: 4, features: .demonstrativeN),
                     Root("zeytinyağı", pos: .noun, lexCost: 4, features: .possessiveCompound),
                     Root("yeryüzü", pos: .noun, lexCost: 4, features: .possessiveCompound),
                     Root("başucu", pos: .noun, lexCost: 4, features: .possessiveCompound)]
        for word in ["şunlar", "şunlardakilerden", "şuna", "bunun", "bunda", "budur", "buymuş",
                     "zeytinyağından", "zeytinyağına", "yeryüzündekiler", "yeryüzünün", "başucunuzdakiler", "zeytinyağımızdan"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["şun", "bun", "şular", "bular", "şuya", "buda", "bunum", "zeytinyağıdan", "yeryüzüde"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }
    func testProductionRootsRejectInfinitiveAsVerbStem() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        let morphology = try XCTUnwrap(pack.decoder.lexicon.sources.compactMap(\.morphology).first)
        func accepts(_ word: String) -> Bool {
            var states = Set(morphology.startStates())
            for ch in word {
                states = Set(states.flatMap { morphology.arcs(from: $0).filter { $0.symbol == ch }.map(\.target) })
            }
            return states.contains { morphology.isAccepting($0) }
        }
        for word in ["öğrenmekiyor", "öğretmekiyor", "okumakıyor", "yazmakıyor", "anlamakıyor", "düşünmekiyor",
                     "aktifleşmekiyor", "çalıştırmakıyor", "takipetmekiyor", "testetmekiyor"] {
            XCTAssertFalse(accepts(word), word)
        }
        for word in ["öğreniyor", "öğretiyor", "okuyor", "yazıyor", "anlıyor", "düşünüyor", "öğrenmek", "okumak",
                     "aktifleşiyor", "çalıştırıyoruz", "bilgilendiririz", "faturalandırıyoruz", "kargoluyoruz"] {
            XCTAssertTrue(accepts(word), word)
        }
        for word in ["mutluluğumuzdan", "gerçekliğimizden", "şampiyonluğumuzdan", "beraberliğimizden",
                     "sakatlığımızdan", "doğruluğumuzdan", "bozukluğumuzdan", "eşitliğimizden",
                     "gençliğimizden", "yoksulluğumuzdan", "zenginliğimizden", "yüksekliğimizden",
                     "taşımacılığımızdan", "liderliğimizden", "uygunluğumuzdan", "bağımlılığımızdan",
                     "yaratıcılığımızdan", "bağlılığımızdan", "egemenliğimizden", "ayrımcılığımızdan",
                     "belirsizliğimizden", "işsizliğimizden", "kendiminkilerden", "herkesinkilerden",
                     "sizinkilerden", "birbirimizinki", "saatlerimiz", "kontrolümüzdekiler",
                     "alkolümüz", "gollerinizden", "sırrımdakiler", "zannımızdan", "hakkımızdan", "reddinden",
                     "suyumuzdakiler", "suyunuzunki", "şunlardakilerden", "bunların", "onların",
                     "zeytinyağından", "gökyüzündekiler", "başucunuzdakiler", "hanımelindekilerden",
                     "bugünkülerden", "dünkülerle", "sonrakilerden", "muymuşsunuz", "mıymışsınız",
                     "peroksidimiz", "karbondioksidimiz"] {
            XCTAssertTrue(accepts(word), word)
        }
        for word in ["mutlulukumuzdan", "belirsizlikimizden", "işsizlikimizden", "peroksitimiz", "karbondioksitimiz"] {
            XCTAssertFalse(accepts(word), word)
        }
    }
    private func accepts(_ word: String, roots: [Root]) -> Bool {
        let m = MorphologyAutomaton(roots: roots)
        var states = Set(m.startStates())
        for ch in word {
            states = Set(states.flatMap { m.arcs(from: $0).filter { $0.symbol == ch }.map(\.target) })
        }
        return states.contains { m.isAccepting($0) }
    }

    func testPreviouslyMissingVerbFamiliesAndNearInvalidControls() {
        let roots = [Root("gel", pos: .verb, lexCost: 4, aoristClass: .ir),
                     Root("yap", pos: .verb, lexCost: 4, aoristClass: .ar, causativeClass: .dir),
                     Root("dinle", pos: .verb, lexCost: 4), Root("oku", pos: .verb, lexCost: 4)]
        for word in ["gelseydi", "gelseydiniz", "gelmeseymişsiniz", "geleyim", "gelmeyelim",
                     "gelemeyelim", "dinlemeyiniz", "okumayınız", "gelmeyerek", "gelemeyerek",
                     "gelmeksizin", "gelmedikçe", "gelebildikçe", "gelinceye", "gelmeyinceye",
                     "gelmeyeceğinizden", "gelmemekten", "gelmeyişimizden", "gelmeyebiliriz",
                     "yaptırırsanız", "yapılamıyormuşsunuz", "yapılamazsınız", "gelmezken", "gelemezken"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["gelseymdim", "gelmişimdim", "gelmezim", "gelmeyebilabilirim", "yaptırarlar"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }

    func testNominalInflectionAndBoundedDerivation() {
        let roots = [Root("araba", pos: .noun, lexCost: 4), Root("saniye", pos: .noun, lexCost: 4),
                     Root("anne", pos: .noun, lexCost: 4), Root("öğrenci", pos: .noun, lexCost: 4)]
        for word in ["arabalarımla", "arabalarınızla", "arabalarıylaymış", "saniyelerce",
                     "anneciğim", "anneciğimizden", "öğrenciyim", "öğrenciymişsinizdir"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["arabamlarla", "arabamlayla", "annelilili", "öğrenciimişim"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }

    func testVerbVowelDropOnlyAtPassiveBoundary() {
        let roots = [Root("kavur", pos: .verb, lexCost: 4, dropsVowel: true),
                     Root("soğur", pos: .verb, lexCost: 4, dropsVowel: true)]
        for word in ["kavuruyorsunuz", "kavrulan", "kavrulanlarımızdan", "soğuruyorsunuz"] {
            XCTAssertTrue(accepts(word, roots: roots), word)
        }
        for word in ["kavruyorsunuz", "kavrılan", "kavurulan", "soğruyorsunuz"] {
            XCTAssertFalse(accepts(word, roots: roots), word)
        }
    }
}
