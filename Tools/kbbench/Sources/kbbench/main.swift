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
let morph = opt.morphology ? spikeMorphology(extra: opt.syntheticRoots) : nil
// --json modunda hiçbir şey basma; çıktı ayrıştırılabilir kalmalı.
if let m = morph, !opt.json {
    print("morfoloji: \(m.roots.count) kök · başlangıç frontier'ı \(m.startStates().count) durum")
}
let lexicon = LexiconSet(formTrie: trie, morphology: morph)
let decoder = Decoder(layout: layout, spatial: spatial, lexicon: lexicon, beamWidth: opt.beamWidth)

var sim = TouchSimulator(layout: layout, seed: opt.seed)
sim.biasX = opt.biasX
sim.biasY = opt.biasY
sim.sigmaScale = opt.sigma

// Isınma — ilk çağrılar sayfa hatası ve tembel kurulum içerir.
for (w, _) in words.prefix(opt.warmup) {
    if let t = sim.touches(for: w) { _ = decoder.decode(touches: t, topK: 3) }
}

var top1 = 0, top3 = 0, attempted = 0, skipped = 0
var latencies: [Double] = []
var perKeystroke: [Double] = []
/// Yanlış düzeltme: kelime **temiz** (gürültüsüz) yazıldığı hâlde top-1 değişmişse.
var cleanAttempts = 0, falseCorrections = 0
/// Uzunluğa göre hata: [uzunluk: (deneme, hata)]
var byLength: [Int: (Int, Int)] = [:]

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
    let results = decoder.decode(touches: touches, topK: 3)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    latencies.append(ms)
    perKeystroke.append(ms / Double(max(touches.count, 1)))

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
        if decoder.decode(touches: clean, topK: 1).first?.word != word { falseCorrections += 1 }
    }
}

latencies.sort()
perKeystroke.sort()

let acc1 = Double(top1) / Double(max(attempted, 1)) * 100
let acc3 = Double(top3) / Double(max(attempted, 1)) * 100
let fcRate = Double(falseCorrections) / Double(max(cleanAttempts, 1)) * 100

if opt.json {
    let obj: [String: Any] = [
        "words": attempted, "skipped": skipped,
        "top1": acc1, "top3": acc3, "falseCorrectionRate": fcRate,
        "latencyMs": ["p50": percentile(latencies, 0.50),
                      "p95": percentile(latencies, 0.95),
                      "p99": percentile(latencies, 0.99),
                      "max": latencies.last ?? 0],
        "perKeystrokeMs": ["p50": percentile(perKeystroke, 0.50),
                           "p95": percentile(perKeystroke, 0.95),
                           "p99": percentile(perKeystroke, 0.99)],
        "beam": opt.beamWidth, "morphology": opt.morphology, "seed": opt.seed,
        "roots": morph?.roots.count ?? 0,
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
    │ YANLIŞ DÜZELTME : \(String(format: "%.2f%%", fcRate))  ← kullanıcının hissettiği metrik
    ├─ gecikme (kelime başına) ─────────────────────────────
    │ p50 \(String(format: "%7.2f", percentile(latencies, 0.50))) ms   \
    p95 \(String(format: "%7.2f", percentile(latencies, 0.95))) ms
    │ p99 \(String(format: "%7.2f", percentile(latencies, 0.99))) ms   \
    max \(String(format: "%7.2f", latencies.last ?? 0)) ms
    ├─ gecikme (TUŞ başına — bütçe p99 < 8 ms) ─────────────
    │ p50 \(String(format: "%7.2f", percentile(perKeystroke, 0.50))) ms   \
    p95 \(String(format: "%7.2f", percentile(perKeystroke, 0.95))) ms
    │ p99 \(String(format: "%7.2f", percentile(perKeystroke, 0.99))) ms
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
