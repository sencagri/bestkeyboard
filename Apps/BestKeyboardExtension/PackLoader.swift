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
/// Diller **aynı beam'de** yaşar, layout değişmez (§5b): Türkçe Q,
/// İngilizce QWERTY'nin harf kümesini zaten kapsıyor.
///
/// Paketler:
///   `tr-TR.bkt` — form listesi (70k yüzey formu)
///   `tr-TR.bkr` — kök sözlüğü (morfoloji); **opsiyonel**, yoksa yalnız
///                 form listesiyle çalışılır
///   `tr-TR.bkc` — literal kanalının karakter n-gram modeli; **opsiyonel**,
///                 yoksa `cost(literal)` sabit bir yedeğe düşer ve
///                 `literalChannel.isCalibrated` bunu bildirir
///   `en-US.bkt` — ikinci dil; **opsiyonel**
///
/// Morfoloji, form listesinin prensip olarak kapatamayacağı kuyruğu kapatır:
/// `kalemlerimizden` hiçbir korpusta geçmiyor ama kökten türetilebiliyor.
/// Dil kimlikleri. `UInt8` çünkü decoder durumunda tek bayt yer kaplıyor;
/// aynı anda en fazla 2 dil aktif olacağı için (plan kararı) fazlası gereksiz.
enum Language {
    static let turkish: UInt8 = 0
    static let english: UInt8 = 1
}

enum PackLoader {

    struct Loaded {
        let decoder: Decoder
        let trie: FormTrie
        let literalChannel: LiteralChannel
        let expansions: ExpansionMap?
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

        // İkinci dil — opsiyonel. Yoksa tek dille çalışılır ve kod yolu aynıdır
        // (§5b: "Faz 1'den itibaren aynı kod yolu, tek dilde bile").
        var english: FormTrie?
        if let enURL = bundle.url(forResource: "en-US", withExtension: "bkt"),
           let enData = try? Data(contentsOf: enURL, options: .mappedIfSafe) {
            english = try? FormTrie(data: enData)
        }

        var charModel: CharNGram?
        if let cURL = bundle.url(forResource: "tr-TR", withExtension: "bkc"),
           let cData = try? Data(contentsOf: cURL, options: .mappedIfSafe) {
            charModel = try? CharNGram(packData: cData)
        }

        // Gayrıresmî katman (§4.B): ayrı kaynak, aynı dil.
        //
        // Ayrı olmasının sebebi lisans değil mimari: bu formların frekansı
        // resmî korpustan gelmiyor (elle küratörlü) ve ayrı bir dosyada
        // durması dil paketini bozmadan güncellenebilmelerini sağlıyor.
        var informal: FormTrie?
        if let u = bundle.url(forResource: "tr-TR-informal", withExtension: "bkt"),
           let d = try? Data(contentsOf: u, options: .mappedIfSafe) {
            informal = try? FormTrie(data: d)
        }

        var expansions: ExpansionMap?
        if let u = bundle.url(forResource: "tr-TR", withExtension: "bkx"),
           let d = try? Data(contentsOf: u, options: .mappedIfSafe) {
            expansions = try? ExpansionMap(packData: d)
        }

        var sources: [LexiconSet.Source] = [.forms(trie, language: Language.turkish)]
        if let inf = informal {
            sources.append(.forms(inf, language: Language.turkish))
        }
        if let m = morphology {
            sources.append(.morphology(m, language: Language.turkish))
        }
        if let en = english {
            // `offset` ölçümle geldi (`kbdiag --scale`): iki listede ortak 12 108
            // yüzeyde maliyet farkının medyanı +0.20 nat, çeyrekler arası
            // genişlik 1.39 nat. Yani paketler zaten uyumlu ölçekte —
            // sıfır bırakmak yerine ölçülen değeri koyuyoruz, ama büyüklüğü
            // gürültü mertebesinde olduğu için tek başına bir şeyi çevirmez.
            sources.append(.forms(en, language: Language.english, offset: -0.20))
        }
        let lexicon = LexiconSet(sources: sources)
        let decoder = Decoder(layout: layout,
                              spatial: SpatialModel(layout: layout),
                              lexicon: lexicon,
                              beamWidth: beamWidth)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let roots = rootCount > 0 ? "\(rootCount) kök" : "morfoloji yok"
        let langs = english != nil ? " · tr+en" : " · tr"
        // Literal kanalının kalibre olup olmadığı raporda: commit kararının
        // ne kadar güvenilir olduğunu belirleyen tek şey bu.
        let lit = charModel == nil ? " · literal yedek" : ""
        let inf = informal != nil ? " · argo" : ""
        let report = String(format: "%d düğüm · %@%@%@%@ · %.0f ms",
                            trie.nodeCount, roots, langs, lit, inf, ms)
        return Loaded(decoder: decoder, trie: trie,
                      literalChannel: LiteralChannel(vocabulary: lexicon, charModel: charModel),
                      expansions: expansions,
                      report: report)
    }
}
