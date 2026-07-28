import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder

// MARK: - kbbench
//
// Sözleşme §9 ve §11.E: telefona dokunmadan algoritma iterasyonu yapabilmenin
// tek yolu. Planda Faz 0 çıktısıydı; performans borcu somutlaşınca yazıldı.
//
// Raporlanan metrikler:
//   - top-1 / top-3 doğruluk
//   - YANLIŞ DÜZELTME oranı: doğru yazılmış kelimenin bozulması. Kullanıcının
//     asıl hissettiği metrik budur ve doğruluktan ayrı raporlanır.
//   - aday uzunluğuna göre hata dağılımı (uzunluk yanlılığı görünür olsun)
//   - tuş başına p50/p95/p99/max gecikme
//
// ÖNEMLİ: doğruluk sayıları **simüle edilmiş** dokunmalardan gelir ve model
// doğrulaması DEĞİLDİR (§9). Gerçek kapı gerçek dokunma verisiyle kurulacak.
// Buradaki değer regresyon tespiti ve parametre taramasıdır.

struct Options {
    var packPath = "LanguagePacks/tr-TR/tr-TR.bkt"
    var wordsPath: String?
    var limit = 2000
    var beamWidth = 128
    var seed: UInt64 = 42
    var morphology = false
    var biasX = 0.0
    var biasY = 0.0
    var sigma = 0.35
    var warmup = 50
    var json = false
    /// Sentetik kök sayısı — başlangıç frontier'ının O(kök) olmasının
    /// gerçekten sorun olup olmadığını ölçmek için.
    var syntheticRoots = 0
    /// Gerçek kök paketi (`.bkr`).
    ///
    /// Sentetik kökler kelime listesinin en sık formlarından üretiliyor; önek
    /// dağılımı, uzunluk dağılımı ve terminal çokluğu gerçek sözlüğü temsil
    /// etmiyor. Ölçek ölçümü sevk edilen veriyle yapılmalı.
    var rootPackPath: String?
    /// İkinci dil paketi — çoklu dilin gecikme ve doğruluk maliyetini ölçmek için.
    var secondLangPath: String?
    var maxOmissions = 4
    /// Aday budamasının yaklaşım payını ölç (§5.4/4).
    var measurePruningGap = false
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--pack":      o.packPath = it.next() ?? o.packPath
        case "--words":     o.wordsPath = it.next()
        case "--limit":     o.limit = Int(it.next() ?? "") ?? o.limit
        case "--beam":      o.beamWidth = Int(it.next() ?? "") ?? o.beamWidth
        case "--seed":      o.seed = UInt64(it.next() ?? "") ?? o.seed
        case "--morphology": o.morphology = true
        case "--bias":
            let parts = (it.next() ?? "").split(separator: ",")
            if parts.count == 2 { o.biasX = Double(parts[0]) ?? 0; o.biasY = Double(parts[1]) ?? 0 }
        case "--sigma":     o.sigma = Double(it.next() ?? "") ?? o.sigma
        case "--json":      o.json = true
        case "--roots":     o.syntheticRoots = Int(it.next() ?? "") ?? 0
        case "--root-pack": o.rootPackPath = it.next(); o.morphology = true
        case "--second-lang": o.secondLangPath = it.next()
        case "--max-om":    o.maxOmissions = Int(it.next() ?? "") ?? 4
        case "--pruning-gap": o.measurePruningGap = true
        case "-h", "--help":
            print("""
            kbbench — decoder değerlendirme ve gecikme ölçümü

              --pack <yol>        dil paketi (varsayılan: LanguagePacks/tr-TR/tr-TR.bkt)
              --words <yol>       test kelimeleri (varsayılan: paketin kaynağı)
              --limit <n>         kaç kelime denensin (varsayılan 2000)
              --beam <n>          beam genişliği (varsayılan 128)
              --seed <n>          PRNG tohumu — tekrarlanabilirlik için
              --sigma <f>         dokunma gürültüsü ölçeği (varsayılan 0.35)
              --bias <x,y>        sistematik parmak sapması, tuş oranında
              --morphology        morfoloji kaynağını da yükle
              --roots <n>         morfolojiye n sentetik kök ekle (ölçek testi)
              --root-pack <yol>   GERÇEK kök paketi (.bkr) yükle; --morphology'yi açar
              --second-lang <yol> ikinci dil form paketi (.bkt) — çoklu dil maliyeti
              --pruning-gap       aday budamasının yaklaşım payını ölç
              --json              makine okunur çıktı (CI kapısı için)

            UYARI: doğruluk sayıları SİMÜLE edilmiş dokunmalardan gelir.
            Gaussian decoder'ı Gaussian gürültüyle test etmek model doğrulaması
            değildir (§9). Bu araç regresyon tespiti içindir.
            """)
            exit(0)
        default: break
        }
    }
    return o
}

// MARK: - Yardımcılar

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[max(0, min(idx, sorted.count - 1))]
}

func loadWords(_ path: String, limit: Int) -> [(String, Double)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [(String, Double)] = []
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        let parts = t.split(separator: "\t")
        guard parts.count == 2, let c = Double(parts[1]) else { continue }
        out.append((String(parts[0]), c))
    }
    // Frekansa göre sırala — en sık kelimeler en çok yazılan kelimelerdir,
    // rastgele örneklem gerçek kullanımı temsil etmez.
    return Array(out.sorted { $0.1 > $1.1 }.prefix(limit))
}

// MARK: - Ana akış

let opt = parseArgs()
let repo = FileManager.default.currentDirectoryPath

func resolve(_ p: String) -> String {
    p.hasPrefix("/") ? p : repo + "/" + p
}

guard let packData = try? Data(contentsOf: URL(fileURLWithPath: resolve(opt.packPath)),
                               options: .mappedIfSafe),
      let trie = try? FormTrie(data: packData) else {
    FileHandle.standardError.write(Data("hata: paket okunamadı: \(opt.packPath)\n".utf8))
    exit(1)
}

let wordsPath = opt.wordsPath.map(resolve)
    ?? resolve("LanguagePacks/tr-TR/wordlist.tsv")
let words = loadWords(wordsPath, limit: opt.limit)
guard !words.isEmpty else {
    FileHandle.standardError.write(Data("hata: test kelimesi yok: \(wordsPath)\n".utf8))
    exit(1)
}

let layout = TurkishQ.layout()
let spatial = SpatialModel(layout: layout)
let morph: MorphologyAutomaton?
if let rp = opt.rootPackPath {
    let path = resolve(rp)
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("hata: kök paketi okunamadı: \(path)\n".utf8))
        exit(1)
    }
    do {
        morph = MorphologyAutomaton(roots: try RootPack(data: data).roots)
    } catch {
        FileHandle.standardError.write(Data("hata: kök paketi geçersiz: \(error)\n".utf8))
        exit(1)
    }
} else {
    morph = opt.morphology ? spikeMorphology(extra: opt.syntheticRoots) : nil
}
// --json modunda hiçbir şey basma; çıktı ayrıştırılabilir kalmalı.
if let m = morph, !opt.json {
    print("morfoloji: \(m.roots.count) kök · başlangıç frontier'ı \(m.startStates().count) durum")
}
var benchSources: [LexiconSet.Source] = [.forms(trie, language: 0)]
if let m = morph { benchSources.append(.morphology(m, language: 0)) }
if let sl = opt.secondLangPath {
    guard let d2 = FileManager.default.contents(atPath: resolve(sl)),
          let t2 = try? FormTrie(data: d2) else {
        FileHandle.standardError.write(Data("hata: ikinci dil paketi okunamadı: \(sl)\n".utf8))
        exit(1)
    }
    benchSources.append(.forms(t2, language: 1, offset: -0.20))
    if !opt.json { print("ikinci dil: \(t2.nodeCount) düğüm") }
}
let lexicon = LexiconSet(sources: benchSources)
var weights = ScoreWeights()
weights.maxConsecutiveOmissions = opt.maxOmissions
let decoder = Decoder(layout: layout, spatial: spatial, lexicon: lexicon,
                      weights: weights, beamWidth: opt.beamWidth)

var sim = TouchSimulator(layout: layout, seed: opt.seed)
sim.biasX = opt.biasX
sim.biasY = opt.biasY
sim.sigmaScale = opt.sigma

// Isınma — ilk çağrılar sayfa hatası ve tembel kurulum içerir.
// AYRI bir PRNG kullanılır: aynı simülatörü tüketmek `--warmup` değişince
// ölçülen dokunma setini de değiştiriyordu, yani karşılaştırmalar bozuluyordu.
var warmSim = TouchSimulator(layout: layout, seed: opt.seed &+ 999)
warmSim.sigmaScale = opt.sigma
for (w, _) in words.prefix(opt.warmup) {
    if let t = warmSim.touches(for: w) { _ = decoder.decode(touches: t, topK: 3) }
}

var top1 = 0, top3 = 0, attempted = 0, skipped = 0
var latencies: [Double] = []
/// **Gerçek** tuş başına gecikme: her `append` ayrı ölçülür.
/// Önceki sürüm kelime süresini dokunma sayısına bölüyordu — bu bir ORTALAMA;
/// pahalı ilk adımı uzun kelimelerde seyreltiyor ve tek bir tuşun kuyruğunu
/// gizliyordu. p99 iddiası bu yüzden yanlıştı.
var appendLatencies: [Double] = []
var resultsLatencies: [Double] = []
/// Temiz yazımda top-1 hatası. **Bu YANLIŞ DÜZELTME DEĞİLDİR** — commit kararı
/// (`Δ > θ`, literal kanalı, kişisel sözlük koruması) burada hiç çalışmıyor.
/// Gerçek yanlış düzeltme ancak commit politikası ölçülerek raporlanabilir.
var cleanAttempts = 0, cleanTop1Errors = 0
/// Uzunluğa göre hata: [uzunluk: (deneme, hata)]
var byLength: [Int: (Int, Int)] = [:]
/// Darboğaz teşhisi: kelime başına üretilen durum ve bunların kaçının
/// omission kapanışından geldiği.
var statesTotal = 0, omissionTotal = 0, subTotal = 0, trTotal = 0, touchTotal = 0

var cleanSim = TouchSimulator(layout: layout, seed: opt.seed &+ 1)
cleanSim.sigmaScale = 0.12          // çok az gürültü: "doğru yazılmış" senaryo
cleanSim.heavyTailRate = 0
cleanSim.omissionRate = 0
cleanSim.insertionRate = 0
cleanSim.transpositionRate = 0

for (word, _) in words {
    guard let touches = sim.touches(for: word) else { skipped += 1; continue }
    attempted += 1

    let t0 = DispatchTime.now().uptimeNanoseconds
    var inc = IncrementalDecoder(decoder: decoder)
    for t in touches {
        let a0 = DispatchTime.now().uptimeNanoseconds
        inc.append(t)
        appendLatencies.append(Double(DispatchTime.now().uptimeNanoseconds - a0) / 1_000_000)
    }
    let r0 = DispatchTime.now().uptimeNanoseconds
    let results = inc.results(topK: 3)
    resultsLatencies.append(Double(DispatchTime.now().uptimeNanoseconds - r0) / 1_000_000)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    statesTotal += inc.statesCreated
    omissionTotal += inc.omissionStates
    subTotal += inc.subStates
    trTotal += inc.transpositionStates
    touchTotal += touches.count
    latencies.append(ms)

    let names = results.map(\.word)
    if names.first == word { top1 += 1 }
    if names.contains(word) { top3 += 1 }

    let len = word.count
    var e = byLength[len] ?? (0, 0)
    e.0 += 1
    if names.first != word { e.1 += 1 }
    byLength[len] = e

    // Yanlış düzeltme ölçümü: neredeyse mükemmel yazımda bile bozuluyor mu?
    if let clean = cleanSim.touches(for: word) {
        cleanAttempts += 1
        if decoder.decode(touches: clean, topK: 1).first?.word != word { cleanTop1Errors += 1 }
    }
}

// §5.4/4: aday budaması bir ARAMA sezgiseli; getirdiği yaklaşım payı
// doğruluktan AYRI raporlanmalı. Oracle kapısında kapatılıyor olması,
// üretimde açıkken ne kaybettirdiğini söylemez.
if opt.measurePruningGap {
    let exact = Decoder(layout: layout, spatial: spatial, lexicon: lexicon,
                        weights: weights, beamWidth: opt.beamWidth,
                        disableCandidatePruning: true)
    var targetLost = 0, top1Changed = 0, compared = 0
    var regretSum = 0.0, regretMax = 0.0
    var gapSim = TouchSimulator(layout: layout, seed: opt.seed)
    gapSim.biasX = opt.biasX; gapSim.biasY = opt.biasY; gapSim.sigmaScale = opt.sigma

    for (word, _) in words {
        guard let t = gapSim.touches(for: word) else { continue }
        let pruned = decoder.decode(touches: t, topK: 3)
        let full = exact.decode(touches: t, topK: 3)
        compared += 1
        if pruned.first?.word != full.first?.word { top1Changed += 1 }
        // Hedef kelime budamasız bulunuyorken budamalıda kayboluyor mu?
        let inFull = full.map(\.word).contains(word)
        let inPruned = pruned.map(\.word).contains(word)
        if inFull && !inPruned { targetLost += 1 }
        // Maliyet pişmanlığı: budamalı top-1 ne kadar daha pahalı?
        if let p = pruned.first, let f = full.first {
            let regret = p.cost - f.cost
            regretSum += max(0, regret)
            regretMax = max(regretMax, regret)
        }
    }
    print("""

    ┌─ aday budaması yaklaşım payı (§5.4/4) ────────────────
    │ karşılaştırılan     : \(compared) kelime
    │ top-1 değişti       : \(top1Changed) (\(String(format: "%.2f%%", Double(top1Changed) / Double(max(compared,1)) * 100)))
    │ hedef KAYBOLDU      : \(targetLost) (\(String(format: "%.2f%%", Double(targetLost) / Double(max(compared,1)) * 100)))
    │ ortalama pişmanlık  : \(String(format: "%.4f", regretSum / Double(max(compared,1)))) nat
    │ en kötü pişmanlık   : \(String(format: "%.4f", regretMax)) nat
    └───────────────────────────────────────────────────────
    """)
}

latencies.sort()
appendLatencies.sort()
resultsLatencies.sort()

let acc1 = Double(top1) / Double(max(attempted, 1)) * 100
let acc3 = Double(top3) / Double(max(attempted, 1)) * 100
let cleanErrRate = Double(cleanTop1Errors) / Double(max(cleanAttempts, 1)) * 100

if opt.json {
    let obj: [String: Any] = [
        "words": attempted, "skipped": skipped,
        "top1": acc1, "top3": acc3,
        // Adı bilinçli: bu commit kararını ölçmüyor (bkz. yorum).
        "cleanTop1ErrorRate": cleanErrRate,
        "falseCorrectionRate": "unavailable — commit politikası ölçülmüyor",
        "latencyMs": ["p50": percentile(latencies, 0.50),
                      "p95": percentile(latencies, 0.95),
                      "p99": percentile(latencies, 0.99),
                      "max": latencies.last ?? 0],
        "appendMs": ["p50": percentile(appendLatencies, 0.50),
                     "p95": percentile(appendLatencies, 0.95),
                     "p99": percentile(appendLatencies, 0.99),
                     "max": appendLatencies.last ?? 0],
        "resultsMs": ["p50": percentile(resultsLatencies, 0.50),
                      "p99": percentile(resultsLatencies, 0.99)],
        "beam": opt.beamWidth, "morphology": opt.morphology, "seed": opt.seed,
        "roots": morph?.roots.count ?? 0,
        "maxOmissions": opt.maxOmissions,
        "statesPerKeystroke": Double(statesTotal) / Double(max(touchTotal, 1)),
        "omissionShare": Double(omissionTotal) / Double(max(statesTotal, 1)),
        "subShare": Double(subTotal) / Double(max(statesTotal, 1)),
        "trShare": Double(trTotal) / Double(max(statesTotal, 1)),
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    print("""

    ┌─ kbbench ─────────────────────────────────────────────
    │ paket      : \(opt.packPath)
    │ kelime     : \(attempted) denendi, \(skipped) atlandı (layout'ta yok)
    │ beam       : \(opt.beamWidth)   morfoloji: \(opt.morphology ? "açık" : "kapalı")
    │ gürültü    : σ=\(opt.sigma)  sapma=(\(opt.biasX), \(opt.biasY))  tohum=\(opt.seed)
    ├─ doğruluk ────────────────────────────────────────────
    │ top-1      : \(String(format: "%.1f%%", acc1))
    │ top-3      : \(String(format: "%.1f%%", acc3))
    │ temiz yazımda top-1 hatası : \(String(format: "%.2f%%", cleanErrRate))
    │   (bu YANLIŞ DÜZELTME DEĞİL — commit kararı ölçülmüyor)
    ├─ gecikme (kelime başına) ─────────────────────────────
    │ p50 \(String(format: "%7.2f", percentile(latencies, 0.50))) ms   \
    p95 \(String(format: "%7.2f", percentile(latencies, 0.95))) ms
    │ p99 \(String(format: "%7.2f", percentile(latencies, 0.99))) ms   \
    max \(String(format: "%7.2f", latencies.last ?? 0)) ms
    ├─ iş miktarı (darboğaz teşhisi) ───────────────────────
    │ tuş başına üretilen durum : \(String(format: "%.0f", Double(statesTotal) / Double(max(touchTotal, 1))))
    │ bunların omission payı    : \(String(format: "%.1f%%", Double(omissionTotal) / Double(max(statesTotal, 1)) * 100))
    ├─ gecikme (TUŞ başına, GERÇEK append — bütçe p99 < 8 ms) ─
    │ p50 \(String(format: "%7.3f", percentile(appendLatencies, 0.50))) ms   \
    p95 \(String(format: "%7.3f", percentile(appendLatencies, 0.95))) ms
    │ p99 \(String(format: "%7.3f", percentile(appendLatencies, 0.99))) ms   \
    max \(String(format: "%7.3f", appendLatencies.last ?? 0)) ms
    │ öneri okuma p99: \(String(format: "%.3f", percentile(resultsLatencies, 0.99))) ms
    └───────────────────────────────────────────────────────
    """)

    print("\n uzunluğa göre top-1 hata oranı (uzunluk yanlılığı görünür olsun):")
    for len in byLength.keys.sorted() {
        let (n, err) = byLength[len]!
        guard n >= 5 else { continue }
        let rate = Double(err) / Double(n) * 100
        let bar = String(repeating: "█", count: Int(rate / 3))
        print(String(format: "   %2d harf  %4d kelime  %5.1f%%  %@", len, n, rate, bar))
    }

    print("""

     UYARI: doğruluk sayıları SİMÜLE edilmiş dokunmalardan geliyor. Gaussian bir
     decoder'ı Gaussian gürültüyle sınamak model doğrulaması değildir (§9).
     Bu araç regresyon tespiti ve parametre taraması içindir; gerçek doğruluk
     kapısı gerçek dokunma verisiyle kurulacak.
    """)
}

// MARK: - Morfoloji fixture'ı

/// `extra > 0` ise gerçek kelime listesinden sentetik kökler eklenir.
/// Amaç: başlangıç frontier'ının `O(kök)` olmasının ölçekte ne kadar
/// maliyetli olduğunu ölçmek (varsayım değil, sayı).
func spikeMorphology(extra: Int = 0) -> MorphologyAutomaton {
    var roots: [Root] = [
        Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
        Root("kalem", pos: .noun, lexCost: 4.2),
        Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
        Root("renk",  pos: .noun, lexCost: 5.2, finalAlternation: .kToG),
        Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
        Root("masa",  pos: .noun, lexCost: 4.7),
        Root("ev",    pos: .noun, lexCost: 4.1),
        Root("gel",   pos: .verb, lexCost: 4.0),
    ]
    if extra > 0 {
        // Kelime listesinden kök gibi davranacak formlar al.
        for (w, c) in words.prefix(extra) where !w.isEmpty && w.count <= 12 {
            roots.append(Root(w, pos: .noun, lexCost: -log(c / 1_000_000)))
        }
    }
    return MorphologyAutomaton(roots: roots)
}
