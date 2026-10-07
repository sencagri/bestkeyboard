import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBMorphology
import KBSpatial
import KBToolSupport

/// Bir ölçümün **ortak kurulumu**: layout, bench sözlüğü, ağırlıklar ve
/// kelime listesi — ve onlardan decoder ile simülatör üreten fabrikalar.
///
/// ## Neden bir değer
///
/// Bunlar `main.swift`'te üst düzey değişkenlerdi ve her kip onlara doğrudan
/// uzanıyordu. Sonuçları: kelime listesi istemeyen kipler (`--lookup`,
/// `--sessions`) bile liste olmadan koşamıyordu, ve decoder aynı argümanlarla
/// sekiz ayrı yerde kuruluyordu — birine yeni bir parametre eklenseydi
/// diğer yedisi sessizce eski motoru ölçerdi. Bağlam bir kez kuruluyor ve
/// kipler onu parametre olarak alıyor.
struct BenchContext {
    let options: Options
    /// Kelime listesi — yalnız isteyen kip için yükleniyor; yoksa boş.
    let words: [(word: String, count: Double)]
    let layout: KeyLayout
    let spatial: SpatialModel
    let weights: ScoreWeights
    let morphology: MorphologyAutomaton?
    /// Bench sözlüğünün kaynakları — kişisel kol bunlara kaynak ekliyor.
    let sources: [LexiconSet.Source]
    let lexicon: LexiconSet

    /// Yol kökü: araç depo kökünden çalıştırılıyor.
    static let repo = FileManager.default.currentDirectoryPath

    static func resolve(_ p: String) -> String {
        p.hasPrefix("/") ? p : repo + "/" + p
    }

    /// - Parameter needsWords: kelime listesi yüklensin mi. Sentetik kök
    ///   istendiyse (`--roots`) liste her hâlde gerekiyor — kökler oradan
    ///   üretiliyor.
    init(_ o: Options, needsWords: Bool) {
        options = o
        if needsWords || o.syntheticRoots > 0 {
            let path = o.wordsPath.map(Self.resolve)
                ?? Self.resolve(PackPaths.wordlist(.turkish))
            words = TSV.wordsByFrequency(at: path, limit: o.limit)
            guard !words.isEmpty else { fail("test kelimesi yok: \(path)") }
        } else {
            words = []
        }

        layout = TurkishQ.layout()
        spatial = SpatialModel(layout: layout)
        var w = ScoreWeights()
        w.maxConsecutiveOmissions = o.maxOmissions
        weights = w

        let trie = PackFile.formTrie(Self.resolve(o.packPath), as: "paket")
        if let rp = o.rootPackPath {
            morphology = MorphologyAutomaton(roots: PackFile.roots(Self.resolve(rp)).roots)
        } else {
            morphology = o.morphology
                ? Self.spikeMorphology(extra: o.syntheticRoots, words: words) : nil
        }
        // --json modunda hiçbir şey basma; çıktı ayrıştırılabilir kalmalı.
        if let m = morphology, !o.json {
            print("morfoloji: \(m.roots.count) kök · başlangıç frontier'ı \(m.startStates().count) durum")
        }
        var s: [LexiconSet.Source] = [.forms(trie, language: Language.turkish)]
        if let m = morphology { s.append(.morphology(m, language: Language.turkish)) }
        if let sl = o.secondLangPath {
            let t2 = PackFile.formTrie(Self.resolve(sl), as: "ikinci dil paketi")
            s.append(.forms(t2, language: Language.english,
                            offset: PackLocale.english.lexiconOffset))
            if !o.json { print("ikinci dil: \(t2.nodeCount) düğüm") }
        }
        sources = s
        lexicon = LexiconSet(sources: s)
    }

    /// Bench decoder'ı — **tek** kurulum. Varsayılanlar bench'in kendisi;
    /// kipler yalnız ölçtükleri parametreyi değiştiriyor.
    ///
    /// - Parameter layout: başka bir geometri (kaydın kendi layout'u); verilir
    ///   ve `spatial` verilmezse o geometrinin kalibrasyonsuz modeli.
    func makeDecoder(layout other: KeyLayout? = nil,
                     spatial m: SpatialModel? = nil,
                     lexicon lex: LexiconSet? = nil,
                     beamWidth: Int? = nil,
                     disableCandidatePruning: Bool = false) -> Decoder {
        let l = other ?? layout
        return Decoder(layout: l,
                       spatial: m ?? other.map { SpatialModel(layout: $0) } ?? spatial,
                       lexicon: lex ?? lexicon, weights: weights,
                       beamWidth: beamWidth ?? options.beamWidth,
                       disableCandidatePruning: disableCandidatePruning)
    }

    /// Ölçüm simülatörü: `--sigma`, ve `withBias` ise `--bias`.
    ///
    /// Simülatör her ölçüm için **tohumundan** kuruluyor: paylaşılan bir
    /// simülatör tüketildiği için ikinci ölçüm başka bir dokunma seti görürdü
    /// ve fark ölçülen parametreye yazılırdı.
    func makeSimulator(seed: UInt64, withBias: Bool = true) -> TouchSimulator {
        var sim = TouchSimulator(layout: layout, seed: seed)
        if withBias {
            sim.biasX = options.biasX
            sim.biasY = options.biasY
        }
        sim.sigmaScale = options.sigma
        return sim
    }

    /// `extra > 0` ise gerçek kelime listesinden sentetik kökler eklenir.
    /// Amaç: başlangıç frontier'ının `O(kök)` olmasının ölçekte ne kadar
    /// maliyetli olduğunu ölçmek (varsayım değil, sayı).
    private static func spikeMorphology(extra: Int,
                                        words: [(word: String, count: Double)])
        -> MorphologyAutomaton {
        var roots = SpikeRoots.all
        if extra > 0 {
            // Kelime listesinden kök gibi davranacak formlar al.
            for (w, c) in words.prefix(extra) where !w.isEmpty && w.count <= 12 {
                roots.append(Root(w, pos: .noun, lexCost: -log(c / 1_000_000)))
            }
        }
        return MorphologyAutomaton(roots: roots)
    }
}
