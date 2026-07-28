import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder

/// Dil paketlerini yükler ve decoder'ı kurar.
///
/// Uzantı ve uygulama içi tezgah **aynı** yolu kullanır; ikisi ayrışırsa
/// tezgahta çalışan bir şeyin uzantıda çalışmadığı durumlar doğar.
///
/// İki paket:
///   `tr-TR.bkt` — form listesi (70k yüzey formu)
///   `tr-TR.bkr` — kök sözlüğü (morfoloji); **opsiyonel**, yoksa yalnız
///                 form listesiyle çalışılır
///   `tr-TR.bkc` — literal kanalının karakter n-gram modeli; **opsiyonel**,
///                 yoksa `cost(literal)` sabit bir yedeğe düşer ve
///                 `literalChannel.isCalibrated` bunu bildirir
///
/// Morfoloji, form listesinin prensip olarak kapatamayacağı kuyruğu kapatır:
/// `kalemlerimizden` hiçbir korpusta geçmiyor ama kökten türetilebiliyor.
enum PackLoader {

    struct Loaded {
        let decoder: Decoder
        let trie: FormTrie
        let literalChannel: LiteralChannel
        let report: String
    }

    static func load(layout: KeyLayout, bundle: Bundle, beamWidth: Int = 128) throws -> Loaded {
        let t0 = CFAbsoluteTimeGetCurrent()

        guard let trieURL = bundle.url(forResource: "tr-TR", withExtension: "bkt") else {
            throw NSError(domain: "pack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "tr-TR.bkt bundle'da yok"])
        }
        // mmap — paket ayrıştırılmaz, eşlenir ve sahiplenilir (§11.A/D).
        let trie = try FormTrie(data: try Data(contentsOf: trieURL, options: .mappedIfSafe))

        var morphology: MorphologyAutomaton?
        var rootCount = 0
        if let rootURL = bundle.url(forResource: "tr-TR", withExtension: "bkr"),
           let rootData = try? Data(contentsOf: rootURL, options: .mappedIfSafe),
           let pack = try? RootPack(data: rootData) {
            morphology = MorphologyAutomaton(roots: pack.roots)
            rootCount = pack.roots.count
        }

        var charModel: CharNGram?
        if let cURL = bundle.url(forResource: "tr-TR", withExtension: "bkc"),
           let cData = try? Data(contentsOf: cURL, options: .mappedIfSafe) {
            charModel = try? CharNGram(packData: cData)
        }

        let lexicon = LexiconSet(formTrie: trie, morphology: morphology)
        let decoder = Decoder(layout: layout,
                              spatial: SpatialModel(layout: layout),
                              lexicon: lexicon,
                              beamWidth: beamWidth)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let roots = rootCount > 0 ? "\(rootCount) kök" : "morfoloji yok"
        // Literal kanalının kalibre olup olmadığı raporda: commit kararının
        // ne kadar güvenilir olduğunu belirleyen tek şey bu.
        let lit = charModel == nil ? " · literal yedek" : ""
        let report = String(format: "%d düğüm · %@%@ · %.0f ms",
                            trie.nodeCount, roots, lit, ms)
        return Loaded(decoder: decoder, trie: trie,
                      literalChannel: LiteralChannel(vocabulary: lexicon, charModel: charModel),
                      report: report)
    }
}
