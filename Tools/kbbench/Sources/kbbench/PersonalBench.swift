import Foundation
import KBAssembly
import KBDecoder
import KBLearning
import KBRuntime
import KBSpatial
import KBToolSupport

/// Kişisel sözlük (§8.7)
///
/// İki soru, ikisi de kapı:
///
///  1. **Tanınma.** Kabul edilen kelime gerçekten geri geliyor mu? Sözlüğe
///     koymak tek başına "bulunuyor" demek değil: kişisel yüzey paketin en
///     pahalı ucuna çıpalanıyor ve 128 genişliğindeki beam'de erken budanabilir
///     ya da ucuz bir paket kelimesine yenilebilir.
///
///  2. **Mıknatıs.** Kişisel kelimeler paketteki kelimelerin kod çözümünü
///     çalıyor mu? Özelliğin taşıdığı asıl risk bu: kullanıcının kendi
///     kelimesini korumak için günlük yazımını bozmak kabul edilemez.
///
/// İkisi **aynı parametrenin** iki yönü — kişisel `F_lex` çıpası. Ucuzlattıkça
/// tanınma artar, mıknatıs riski büyür. O yüzden tek bir sayı savunulmuyor,
/// eğri taranıyor (§8.5'in ağırlık taramasıyla aynı yöntem).
///
/// **Popülasyon bir vekildir.** Kişisel yüzeyler İngilizce listeden alınıyor
/// (tr paketinde ve morfolojisinde bulunmayanlar) — gerçek kullanıcının kendi
/// kelimeleri değil, ama gerçek harf dizileri ve tr sözlüğüne yabancı. Yanına
/// elle yazılmış bir avuç gerçek vaka (kullanıcı adı, lakap) konuyor. Kısa
/// İngilizce kelimeler Türkçe kelimelerle bol bol çakıştığı için bu popülasyon
/// mıknatıs ölçümünde **kötümser**, tanınma ölçümünde de öyle. Ölçüm
/// mekanizmanın çalıştığını gösterir; kullanıcı popülasyonunda kazanç
/// iddiasında DEĞİLDİR.
enum PersonalBench {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        let words = ctx.words
        let layout = ctx.layout
        let lexicon = ctx.lexicon
        print("\n=== kişisel sözlük (§8.7) ===")

        // Gerçek vakalar: kullanıcı adı, lakap, türetilemeyen soyad.
        let handwritten = ["sencagri", "zeynepcim", "kardo", "reyiz", "caginho",
                           "bayraktaroğlu", "akgündüz", "çelikkol", "ertuğrulgazi",
                           "demirkanlı"]

        // Yabancı yüzeyler: en-US listesinden, tr paketinde **ve morfolojisinde**
        // bulunmayanlar. Morfolojiyi atlamak `özdemirler` gibi türetilebilir
        // yüzeyleri "kişisel" sayardı ve §7 tek sahipliğini kırardı.
        let enPath = opt.secondLangPath.map(BenchContext.resolve)
            ?? BenchContext.resolve(PackPaths.wordlist(.english))
        let enWords = TSV.wordsByFrequency(at: enPath, limit: 20_000).map(\.word)

        var personalWords: [String] = []
        var queried = 0
        let filterStart = Stopwatch()
        for w in handwritten {
            queried += 1
            if !lexicon.containsSurface(w) { personalWords.append(w) }
        }
        let handwrittenKept = personalWords.count
        for w in enWords {
            if personalWords.count >= opt.personalCount + handwrittenKept { break }
            guard PersonalLexicon.canonical(w) == w else { continue }
            queried += 1
            guard !lexicon.containsSurface(w) else { continue }
            personalWords.append(w)
        }
        let filterMs = filterStart.elapsedMs

        guard personalWords.count > handwrittenKept else {
            print("  ölçülecek yüzey yok — hepsi zaten pakette")
            return 0
        }

        // Dokunma dizileri **bir kez** üretiliyor: her çıpa aynı dokunmalarla
        // ölçülsün, fark yalnız maliyetten gelsin.
        func touchSet(sigma: Double, seed: UInt64, words: [String])
            -> [(String, [TouchSample])] {
            var s = TouchSimulator(layout: layout, seed: seed)
            s.sigmaScale = sigma
            if sigma <= 0.15 {
                s.makeClean()
            } else {
                s.biasX = opt.biasX; s.biasY = opt.biasY
            }
            return words.compactMap { w in s.touches(for: w).map { (w, $0) } }
        }

        let carefulSet = touchSet(sigma: 0.12, seed: opt.seed &+ 7, words: personalWords)
        let dailySet = touchSet(sigma: opt.sigma, seed: opt.seed &+ 7, words: personalWords)
        let packSet = touchSet(sigma: opt.sigma, seed: opt.seed, words: words.map(\.0))

        // Paket kolunun **referansı**: kişisel kaynak yokken hangi kelimeler doğru.
        // Mıknatıs zararı buna göre ölçülüyor.
        let decoder = ctx.makeDecoder()
        var packBaseline: [String: Bool] = [:]
        for (w, t) in packSet {
            packBaseline[w] = decoder.decode(touches: t, topK: 1).first?.word == w
        }
        let baselineCorrect = packBaseline.values.filter { $0 }.count

        print("""
          yüzey       : \(personalWords.count) (elle \(handwrittenKept) + en-US \(personalWords.count - handwrittenKept))
          OOV süzgeci : \(String(format: "%.1f", filterMs)) ms · \(queried) yüzey sorgulandı
          paket kolu  : \(packSet.count) kelime · kişisel kaynak yokken top1 \
        \(String(format: "%.2f%%", 100 * Double(baselineCorrect) / Double(max(packSet.count, 1))))
        """)

        struct Arm {
            let cost: Double
            let careful: Int
            let daily: Int
            let packTop1: Int
            let stolen: Int
            let examples: [String]
            let buildMs: Double
        }

        func measure(cost: Double) -> Arm? {
            let t0 = Stopwatch()
            guard let src = PersonalLexiconSource.make(words: personalWords,
                                                       base: lexicon, lexCost: cost)
            else { return nil }
            let buildMs = t0.elapsedMs
            let d = ctx.makeDecoder(lexicon: LexiconSet(sources: ctx.sources + [src]))

            func hits(_ set: [(String, [TouchSample])]) -> Int {
                set.reduce(0) { $0 + (d.decode(touches: $1.1, topK: 1).first?.word == $1.0 ? 1 : 0) }
            }
            var packTop1 = 0, stolen = 0
            var examples: [String] = []
            for (w, t) in packSet {
                let got = d.decode(touches: t, topK: 1).first?.word
                if got == w { packTop1 += 1 }
                // **Çalınan**: kişisel kaynak yokken doğru olan cevabı bozdu.
                if packBaseline[w] == true, got != w {
                    stolen += 1
                    if examples.count < 5, let got { examples.append("\(w)→\(got)") }
                }
            }
            return Arm(cost: cost, careful: hits(carefulSet), daily: hits(dailySet),
                       packTop1: packTop1, stolen: stolen, examples: examples,
                       buildMs: buildMs)
        }

        // Tarama: paketin en pahalı yüzeyinden (14.57) medyanına (12.91) ve altına.
        // Alt uç bilerek agresif — zararın nerede başladığını görmeden "zarar yok"
        // demek, ölçülmemiş bir aralığı ölçülmüş gibi göstermek olurdu.
        let sweep: [Double] = [14.6, 13.8, 12.9, 11.5, 10.0, 9.0, 8.0, 6.0]
        print("\n  çıpa taraması (aynı dokunmalar, tek değişken kişisel F_lex):")
        print("    F_lex   tanınma-dikkatli  tanınma-günlük   paket top1     çalınan")
        var arms: [Arm] = []
        for c in sweep {
            guard let a = measure(cost: c) else { continue }
            arms.append(a)
            let n = Double(max(personalWords.count, 1))
            let p = Double(max(packSet.count, 1))
            print(String(format: "    %5.1f   %4d (%5.1f%%)     %4d (%5.1f%%)   %6.2f%% (%+.2f)   %4d",
                         a.cost, a.careful, 100 * Double(a.careful) / n,
                         a.daily, 100 * Double(a.daily) / n,
                         100 * Double(a.packTop1) / p,
                         100 * Double(a.packTop1 - baselineCorrect) / p,
                         a.stolen))
        }
        if let worst = arms.max(by: { $0.stolen < $1.stolen }), !worst.examples.isEmpty {
            print("    en çok çalan kol (F_lex \(worst.cost)): " + worst.examples.joined(separator: ", "))
        }

        // Üretim çıpası ayrıca **koruma** tarafından da sınanıyor: kabul edilen
        // yüzey `V`'ye girdiği için `θ = ∞` olmalı. Tanım gereği doğru ama kanalın
        // sözlüğü decoder'ınkiyle aynı nesne olmazsa sessizce bozulur.
        if let src = PersonalLexiconSource.make(words: personalWords, base: lexicon) {
            let lex = LexiconSet(sources: ctx.sources + [src])
            var channel = LiteralChannel(vocabulary: lex, charModels: [])
            channel.autoCorrectsOutOfVocabulary = true
            let unprotected = personalWords.filter { !channel.score($0).demandsProtection }
            print("\n  koruma (üretim çıpası \(PersonalLexicon.lexCost)): "
                  + "\(personalWords.count - unprotected.count)/\(personalWords.count) yüzey θ = ∞"
                  + (unprotected.isEmpty ? "" : " · KORUMASIZ: \(unprotected.prefix(5).joined(separator: ", "))"))
            print("    trie \(src.formTrie?.nodeCount ?? 0) düğüm · kurulum "
                  + String(format: "%.1f ms", arms.first?.buildMs ?? 0))

            // **Kabul anının tam bedeli.** Klavye bunu token sınırında, ana
            // thread'de ödüyor: kaynak kurulumu + leksikon + decoder. Yalnız trie
            // kurulumunu raporlamak, `LexiconSet`'in birleşik alfabeyi bütün
            // morfoloji kökleri üzerinden kurmasını gizlerdi.
            let applyStart = Stopwatch()
            let rebuilt = LexiconSet(sources: ctx.sources + [src])
            _ = ctx.makeDecoder(lexicon: rebuilt)
            let applyMs = applyStart.elapsedMs
            print(String(format: "    kabul anında motorun yeniden kurulumu: %.1f ms", applyMs))
        }
        return 0
    }
}
