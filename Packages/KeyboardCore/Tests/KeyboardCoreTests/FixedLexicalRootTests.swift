import XCTest
import KBMorphology
import KBAssembly
import KBGeometry

final class FixedLexicalRootTests: XCTestCase {
    func testFixedRootsRoundTripWithoutInventingNominalInflections() throws {
        let roots = [Root("ayol", pos: .fixed, lexCost: 4),
                     Root("mademki", pos: .fixed, lexCost: 5),
                     Root("hamdolsun", pos: .fixed, lexCost: 6),
                     Root("şırıl", pos: .fixed, lexCost: 6), Root("gümbür", pos: .fixed, lexCost: 6)]
        let decoded = try RootPack(data: Data(RootPack.build(roots: roots))).roots
        XCTAssertTrue(decoded.allSatisfy { $0.pos == .fixed })
        let morphology = MorphologyAutomaton(roots: decoded)
        func accepts(_ word: String) -> Bool {
            var states = Set(morphology.startStates())
            for letter in word {
                states = Set(states.flatMap { morphology.arcs(from: $0)
                    .filter { $0.symbol == letter }.map(\.target) })
            }
            return states.contains { morphology.isAccepting($0) }
        }
        for word in ["ayol", "mademki", "hamdolsun", "şırıl", "gümbür"] { XCTAssertTrue(accepts(word), word) }
        for word in ["ayollar", "ayolum", "ayoldan", "mademkiler", "mademkiyim",
                     "hamdolsunlar", "hamdolsunum", "hamdolsundan", "şırıllar", "şırıldan", "gümbürüm", "gümbürde"] {
            XCTAssertFalse(accepts(word), word)
        }
    }

    func testProductionConversationParticlesAreRecognized() throws {
        let pack = try PackLoader.load(layout: TurkishQ.layout(), source: RecordingTestSupport.packSource)
        for word in ["ayol", "mademki", "hamdolsun", "maazallah", "heyhat", "velev", "keşki",
                     "haydisene", "selamünaleyküm", "aleykümselam", "aleykümselâm", "mamafih",
                     "binaen", "mahsuben", "müteakiben", "iştiraken", "izafeten", "hürmeten", "ilaveten", "ilâveten", "üzre", "şırıl", "gümbür", "fokur", "kıkır", "horul", "mırıl", "şakır", "çatır", "şapır", "gürül",
                     "fısıl", "fıkır", "pıtır", "şıkır", "tıpış", "şıpır", "patır", "takır",
                     "püfür", "zangır", "cıyak", "homur",
                     "bıcır", "börtü", "cümbür", "cazır", "cızır", "fıldır",
                     "kütür", "lıkır", "mırın", "parıl", "tiril", "zonk",
                     "şarıl", "tıpır", "ılgıt", "ifil", "fırıl", "çıngır",
                     "şangır", "şungur", "langır", "lungur", "höpür", "gacır", "gucur",
                     "fosur", "pofur", "hapır", "hupur", "löpür", "tangır",
                     "tungur", "uğul", "şıngır", "zıngır", "şupur", "hışıl",
                     "bıngıl", "cumbul", "fingir", "fışır", "hırıl", "ipil",
                     "pır", "şıldır", "vızır", "vızıl", "zırıl", "mıncık",
                     "apul", "ceste", "kıdım", "pırtık", "sapır", "tapır",
                     "tukur", "gıldır", "fısır", "şalap", "yalap", "zıngıl",
                     "zart", "zurt", "zırt", "vır", "vırt", "çer", "çör",
                     "fış", "cır", "mır", "mık", "vık",
                     "anha", "minha", "bici", "cambul", "ciyak", "cungul", "fiso",
                     "fıkı", "gulu", "okus", "pokus", "ıkına", "yapıldak"] {
            XCTAssertTrue(pack.literalChannel.score(word).isInVocabulary, word)
        }
    }
}
