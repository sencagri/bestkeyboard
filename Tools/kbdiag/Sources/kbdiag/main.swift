import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder
import KBMorphology

let layout = TurkishQ.layout()
let spatial = SpatialModel(layout: layout)
let w = ScoreWeights()

let counts: [String: Double] = [
    "kalem": 900, "işlem": 1500, "kalan": 700, "eklem": 180, "islem": 5,
    "kalemi": 300, "kalıp": 260, "ıslak": 120,
]
let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
let (bytes, _) = try FormTrieBuilder().build(entries: entries)
_ = try FormTrie(bytes: bytes)
let oracle = Oracle(layout: layout, spatial: spatial, weights: w)

func touches(_ s: String) -> [TouchSample] {
    s.enumerated().map { i, ch in
        TouchSample(down: layout.keys[layout.keyIndex(for: ch)!].center, timestamp: Double(i) * 0.15)
    }
}

let t = touches("lslem")
print("=== 'lslem' dokunma dizisi ===")
print("kelime       toplam      F_lex      kanal")
for e in entries.sorted(by: { oracle.cost(word: $0.word, touches: t, lexCost: $0.lexCost)
                            < oracle.cost(word: $1.word, touches: t, lexCost: $1.lexCost) }) {
    let total = oracle.cost(word: e.word, touches: t, lexCost: e.lexCost)
    let lex = w.wLex * e.lexCost
    print(e.word.padding(toLength: 12, withPad: " ", startingAt: 0)
          + String(format: "%8.3f   %8.3f   %8.3f", total, lex, total - lex))
}

print("\n=== Tuş bazlı uzamsal maliyet ===")
func spa(_ typed: Character, _ target: Character) {
    let tt = TouchSample(down: layout.keys[layout.keyIndex(for: typed)!].center)
    let direct = spatial.negLogP(tt, keyIndex: layout.keyIndex(for: target)!)
    var line = "\(typed)→\(target)  doğrudan=" + String(format: "%8.3f", direct)
    if let b = layout.asciiBaseKeyIndex(for: target) {
        let eq = w.wSpaEq * spatial.negLogP(tt, keyIndex: b) + w.wEq
        line += "  eşdeğerlik=" + String(format: "%8.3f", eq)
             + "  min=" + String(format: "%8.3f", min(direct, eq))
    }
    print(line)
}
spa("l", "k"); spa("s", "a"); spa("l", "i"); spa("s", "ş")

// MARK: - -1A₂ state şeması ölçümü

let spikeRoots: [Root] = [
    Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
    Root("kalem", pos: .noun, lexCost: 4.2),
    Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
    Root("renk",  pos: .noun, lexCost: 5.2, finalAlternation: .kToG),
    Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
    Root("gel",   pos: .verb, lexCost: 4.0),
]
let morph = MorphologyAutomaton(roots: spikeRoots)

print("\n=== -1A₂ düğüm şeması: ölçülen bit genişlikleri ===")
func report(_ name: String, _ l: MorphologyNodeLayout) {
    print("""
    \(name)
      \(l.breakdown)
      UInt32'ye sığar mı: \(l.fitsInUInt32 ? "EVET" : "HAYIR")
      TAM dedup anahtarı: \(DecoderKeyLayout.total(nodeBits: l.total)) bit
    """)
}
report("spike (\(spikeRoots.count) kök)", morph.nodeLayout)
report("ÜRETİM tahmini (Faz 4)", MorphologyNodeLayout.productionEstimate)

let reach = morph.reachableStates(maxSurfaceLen: 10)
var packed = Set<UInt64>()
for st in reach { if let p = st.packed(morph.nodeLayout) { packed.insert(p) } }
print("  erişilebilir durum: \(reach.count) · benzersiz paketlenmiş: \(packed.count) · çakışma: \(reach.count - packed.count)")

print("\n=== türetilen formlar ===")
for name in ["kitap", "çocuk", "renk", "burun"] {
    let i = spikeRoots.firstIndex { String($0.surface) == name }!
    let forms = (try? morph.generate(rootIndex: i, maxSuffixes: 1)) ?? []
    let uniq = Set(forms.map(\.surface)).sorted()
    print("  \(name) → \(uniq.joined(separator: ", "))")
}

// MARK: - Çoklu kaynak entegrasyonu
print("\n=== çoklu kaynak: decoder ABI ===")
let mRoots: [Root] = [
    Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
    Root("kalem", pos: .noun, lexCost: 4.2),
    Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
    Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
    Root("gel",   pos: .verb, lexCost: 4.0),
]
let mAuto = MorphologyAutomaton(roots: mRoots)
let trieCounts: [String: Double] = ["işlem": 1500, "eklem": 180, "masa": 500]
let tEntries = try FormTrieBuilder.lexCosts(fromCounts: trieCounts)
let tTrie = try FormTrie(bytes: try FormTrieBuilder().build(entries: tEntries).bytes)

for (name, set) in [
    ("yalnız trie",      LexiconSet(formTrie: tTrie, morphology: nil)),
    ("yalnız morfoloji", LexiconSet(formTrie: nil, morphology: mAuto)),
    ("ikisi birden",     LexiconSet(formTrie: tTrie, morphology: mAuto)),
] {
    let dec = Decoder(layout: layout, spatial: spatial, lexicon: set, beamWidth: 512)
    print("\n  [\(name)] başlangıç frontier: \(set.startPositions().count) durum")
    for word in ["kalemlerimizden", "kitapta", "burnu", "işlem"] {
        let ts = word.enumerated().compactMap { i, ch -> TouchSample? in
            guard let k = layout.keyIndex(for: ch) else { return nil }
            return TouchSample(down: layout.keys[k].center, timestamp: Double(i) * 0.15)
        }
        guard ts.count == word.count else { continue }
        let t0 = Date().timeIntervalSince1970
        let r = dec.decode(touches: ts, topK: 1)
        let ms = (Date().timeIntervalSince1970 - t0) * 1000
        let got = r.first.map { "\($0.word) (\(String(format: "%.2f", $0.cost)))" } ?? "—"
        print(String(format: "    %-18@ → %-28@ %6.1f ms", word as NSString, got as NSString, ms))
    }
}

// MARK: - Literal kanalı ölçek teşhisi
//
// `c_unk` ve `θ` ancak bu iki ölçek yan yana görülünce ayarlanabilir. Sorulan
// soru: sözlük dışı ama Türkçeye benzeyen bir token, sözlükteki NADİR bir
// kelimeden pahalı mı (öyle olmalı) ama tuş gürültüsünden ucuz mu (öyle olmalı)?
//
//   kbdiag --literal <tr-TR.bkt> <tr-TR.bkc> [tr-TR.bkr]

let dargs = CommandLine.arguments
if dargs.count >= 4, dargs[1] == "--literal" {
    let trieData = try Data(contentsOf: URL(fileURLWithPath: dargs[2]), options: .mappedIfSafe)
    let realTrie = try FormTrie(data: trieData)
    let model = try CharNGram(packData: try Data(contentsOf: URL(fileURLWithPath: dargs[3])))
    // Kök paketi varsa morfoloji de `V`'ye dahil — kanalın gerçek sevk
    // konfigürasyonu bu.
    var realMorph: MorphologyAutomaton?
    if dargs.count >= 5,
       let rd = try? Data(contentsOf: URL(fileURLWithPath: dargs[4])),
       let rp = try? RootPack(data: rd) {
        realMorph = MorphologyAutomaton(roots: rp.roots)
    }
    let realLexicon = LexiconSet(formTrie: realTrie, morphology: realMorph)
    let channel = LiteralChannel(vocabulary: realLexicon, charModel: model)
    print("  kaynak: form listesi\(realMorph != nil ? " + morfoloji" : " (morfoloji yok)")")

    print("\n=== literal kanalı ölçeği (c_unk = \(channel.cUnk)) ===")
    print(String(format: "%-22@ %-10@ %8@  %@",
                 "token" as NSString, "kanal" as NSString,
                 "F_lex" as NSString, "not" as NSString))

    let probes: [(String, String)] = [
        ("ve",              "en sık kelimelerden"),
        ("kalem",           "orta sıklık"),
        ("kalemlerimizden", "morfolojik, listede yok"),
        ("sencagri",        "özel ad, OOV"),
        ("kalemlik",        "Türkçeye benzeyen OOV"),
        ("kqxwjf",          "tuş gürültüsü"),
        ("192.168.1.42",    "literal token"),
        ("😀",              "alfabe dışı"),
    ]
    for (p, note) in probes {
        let s = channel.score(p)
        let kanal = s.isInVocabulary ? "sözlük" : (s.overflowed ? "taşma" : "n-gram")
        print(String(format: "%-22@ %-10@ %8.2f  %@",
                     p as NSString, kanal as NSString, s.lexCost, note as NSString))
    }

    // KARAKTER BAŞINA maliyet — `θ` politikasının dayanabileceği tek ölçü.
    // Toplam maliyet uzunlukla büyüdüğü için doğru yazılmış uzun bir özel adı
    // gürültüden ayıramaz; normalize edilmiş hâli ayırabilir mi?
    print("\n=== karakter başına OOV maliyeti (n-gram kanalından geçenler) ===")
    let oovProbes = [
        ("lslem",     "kalem'in kaydırılmışı — DÜZELTİLMELİ"),
        ("guzell",    "typo — DÜZELTİLMELİ"),
        ("eeklam",    "typo — DÜZELTİLMELİ"),
        ("sencagri",  "özel ad — KORUNMALI"),
        ("ayşenur",   "özel ad — KORUNMALI"),
        ("kalemlik",  "türetilmiş — KORUNMALI"),
        ("zeynepcim", "argo/özel — KORUNMALI"),
        ("kqxwjf",    "tuş gürültüsü — DÜZELTİLMELİ"),
        ("asdfgh",    "tuş gürültüsü — DÜZELTİLMELİ"),
    ]
    print(String(format: "%-12@ %8@ %9@  %@", "token" as NSString,
                 "toplam" as NSString, "kar/başı" as NSString, "beklenti" as NSString))
    for (p, note) in oovProbes {
        let s = channel.score(p)
        let kanal = s.isInVocabulary ? "SÖZLÜK" : ""
        let perChar = (s.lexCost - channel.cUnk) / Double(p.count)
        print(String(format: "%-12@ %8.2f %9.2f  %@ %@",
                     p as NSString, s.lexCost, perChar, note as NSString, kanal as NSString))
    }

    // Gecikme: `lexCost(ofSurface:)` boşluk başına ANA THREAD'de çalışıyor.
    // Morfoloji tarafında yüzey yürüyüşü yapıyor, yani ölçülmesi gerekiyor.
    var lat: [Double] = []
    let latProbes = ["kalem", "kalemlerimizden", "çocuklarımızdan", "sencagri",
                     "kqxwjf", "evlerimizdekilerden", "a", "192.168.1.42"]
    for _ in 0..<50 { for p in latProbes { _ = channel.score(p) } }   // ısınma
    for _ in 0..<200 {
        for p in latProbes {
            let t0 = Date().timeIntervalSince1970
            _ = channel.score(p)
            lat.append((Date().timeIntervalSince1970 - t0) * 1000)
        }
    }
    lat.sort()
    func pct(_ q: Double) -> Double { lat[min(Int(Double(lat.count) * q), lat.count - 1)] }
    print(String(format: "\n  gecikme (token başına, %d örnek): p50 %.3f · p95 %.3f · p99 %.3f · max %.3f ms",
                 lat.count, pct(0.50), pct(0.95), pct(0.99), lat.last ?? 0))
    print("  (boşluk başına BİR kez; tuş başına 8 ms bütçesinin dışında ama aynı thread'de)")

    // Asıl kapı: OOV bandı, sözlüğün en nadir kuyruğunun ÜSTÜNDE mi?
    let rarest = ["islem", "eklem"].compactMap { realTrie.lookup($0) }.max() ?? 0
    let oov = channel.score("kalemlik").lexCost
    print(String(format: "\n  sözlük kuyruğu ≈ %.2f · Türkçemsi OOV = %.2f · fark = %+.2f",
                 rarest, oov, oov - rarest))
    print("  (fark pozitif olmalı: bilinen nadir kelime, bilinmeyen kelimeden ucuz)")
}

// MARK: - θ ölçümü
//
//   kbdiag --theta <tr-TR.bkt> <tr-TR.bkc> [tr-TR.bkr]
//
// `θ`'nın veriyle seçilmesi gereken tek parametre olduğunu sözleşme §8 söylüyor.
// Gerçek dokunma verisi yokken bile bir şey ölçebiliriz: kullanıcı **tam olarak
// ne demek istediyse onu yazdığında** `Δ` ne oluyor?
//
// İki aile:
//   A) typo — kullanıcı kaydırmış, DÜZELTİLMELİ  → Δ büyük olmalı
//   B) doğru yazılmış sözlük dışı kelime, KORUNMALI → Δ küçük/negatif olmalı
//
// İkisinin arasında bir boşluk varsa `θ` oraya oturur. Boşluk yoksa `θ` bu
// kanıtla seçilemez ve bunu söylemek gerekir.
//
// SINIR: dokunmalar SİMÜLE değil, tam tuş merkezleri — "kullanıcı yazmak
// istediğini tam bastı" varsayımı. Gerçek parmak gürültüsü Δ'yı her iki yönde
// de yayar; bu ölçüm bir ALT SINIR verir, kalibrasyonun yerine geçmez (§9).
if dargs.count >= 4, dargs[1] == "--theta" {
    let trieData = try Data(contentsOf: URL(fileURLWithPath: dargs[2]), options: .mappedIfSafe)
    let tTrie2 = try FormTrie(data: trieData)
    let cModel = try CharNGram(packData: try Data(contentsOf: URL(fileURLWithPath: dargs[3])))
    var mAuto2: MorphologyAutomaton?
    if dargs.count >= 5, let rd = try? Data(contentsOf: URL(fileURLWithPath: dargs[4])),
       let rp = try? RootPack(data: rd) { mAuto2 = MorphologyAutomaton(roots: rp.roots) }
    let lex2 = LexiconSet(formTrie: tTrie2, morphology: mAuto2)
    let chan = LiteralChannel(vocabulary: lex2, charModel: cModel)
    let dec2 = Decoder(layout: layout, spatial: spatial, lexicon: lex2, beamWidth: 128)
    let wts = ScoreWeights()

    func delta(_ typed: String) -> (Double, String)? {
        let ts = typed.compactMap { ch -> TouchSample? in
            guard let k = layout.keyIndex(for: ch) else { return nil }
            return TouchSample(down: layout.keys[k].center, timestamp: 0)
        }
        guard ts.count == typed.count else { return nil }
        guard let best = dec2.decode(touches: ts, topK: 1).first else { return nil }
        let s = chan.score(typed)
        if s.demandsProtection { return (-Double.infinity, "korumalı") }
        // cost(literal): tam tuş merkezleri → uzamsal terim tuş başına sabit.
        let spatialCost = ts.enumerated().reduce(0.0) { acc, p in
            guard let k = layout.keyIndex(for: Array(typed)[p.offset]) else { return acc }
            return acc + dec2.spatial.negLogP(p.element, keyIndex: k)
        }
        let litCost = spatialCost + wts.wLex * s.lexCost + wts.wLen * Double(typed.count)
        return (litCost - best.cost, best.word)
    }

    print("\n=== Δ dağılımı — θ bu iki ailenin ARASINA oturmalı ===")
    let typos = ["lslem", "guzell", "eeklam", "kslem", "iaman", "arsba",
                 "yspmak", "gelfi", "kitpa", "çoçuk"]
    let correct = ["sencagri", "ayşenur", "zeynepcim", "mustafam", "elifnaz",
                   "berkay", "ecrin", "kaanhan", "duygunur", "alperen"]

    var aMin = Double.infinity, bMax = -Double.infinity
    print("\n  A) typo — DÜZELTİLMELİ")
    for t in typos {
        guard let (d, w) = delta(t) else { continue }
        if d.isFinite { aMin = min(aMin, d) }
        print(String(format: "     %-10@ Δ = %8.2f  → %@", t as NSString, d, w as NSString))
    }
    print("\n  B) doğru yazılmış sözlük dışı — KORUNMALI")
    for t in correct {
        guard let (d, w) = delta(t) else { continue }
        if d.isFinite { bMax = max(bMax, d) }
        print(String(format: "     %-10@ Δ = %8.2f  → %@", t as NSString, d, w as NSString))
    }
    print(String(format: "\n  A ailesinin EN DÜŞÜĞÜ : %.2f", aMin))
    print(String(format: "  B ailesinin EN YÜKSEĞİ: %.2f", bMax))
    if aMin > bMax {
        print(String(format: "  → BOŞLUK VAR: θ ∈ (%.2f, %.2f); ortası %.2f",
                     bMax, aMin, (aMin + bMax) / 2))
    } else {
        print("  → BOŞLUK YOK: θ bu kanıtla seçilemez, hangi değer seçilirse")
        print("    seçilsin ya typo kaçar ya doğru kelime bozulur.")
    }
}

// MARK: - Diller arası ölçek uyumu
//
//   kbdiag --scale <tr.bkt> <en.bkt>
//
// §5b: iki dil paketi bağımsız korpuslardan üretiliyor, `−log(freq/total)`
// ölçekleri birebir aynı olmak zorunda değil. Sözleşme bir `offset_ℓ` istiyor
// ve onun "ortak dev korpusunda fit edilmesini" söylüyor.
//
// Ortak korpus yok. Ama ölçebileceğimiz bir şey var: **iki listede de bulunan
// kelimeler**. Bunlar aynı gerçek dünya nesnesini (aynı yazım, çoğu kez aynı
// kavram) iki farklı korpus ölçeğinden gördüğümüz noktalar. Aralarındaki
// sistematik fark, ölçek kaymasının doğrudan tahminidir.
//
// SINIR: ortak kelimeler rastgele bir örneklem DEĞİL — özel adlar, alıntılar ve
// kısa diziler baskın. Bu yüzden medyan (ortalama değil) raporlanıyor ve
// dağılımın genişliği de gösteriliyor: dar değilse tek bir offset yetmez.
if dargs.count >= 4, dargs[1] == "--scale" {
    let a = try FormTrie(data: try Data(contentsOf: URL(fileURLWithPath: dargs[2]), options: .mappedIfSafe))
    let b = try FormTrie(data: try Data(contentsOf: URL(fileURLWithPath: dargs[3]), options: .mappedIfSafe))

    // TSV'lerden kelime listelerini oku (trie enumerasyonu yok).
    func words(_ path: String) -> [String] {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap { line in
            if line.hasPrefix("#") || line.isEmpty { return nil }
            return line.split(separator: "\t").first.map(String.init)
        }
    }
    let trWords = Set(words("LanguagePacks/tr-TR/wordlist.tsv"))
    let enWords = words("LanguagePacks/en-US/wordlist.tsv")

    var diffs: [Double] = []
    var examples: [(String, Double, Double)] = []
    for w in enWords where trWords.contains(w) {
        guard let ca = a.lookup(w), let cb = b.lookup(w) else { continue }
        diffs.append(cb - ca)
        if examples.count < 8 { examples.append((w, ca, cb)) }
    }
    diffs.sort()

    print("\n=== diller arası ölçek uyumu (§5b) ===")
    print("  tr listesi: \(trWords.count) · en listesi: \(enWords.count)")
    print("  ortak yüzey: \(diffs.count)")
    guard diffs.count >= 20 else {
        print("  → ortak yüzey çok az, offset ölçülemez; 0 bırakılmalı")
        exit(0)
    }
    func q(_ p: Double) -> Double { diffs[min(Int(Double(diffs.count) * p), diffs.count - 1)] }
    let median = q(0.50)
    print(String(format: "  Δ = maliyet_en − maliyet_tr   (nat)"))
    print(String(format: "    p10 %+.2f · p25 %+.2f · MEDYAN %+.2f · p75 %+.2f · p90 %+.2f",
                 q(0.10), q(0.25), median, q(0.75), q(0.90)))
    print(String(format: "    çeyrekler arası genişlik: %.2f nat", q(0.75) - q(0.25)))
    print("\n  örnekler (kelime · tr · en):")
    for (w, ca, cb) in examples {
        print(String(format: "    %-14@ %7.2f %7.2f  Δ %+.2f", w as NSString, ca, cb, cb - ca))
    }
    print(String(format: "\n  → offset_en = %+.2f nat (medyan; referans dil tr = 0 sabit)", -median))
    if q(0.75) - q(0.25) > 4 {
        print("  UYARI: dağılım geniş — tek bir sabit offset bu farkı temsil etmiyor.")
        print("  Sözleşmenin istediği ortak dev korpusu bunun yerine geçemez.")
    }
}
