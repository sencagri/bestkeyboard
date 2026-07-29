import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBLearning

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
    /// Kalibrasyon deneyi: sapmalı kullanıcıda öğrenmenin faydası ve zararı.
    var calibrationExperiment = false
    /// Kalibrasyon deneyinde profil başına bağımsız çekiliş sayısı.
    var calibrationRepeats = 4
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
        case "--calibration": o.calibrationExperiment = true
        case "--calibration-repeats":
            o.calibrationRepeats = max(1, Int(it.next() ?? "") ?? o.calibrationRepeats)
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
              --calibration       kalibrasyon deneyi (fayda + ZARAR metrikleri)
              --calibration-repeats <n>  profil başına çekiliş (varsayılan 4)
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

// MARK: - Kalibrasyon: SENTETİK MEKANİZMA TESTİ
//
// **Bu bir doğruluk kapısı DEĞİLDİR.** Öğrenme ve değerlendirme aynı
// simülatörden, aynı gürültü ailesinden ve aynı sabit-global-bias modelinden
// geliyor — plan §9'un açıkça *"model doğrulaması değil, kendini doğrulama"*
// dediği durum bu. Buradan çıkan tek meşru sonuç: **mekanizma çalışıyor mu**
// (sapmayı görüyor mu, yanlış yöne gitmiyor mu, kimseye zarar veriyor mu).
//
// Gerçek kabul kapısı bağımsız dokunma replay'leri ve kullanıcı bazlı ayrık
// train/test ile kurulacak (§9).
//
// Plan §9 metrik 6 fayda kadar ZARAR ister: p10 kullanıcı, en kötü tuş kayması,
// zamanla değişen sapma, profil transferi.
if opt.calibrationExperiment {
    print("\n=== kalibrasyon: SENTETİK MEKANİZMA TESTİ ===")
    print("  UYARI: doğruluk kapısı DEĞİL — öğrenme ve test aynı simülatörden.")
    print("  Meşru sonuç yalnız: mekanizma çalışıyor mu, zarar veriyor mu.\n")

    // Test kümesi **her koşuda aynı** ve eğitimden ayrık. Eğitim boyutu
    // taranacağı için `dropFirst(eğitim)` kullanılamaz: test kümesi eğitimle
    // birlikte kayardı ve boyutlar arası karşılaştırma anlamsız olurdu.
    // Listenin sonundan alınıyor; eğitim baştan büyüdüğü için çakışma yok.
    let testWords = Array(words.suffix(400))
    /// Eğitim kümesinin üst sınırı — test kümesine taşmamalı.
    let maxTrain = max(0, words.count - testWords.count)
    if maxTrain < 1200 {
        print("  NOT: --limit \(opt.limit) küçük; eğitim taraması \(maxTrain) kelimede kesiliyor.")
    }

    /// Sentetik bir kullanıcının sapma profili — üç katmanlı.
    ///
    /// Faz 1 ölçümünde yalnız `gx/gy` vardı. Hiyerarşik modeli o profille
    /// ölçmek onu yapısal olarak kazanamayacağı bir sınava sokmak olurdu:
    /// öğrenecek satır ya da tuş etkisi yokken fazladan iki katman ancak
    /// gürültü ekler. Bu yüzden **iki yön de** ölçülüyor — yapı varken kazanç,
    /// yapı yokken zarar.
    struct Profile {
        var gx = 0.0, gy = 0.0
        var rowScale = 0.0      // satır sapmalarının std'si (tuş ölçüsü oranında)
        var keyScale = 0.0      // tuş sapmalarının std'si
        var drift = 0.0
        /// Tuş sapmalarının uzamsal **korelasyon uzunluğu**, tuş genişliği
        /// biriminde. `0` = IID.
        ///
        /// IID çekiliş gerçekçi bir kullanıcı değil: gerçek parmak sapması el
        /// geometrisinden doğar, dolayısıyla komşu tuşlar **benzer** sapar.
        /// Komşu farkının varyansı `2σ²(1−ρ)` olduğuna göre `ρ = 0` (IID)
        /// düzgün alandan sert, ama matematiksel en kötü de değil
        /// (anti-korelasyon daha kötü). Bu yüzden IID artık "gerçekçi senaryo"
        /// değil, ayrı bir **stres satırı** olarak duruyor.
        var correlationLength = 0.0
    }

    /// Profilden simülatörün katman dizilerini üretir.
    /// Aynı kullanıcı için eğitim ve değerlendirmede **aynı** diziler kullanılır
    /// (aynı el, aynı alışkanlık); değişen yalnız gürültü tohumu.
    func layers(_ p: Profile, seed: UInt64)
        -> (rx: [Double], ry: [Double], kx: [Double], ky: [Double]) {
        var g = SplitMix64(seed: seed)
        let rx = (0..<layout.rowCount).map { _ in g.nextGaussian() * p.rowScale }
        let ry = (0..<layout.rowCount).map { _ in g.nextGaussian() * p.rowScale }

        /// Tuş sapması alanı. `correlationLength == 0` ise bağımsız; değilse
        /// bağımsız çekilişler tuş merkezleri arası uzaklığa göre Gaussian
        /// çekirdekle yumuşatılıyor — el geometrisinden doğan düzgün bir alanın
        /// ucuz ve deterministik karşılığı.
        func field() -> [Double] {
            let raw = (0..<layout.keys.count).map { _ in g.nextGaussian() }
            guard p.correlationLength > 0 else { return raw.map { $0 * p.keyScale } }
            let w = layout.keys.map(\.width).min() ?? 1
            let l = p.correlationLength * w
            var out = [Double](repeating: 0, count: raw.count)
            for i in layout.keys.indices {
                var acc = 0.0, norm = 0.0
                for j in layout.keys.indices {
                    let dx = layout.keys[i].center.x - layout.keys[j].center.x
                    let dy = layout.keys[i].center.y - layout.keys[j].center.y
                    let wgt = exp(-(dx * dx + dy * dy) / (2 * l * l))
                    acc += wgt * raw[j]; norm += wgt * wgt
                }
                // `norm`'un karekökü ile bölmek marjinal varyansı `1`de tutuyor,
                // yani `keyScale` korelasyondan bağımsız olarak aynı şeyi ifade
                // ediyor ve senaryolar karşılaştırılabilir kalıyor.
                out[i] = norm > 0 ? acc / norm.squareRoot() * p.keyScale : 0
            }
            return out
        }
        return (rx, ry, field(), field())
    }

    struct Arm {
        /// Kelime doğruluğu — **kabul kapısı olan metrik budur.**
        var accuracy = 0.0
        /// Tuş başına uzamsal isabetin ortalaması (kalsız kola göre fark).
        /// En kötü tuştan çok daha kararlı; asıl uzamsal sinyal bu.
        var spatialMean = 0.0
        /// Tuş başına uzamsal isabette **en kötü** tuşun kaybı.
        ///
        /// **Teşhis, kapı değil.** 32 tuş üzerinden minimum almak güçlü bir
        /// seçim yanlılığı taşır ve tahmin gürültüsü tablo basamaklarıyla aynı
        /// mertebede. Ürün hedefi kelime doğruluğu; bu sayı "nerede bozuluyor"
        /// sorusunu yanıtlamak için var.
        var worstSpatialKey = 0.0
    }
    struct Result { var plain = 0.0; var global = Arm(); var hier = Arm()
                    var strongSamples = 0; var keysWithOwnLayer = 0 }

    /// **Aynı kullanıcının** kaç bağımsız eğitim/test çekilişiyle ölçüleceği.
    ///
    /// İki ayrı gerekçe, ikisi de ölçümün kendisinden çıktı:
    ///
    /// 1. Tek çekilişte 400 test kelimesinde 0.7 puanlık fark 3 kelime demek;
    ///    kollar arası küçük farklar tamamen gürültüydü.
    /// 2. "En kötü tuş" metriği tuş başına 8 kelimeye bakıyordu — orada tek bir
    ///    kelime 12.5 puan oynatıyor. §8.3'te raporlanan −8.3 puanlık "zarar"
    ///    ölçüm gürültüsünden ayırt edilemez.
    ///
    /// **Codex turunda düzeltilen hata:** tekrarlar önce her seferinde katman
    /// sapmalarını yeniden çekiyordu, yani aynı kullanıcının tekrarı değil
    /// farklı kullanıcılardı. Tuş sayaçları o kullanıcılar boyunca havuzlanınca
    /// birinin zararı diğerinin kazancıyla sessizce götürülüyordu. Artık
    /// katmanlar kullanıcıya sabit; tekrarlar yalnız eğitim ve test gürültüsü.
    let repeats = opt.calibrationRepeats
    /// Bir senaryonun kaç farklı kullanıcıyla koşulacağı. Kullanıcılar arası
    /// dağılım **dış** döngüde kalır; havuzlanmaz.
    let usersPerScenario = 3

    /// Tek bir kullanıcıyı ölçer: katmanlar sabit, `repeats` gürültü çekilişi.
    func runUser(_ p: Profile, user: UInt64, trainCount: Int) -> Result {
        let trainCount = min(trainCount, maxTrain)
        let trainWords = Array(words.prefix(trainCount))
        // Kullanıcının eli: tüm çekilişlerde AYNI.
        let L = layers(p, seed: user &+ 999)

        var hitAll = [0, 0, 0], nAll = 0
        var samplesAll = 0, ownLayerAll = 0
        // Uzamsal sonda: tuş başına, decode'dan bağımsız.
        var spatialHit = [[Int]](repeating: [Int](repeating: 0, count: layout.keys.count), count: 3)
        var spatialTotal = [Int](repeating: 0, count: layout.keys.count)

        for rep in 0..<repeats {
            let seed = user &+ UInt64(rep) &* 1013

            var learner = CalibrationLearner()
            var learnSim = TouchSimulator(layout: layout, seed: seed &+ 1)
            learnSim.sigmaScale = opt.sigma
            learnSim.rowBiasX = L.rx; learnSim.rowBiasY = L.ry
            learnSim.keyBiasX = L.kx; learnSim.keyBiasY = L.ky
            // Eğitim akışında düzeltme olayları KAPALI — bu bir sadeleştirme
            // değil, doğruluk düzeltmesi (Codex turu).
            //
            // Uzantı yalnız `commit == literal` olan token'lardan öğrenir ve
            // literal, kullanıcının fiilen bastığı harflerdir. Simülatör
            // transposition ürettiğinde dokunma dizisi ters sıradadır ama
            // benchmark `literal` olarak hedef kelimeyi veriyordu: dokunmalar
            // yanlış tuşlara "strong" etiketleniyordu. Dengeli bir
            // omission+insertion çifti de uzunluk kontrolünü geçip aynı şeyi
            // yapıyordu. Yani kalibrasyon deneyi kendi eğitim verisini
            // bozuyordu.
            learnSim.omissionRate = 0
            learnSim.insertionRate = 0
            learnSim.transpositionRate = 0
            // Kalın kuyruk da kapalı, aynı gerekçeyle ve aslında daha net:
            // simülatör bu olayda dokunmayı **komşu tuşun** merkezinden
            // örnekliyor ama karakteri hedef harf olarak bırakıyor. Gerçek
            // uzantıda literal dokunmanın düştüğü tuştan yazılır, yani o
            // dokunma komşunun harfini üretir, `commit == literal` bozulur ve
            // token'ın tamamı atılır. Açık bırakmak eğitim örneklerinin %3'ünü
            // "tam bir tuş yanlış" hâlde modele veriyordu — tuş başına ortalama
            // tam da komşuya doğru çekiliyordu ki Faz 3'ün ölçtüğü şey bu.
            learnSim.heavyTailRate = 0
            for (i, wc) in trainWords.enumerated() {
                let f = p.drift * Double(i) / Double(max(trainCount - 1, 1))
                learnSim.biasX = p.gx + f
                learnSim.biasY = p.gy + f
                guard let t = learnSim.touches(for: wc.0) else { continue }
                learner.observe(touches: t, literal: wc.0, committed: wc.0,
                                layout: layout, confidence: .strong)
            }

            var globalModel = SpatialModel(layout: layout)
            learner.apply(to: &globalModel)
            var hierModel = SpatialModel(layout: layout)
            learner.applyHierarchical(to: &hierModel)

            // Değerlendirmede sapma **son** hâlinde (kullanıcı oraya evrildi)
            // ve düzeltme olayları AÇIK — orada gerçekçi girdi isteniyor.
            var sim = TouchSimulator(layout: layout, seed: seed)
            sim.biasX = p.gx + p.drift; sim.biasY = p.gy + p.drift
            sim.sigmaScale = opt.sigma
            sim.rowBiasX = L.rx; sim.rowBiasY = L.ry
            sim.keyBiasX = L.kx; sim.keyBiasY = L.ky

            func decoder(_ m: SpatialModel) -> Decoder {
                Decoder(layout: layout, spatial: m, lexicon: lexicon,
                        weights: weights, beamWidth: opt.beamWidth)
            }
            let dPlain = decoder(SpatialModel(layout: layout))
            let dGlobal = decoder(globalModel)
            let dHier = decoder(hierModel)

            for (w, _) in testWords {
                guard let t = sim.touches(for: w) else { continue }
                nAll += 1
                let ok = [dPlain, dGlobal, dHier].map { $0.decode(touches: t, topK: 1).first?.word == w }
                for a in 0..<3 where ok[a] { hitAll[a] += 1 }
            }
            // --- Uzamsal sonda (Codex turu): "en kötü tuş" iddiasını
            // doğrudan atfedilebilir bir ölçüme dayandırmak için.
            //
            // Kelime decode'u kullanılmıyor: her tuş için o tuşa nişan alınmış
            // dokunmalar üretiliyor ve modelin argmax'ı doğru tuşu veriyor mu
            // diye bakılıyor. Kalibrasyonun fiilen değiştirdiği şey tam olarak
            // budur; kelime doğruluğu araya dil modelini ve edit olaylarını
            // sokar.
            var probe = TouchSimulator(layout: layout, seed: seed &+ 7)
            probe.biasX = p.gx + p.drift; probe.biasY = p.gy + p.drift
            probe.sigmaScale = opt.sigma
            probe.rowBiasX = L.rx; probe.rowBiasY = L.ry
            probe.keyBiasX = L.kx; probe.keyBiasY = L.ky
            probe.heavyTailRate = 0        // sonda saf uzamsal olmalı
            probe.omissionRate = 0; probe.insertionRate = 0; probe.transpositionRate = 0

            // Tuş başına sonda sayısı. Tek dokunma üretmek yetmez: eşik 40
            // örnek istiyor ve tuş başına 1 dokunma ile `spatialWorst` hiçbir
            // tuşu değerlendiremeden başlangıç değeri 0'ı döndürüyordu — yani
            // metrik sessizce "hiç zarar yok" diyordu. Codex turunda yakalandı.
            //
            // Sonda **yalnız son çekilişte** koşuyor. Maliyet sebebi somut:
            // tuş başına 200 sonda × 3 model × 32 tuş = çekiliş başına ~600 bin
            // `negLogP`, her biri dört `erfc`. Her çekilişte koşturmak deneyi
            // saatlere çıkarıyordu ve kazancı yok — sonda modeli ölçüyor,
            // ortalaması alınacak bir doğruluk değil.
            // Sonda **her çekilişte** koşuyor. Yalnız son çekilişte koşturmak
            // ucuzdu ama yanlıştı: ölçülen model rastgele bir eğitim
            // çekilişinin çıktısı, oysa kelime doğruluğu tüm çekilişlerin
            // ortalaması — aynı tablo satırındaki iki sayı farklı örnekleme
            // rejiminden gelirdi (Codex turu).
            //
            // Maliyeti kapatan şey önhesap: `negLogP`'nin normalizasyon terimi
            // (`logNorm + log(mass)`, dört `erfc`) dokunmaya değil yalnız tuşa
            // ve kalibrasyona bağlı. Tuş başına bir kez hesaplanınca iç döngüde
            // yalnız quadratic terim kalıyor. Sözleşme §11 zaten gerçek üründe
            // bunun önhesaplandığını söylüyor; sonda da aynısını yapıyor.
            let probesPerKey = 60
            let models = [SpatialModel(layout: layout), globalModel, hierModel]
            var mx = [[Double]](), my = [[Double]](), isx = [[Double]](),
                isy = [[Double]](), konst = [[Double]]()
            for m in models {
                var a = [Double](), b = [Double](), c = [Double](),
                    d = [Double](), e = [Double]()
                for j in layout.keys.indices {
                    let key = layout.keys[j], cal = m.calib[j]
                    let cx = key.center.x + cal.biasX, cy = key.center.y + cal.biasY
                    a.append(cx); b.append(cy)
                    c.append(1 / cal.sigmaX); d.append(1 / cal.sigmaY)
                    // negLogP = quad + logNorm + log(mass); ikisi de tuş sabiti.
                    let full = m.negLogP(TouchSample(down: Point(x: cx, y: cy)), keyIndex: j)
                    e.append(full)      // quad = 0 olduğu için bu doğrudan sabit
                }
                mx.append(a); my.append(b); isx.append(c); isy.append(d); konst.append(e)
            }

            for k in layout.keys.indices {
                let ch = String(layout.keys[k].char)
                var made = 0, attempts = 0
                while made < probesPerKey && attempts < probesPerKey * 8 {
                    attempts += 1
                    guard let t = probe.touches(for: ch), let touch = t.first else { break }
                    // Kenar kırpmasını **reddederek** ele: `TouchSimulator`
                    // koordinatı [0.001, 0.999]'a kırpıyor, `SpatialModel` ise
                    // truncate edilip yeniden normalize edilmiş sürekli bir
                    // yoğunluk varsayıyor. Kırpma sınırda noktasal kütle
                    // yaratır ve bu tam olarak kenar tuşlarını, yani "en kötü
                    // tuş"un en çok çıkacağı yeri etkiler.
                    if touch.down.x <= 0.0011 || touch.down.x >= 0.9989
                        || touch.down.y <= 0.0011 || touch.down.y >= 0.9989 { continue }
                    made += 1
                    spatialTotal[k] += 1
                    for a in 0..<3 {
                        var best = 0, bestCost = Double.infinity
                        for j in layout.keys.indices {
                            let zx = (touch.down.x - mx[a][j]) * isx[a][j]
                            let zy = (touch.down.y - my[a][j]) * isy[a][j]
                            let c = 0.5 * (zx * zx + zy * zy) + konst[a][j]
                            if c < bestCost { bestCost = c; best = j }
                        }
                        if best == k { spatialHit[a][k] += 1 }
                    }
                }
            }

            let e = learner.hierarchicalEstimate(layout: layout)
            samplesAll += e.strongSamples
            ownLayerAll += e.keysWithOwnLayer
        }

        guard nAll > 0 else { return Result() }

        guard nAll > 0 else { return Result() }

        // Ölçülemeyen değer sıfır DEĞİLDİR. `0.0` "zarar yok" gibi okunur ve
        // tam da bu, sondanın hiçbir tuşu değerlendiremediğinin fark edilmesini
        // geciktirdi. Uygun tuş yoksa sonuç NaN.
        func spatialStats(_ arm: Int) -> (mean: Double, worst: Double) {
            var worst = 0.0, sum = 0.0, eligible = 0
            for k in 0..<layout.keys.count where spatialTotal[k] >= 40 {
                eligible += 1
                let pa = Double(spatialHit[0][k]) / Double(spatialTotal[k])
                let pb = Double(spatialHit[arm][k]) / Double(spatialTotal[k])
                let d = 100 * (pb - pa)
                worst = min(worst, d); sum += d
            }
            guard eligible > 0 else { return (.nan, .nan) }
            return (sum / Double(eligible), worst)
        }
        let sg = spatialStats(1), sh = spatialStats(2)
        return Result(plain: 100 * Double(hitAll[0]) / Double(nAll),
                      global: Arm(accuracy: 100 * Double(hitAll[1]) / Double(nAll),
                                  spatialMean: sg.mean, worstSpatialKey: sg.worst),
                      hier: Arm(accuracy: 100 * Double(hitAll[2]) / Double(nAll),
                                spatialMean: sh.mean, worstSpatialKey: sh.worst),
                      strongSamples: samplesAll / repeats,
                      keysWithOwnLayer: ownLayerAll / repeats)
    }

    /// Bir senaryoyu birden çok kullanıcıyla koşar; doğruluk ortalanır, en kötü
    /// tuş **kullanıcı başına** hesaplanıp en kötüsü raporlanır (havuzlanmaz).
    func run(_ p: Profile, seed: UInt64, trainCount: Int, users: Int) -> Result {
        var acc = [0.0, 0.0, 0.0]
        var sGlobal = 0.0, sHier = 0.0, mGlobal = 0.0, mHier = 0.0
        var samples = 0, own = 0
        for u in 0..<users {
            let r = runUser(p, user: seed &+ UInt64(u) &* 7919, trainCount: trainCount)
            acc[0] += r.plain; acc[1] += r.global.accuracy; acc[2] += r.hier.accuracy
            // NaN "ölçülemedi" demek; `min` ile sessizce yutulmamalı.
            func worse(_ acc: Double, _ v: Double) -> Double {
                v.isNaN ? .nan : (acc.isNaN ? .nan : min(acc, v))
            }
            sGlobal = worse(sGlobal, r.global.worstSpatialKey)
            sHier = worse(sHier, r.hier.worstSpatialKey)
            mGlobal += r.global.spatialMean
            mHier += r.hier.spatialMean
            samples += r.strongSamples; own += r.keysWithOwnLayer
        }
        let k = Double(users)
        return Result(plain: acc[0] / k,
                      global: Arm(accuracy: acc[1] / k, spatialMean: mGlobal / k,
                                  worstSpatialKey: sGlobal),
                      hier: Arm(accuracy: acc[2] / k, spatialMean: mHier / k,
                                worstSpatialKey: sHier),
                      strongSamples: samples / users,
                      keysWithOwnLayer: own / users)
    }

    // DİKKAT: `TouchSimulator` sapmaları **referans tuş ölçüsü** birimindedir,
    // normalize koordinat değil. İlk denemede 0.018 yazılmıştı — tuşun %1.8'i,
    // yani ölçülemez. Bu birim karışıklığı deneyi sessizce anlamsız kılıyordu.
    struct Scenario { let name: String; let p: Profile; let note: String }
    let scenarios = [
        Scenario(name: "sapma yok", p: Profile(),
                 note: "iki kol da ZARAR VERMEMELİ"),
        Scenario(name: "yalnız global", p: Profile(gx: 0.35, gy: 0.30),
                 note: "Faz 1'in alanı"),
        Scenario(name: "global+satır", p: Profile(gx: 0.25, gy: 0.20, rowScale: 0.25),
                 note: "orta katman"),
        Scenario(name: "global+satır+tuş", p: Profile(gx: 0.25, gy: 0.20, rowScale: 0.20,
                                                      keyScale: 0.25, correlationLength: 2.0),
                 note: "Faz 3'ün gerekçesi (düzgün alan)"),
        Scenario(name: "yalnız tuş", p: Profile(keyScale: 0.30, correlationLength: 2.0),
                 note: "global öğrenecek şey yok"),
        Scenario(name: "yalnız tuş (IID)", p: Profile(keyScale: 0.30),
                 note: "STRES: komşular bağımsız sapıyor"),
        Scenario(name: "zamanla değişen", p: Profile(gx: 0.10, gy: 0.10, rowScale: 0.20, drift: 0.30),
                 note: "bayat tahmin"),
    ]

    let trainCount = min(400, maxTrain)
    print("  eğitim \(trainCount) kelime · test \(testWords.count) kelime (AYRIK)")
    print("  senaryo başına \(usersPerScenario) kullanıcı × \(repeats) çekiliş"
          + " · en kötü tuş kullanıcı başına hesaplanır\n")
    // `String(format:)` genişlik belirteci `%@` ile güvenilir çalışmıyor
    // (Türkçe karakterlerde hiç dolgu yapmıyor); dolgu Swift tarafında.
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
    print("  uzamsal = tuş başına dokunma isabeti, kalsız kola göre fark (kelime decode'u yok)")
    print("  ort = 32 tuşun ortalaması (kararlı) · eK = en kötü tuş (TEŞHİS, kapı değil)\n")
    print("  " + pad("senaryo", 19) + lpad("kalsız", 7) + lpad("global", 7)
          + lpad("hiyer.", 7) + lpad("uzOrt-g", 8) + lpad("uzOrt-h", 8)
          + lpad("eK-g", 7) + lpad("eK-h", 7) + "  beklenti")

    var worstKeyGlobal = 0.0, worstKeyHier = 0.0
    var worstDeltaHier = 0.0
    for sc in scenarios {
        let r = run(sc.p, seed: opt.seed, trainCount: trainCount, users: usersPerScenario)
        worstKeyGlobal = min(worstKeyGlobal, r.global.worstSpatialKey)
        worstKeyHier = min(worstKeyHier, r.hier.worstSpatialKey)
        worstDeltaHier = min(worstDeltaHier, r.hier.accuracy - r.plain)
        func pct(_ v: Double) -> String { lpad(String(format: "%.1f%%", v), 7) }
        func sd(_ v: Double, _ n: Int) -> String {
            lpad(v.isNaN ? "n/a" : String(format: "%+.1f", v), n)
        }
        print("  " + pad(sc.name, 19) + pct(r.plain) + pct(r.global.accuracy)
              + pct(r.hier.accuracy)
              + sd(r.global.spatialMean, 8) + sd(r.hier.spatialMean, 8)
              + sd(r.global.worstSpatialKey, 7) + sd(r.hier.worstSpatialKey, 7)
              + "  " + sc.note)
    }

    // Eğitim boyutu taraması. Faz 3'ün tüm önermesi ince katmanın **veri
    // istediği**; az veride hiyerarşinin global'e inmesi (zarar vermemesi)
    // kazanç kadar önemli bir sonuçtur.
    // Rezervuar kapasitesi taramanın üst sınırını belirliyor: `CalibrationLearner`
    // yalnız son 2000 güçlü örneği tutuyor. Bunun üstündeki basamaklar "daha
    // fazla veri" ölçmez, yalnız rezervuarda kalan farklı kelime dağılımını
    // ölçer. Doygunluk satırda işaretleniyor (Codex turu).
    print("\n  eğitim boyutu (senaryo: global+satır+tuş):")
    print("    NOT: rezervuar kapasitesi \(CalibrationLearner.reservoirCapacity) örnek;"
          + " ★ = doygunluk, o satırdan sonrası daha fazla veri DEĞİL")
    print("    " + lpad("kelime", 8) + lpad("örnek", 8) + lpad("kalsız", 8)
          + lpad("global", 8) + lpad("hiyer.", 8) + lpad("kendi d_c'si", 14))
    let sweepProfile = Profile(gx: 0.25, gy: 0.20, rowScale: 0.20,
                               keyScale: 0.25, correlationLength: 2.0)
    // Aynı boyut iki kez koşulmasın: `--limit` küçükse üst basamaklar
    // `maxTrain`e kırpılır ve tablo yanıltıcı biçimde tekrar ederdi.
    var seenSizes = Set<Int>()
    for tc in [60, 120, 400, 1200] {
        let eff = min(tc, maxTrain)
        guard seenSizes.insert(eff).inserted else { continue }
        let r = run(sweepProfile, seed: opt.seed, trainCount: eff, users: 1)
        func pct(_ v: Double) -> String { lpad(String(format: "%.1f%%", v), 8) }
        let saturated = r.strongSamples >= CalibrationLearner.reservoirCapacity
        print("    " + lpad("\(eff)", 8) + lpad("\(r.strongSamples)\(saturated ? "★" : "")", 8)
              + pct(r.plain) + pct(r.global.accuracy) + pct(r.hier.accuracy)
              + lpad("\(r.keysWithOwnLayer)/\(layout.keys.count)", 14))
    }

    // Kullanıcı dağılımı: p10 kullanıcı sonucu (plan §9 metrik 6).
    // Ortalama iyileşme eğrisi yetmez — kaç kullanıcının zarar gördüğü lazım.
    print("\n  kullanıcı dağılımı (24 sentetik kullanıcı, rastgele katmanlı sapma):")
    var dGlobal: [Double] = [], dHier: [Double] = [], dGain: [Double] = []
    var rngState: UInt64 = opt.seed &+ 12345
    func nextUniform() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        return Double(rngState >> 11) / Double(1 << 53)
    }
    for u in 0..<24 {
        let p = Profile(gx: (nextUniform() - 0.5) * 0.9,      // ±0.45 tuş
                        gy: (nextUniform() - 0.5) * 0.9,
                        rowScale: nextUniform() * 0.25,
                        keyScale: nextUniform() * 0.30,
                        correlationLength: 2.0)
        let r = runUser(p, user: opt.seed &+ UInt64(u) &* 77, trainCount: trainCount)
        dGlobal.append(r.global.accuracy - r.plain)
        dHier.append(r.hier.accuracy - r.plain)
        dGain.append(r.hier.accuracy - r.global.accuracy)
    }
    func report(_ label: String, _ d: [Double]) {
        let v = d.sorted()
        print("    " + pad(label, 22)
              + String(format: "p10 %+.1f · medyan %+.1f · p90 %+.1f · zarar gören %d/%d",
                       v[max(0, Int(0.10 * Double(v.count)))],
                       v[v.count / 2],
                       v[min(v.count - 1, Int(0.90 * Double(v.count)))],
                       v.filter { $0 < -0.5 }.count, v.count))
    }
    report("global − kalsız", dGlobal)
    report("hiyerarşik − kalsız", dHier)
    report("hiyerarşik − global", dGain)

    print(String(format: "\n  EN KÖTÜ TUŞ (uzamsal, TEŞHİS): global %+.1f · hiyerarşik %+.1f puan",
                 worstKeyGlobal, worstKeyHier))
    print("  32 tuş üzerinden minimum alınıyor; seçim yanlılığı taşır ve tahmin")
    print("  gürültüsü tablo basamaklarıyla aynı mertebede. Kabul kapısı KELİME")
    print("  doğruluğu ve kullanıcı dağılımıdır.")
    print(String(format: "  EN KÖTÜ SENARYO (hiyerarşik − kalsız): %+.1f puan", worstDeltaHier))
    print("  (negatif değerler kalibrasyonun zarar verdiğini gösterir)")
}
