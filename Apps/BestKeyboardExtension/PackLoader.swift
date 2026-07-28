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

        // Karakter modeli **dil başına**. İkincisini üretip yüklememek,
        // İngilizce sözlük dışı kelimelerin Türkçe modelle puanlanması
        // demekti — Türkçeye göre implausible görünüp düzeltilirlerdi.
        var charModels: [CharNGram] = []
        for name in ["tr-TR", "en-US"] {
            guard let u = bundle.url(forResource: name, withExtension: "bkc"),
                  let d = try? Data(contentsOf: u, options: .mappedIfSafe),
                  let m = try? CharNGram(packData: d) else { continue }
            charModels.append(m)
        }

        // Gayrıresmî katman (§4.B) **ayrı bir kaynak değil**: `packbuild
        // --informal` onu form listesiyle birleştirip tek trie üretiyor.
        //
        // Ayrı kaynak olarak yüklemek §7'yi ihlal ediyordu: aynı yüzey iki
        // trie'de bulunduğunda decoder ucuz olanı seçiyor, oysa listeler farklı
        // toplamlara göre normalize edilmiş ve maliyetleri karşılaştırılamaz.
        // Ayrı DOSYA olarak durması yazım kolaylığı ve lisans ayrımı içindir.

        var expansions: ExpansionMap?
        if let u = bundle.url(forResource: "tr-TR", withExtension: "bkx"),
           let d = try? Data(contentsOf: u, options: .mappedIfSafe) {
            expansions = try? ExpansionMap(packData: d)
        }

        // **Genişletmeler kısaltmaların bilinmesine bağlıdır.**
        //
        // `slm`'nin otomatik açılmamasının tek güvencesi onun sözlükte olması
        // (`θ = ∞`). Kısaltmalar form paketinde birleşik geliyor; bir anahtar
        // sözlükte değilse ona açılım önermek tutarsız olurdu — üstelik o
        // token korumasız demektir ve decoder onu başka bir yüzeye çevirebilir.
        //
        // O yüzden açılımlar **doğrulanır**: anahtarı sözlükte olmayan girdiler
        // atılır. Böylece iki paket birbirinden bağımsız yüklense de tutarsız
        // bir durum oluşamaz.
        var informalKnown = 0
        if let m = expansions {
            let verified = m.entries.filter { trie.lookup($0.0) != nil }
            informalKnown = verified.count
            expansions = verified.isEmpty ? nil : ExpansionMap(entries: verified)
        }

        var sources: [LexiconSet.Source] = [.forms(trie, language: Language.turkish)]
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
        let lit = charModels.isEmpty ? " · literal yedek" : ""
        let inf = informalKnown > 0 ? " · argo \(informalKnown)" : ""
        let report = String(format: "%d düğüm · %@%@%@%@ · %.0f ms",
                            trie.nodeCount, roots, langs, lit, inf, ms)
        return Loaded(decoder: decoder, trie: trie,
                      literalChannel: LiteralChannel(vocabulary: lexicon,
                                                     charModels: charModels),
                      expansions: expansions,
                      report: report)
    }
}
