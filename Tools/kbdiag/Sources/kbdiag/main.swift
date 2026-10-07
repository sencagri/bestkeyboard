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

// MARK: - θ ölçümü (GERÇEKÇİ dokunmalarla)
//
//   kbdiag --theta <tr-TR.bkt> <tr-TR.bkc> [tr-TR.bkr]
//
// ## Önceki ölçüm HATALIYDI
//
// İlk sürüm dokunmaları **tam tuş merkezine** koyuyordu — hem typo'lar hem
// doğru yazılmış kelimeler için. Bu, iki aileyi ayıran ASIL sinyali kendi
// elimle siliyordu:
//
//   - Bir typo'da parmak kaymıştır: literal'in uzamsal maliyeti YÜKSEK.
//   - Doğru yazılmış bir kelimede parmak hedefindedir: literal'in uzamsal
//     maliyeti DÜŞÜK.
//
// Her ikisini de merkeze koymak `F_spa`'yı iki tarafta da sıfırlıyor, geriye
// yalnız leksikal fark kalıyor ve elbette aileler örtüşüyordu. "θ bu ayrımı
// yapamıyor" sonucu ölçümün kendi kusuruydu.
//
// Bu sürüm gerçekçi: typo'lar simülatörle üretiliyor (parmak kayıyor, literal
// en yakın tuşlardan çıkıyor), doğru yazımlar da normal gürültüyle ama kendi
// tuşlarına basılarak.
if dargs.count >= 4, dargs[1] == "--theta" {
    let trieData = try Data(contentsOf: URL(fileURLWithPath: dargs[2]), options: .mappedIfSafe)
    let tTrie2 = try FormTrie(data: trieData)
    let cModel = try CharNGram(packData: try Data(contentsOf: URL(fileURLWithPath: dargs[3])))
    var mAuto2: MorphologyAutomaton?
    if dargs.count >= 5, let rd = try? Data(contentsOf: URL(fileURLWithPath: dargs[4])),
       let rp = try? RootPack(data: rd) { mAuto2 = MorphologyAutomaton(roots: rp.roots) }
    let lex2 = LexiconSet(formTrie: tTrie2, morphology: mAuto2)
    var chan = LiteralChannel(vocabulary: lex2, charModel: cModel)
    chan.autoCorrectsOutOfVocabulary = true      // ölçüm için kapıyı aç
    let dec2 = Decoder(layout: layout, spatial: spatial, lexicon: lex2,
                       beamWidth: Decoder.defaultBeamWidth)
    let wts = ScoreWeights()
    let sp2 = SpatialModel(layout: layout)

    /// Verilen dokunmalar ve onlardan çıkan literal için `Δ`.
    func delta(touches: [TouchSample], literal: String) -> (Double, String)? {
        guard let best = dec2.decode(touches: touches, topK: 1).first else { return nil }
        let s = chan.score(literal)
        if s.isInVocabulary || s.overflowed { return (-Double.infinity, "korumalı") }
        let chars = Array(literal)
        guard chars.count == touches.count else { return nil }
        var spatialCost = 0.0
        for (t, ch) in zip(touches, chars) {
            guard let k = layout.keyIndex(for: ch) else { return nil }
            spatialCost += sp2.negLogP(t, keyIndex: k)
        }
        let litCost = spatialCost + wts.wLex * s.lexCost + wts.wLen * Double(literal.count)
        return (litCost - best.cost, best.word)
    }

    /// Dokunmalardan literal'i çıkarır — uzantının yaptığı: en yakın tuş.
    func literalOf(_ ts: [TouchSample]) -> String {
        String(ts.compactMap { t in
            layout.nearestKey(to: t.down).map { layout.keys[$0].char }
        })
    }

    print("\n=== Δ dağılımı — GERÇEKÇİ dokunmalar ===")
    print("  (önceki ölçüm dokunmaları tuş merkezine koyup ayırt edici uzamsal")
    print("   sinyali siliyordu; bu sürüm parmak kaymasını simüle ediyor)\n")

    // Test kelimeleri — gerçek liste.
    var words: [(String, Double)] = []
    if let t = try? String(contentsOfFile: "LanguagePacks/tr-TR/wordlist.tsv", encoding: .utf8) {
        for line in t.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            let f = line.split(separator: "\t")
            guard f.count == 2, let c = Double(f[1]) else { continue }
            words.append((String(f[0]), c))
        }
        words.sort { $0.1 > $1.1 }
    }

    // A) TYPO: kullanıcı gerçek bir kelimeyi yazmak istedi, parmağı kaydı.
    var sim = TouchSimulator(layout: layout, seed: 4242)
    sim.sigmaScale = 0.55                 // dikkatsiz yazım
    sim.omissionRate = 0; sim.insertionRate = 0; sim.transpositionRate = 0

    var typoDeltas: [Double] = []
    var typoShown: [(String, String, Double, String)] = []
    for (w, _) in words.prefix(1500) where w.count >= 4 {
        guard let ts = sim.touches(for: w) else { continue }
        let lit = literalOf(ts)
        guard lit != w, lit.count == w.count else { continue }   // gerçekten typo
        guard let (d, best) = delta(touches: ts, literal: lit), d.isFinite else { continue }
        typoDeltas.append(d)
        if typoShown.count < 6 { typoShown.append((lit, w, d, best)) }
    }

    // B) DOĞRU YAZILMIŞ SÖZLÜK DIŞI: kullanıcı ne demek istediyse ona bastı.
    // Modellenen durum: "kullanıcı sözlük dışı bir kelimeyi yazdı ve DOĞRU
    // çıktı". Gürültü harfleri kaydırırsa o artık bu ailenin vakası değil
    // (kullanıcı zaten fark edip düzeltirdi) — o yüzden literal isme eşit
    // olana kadar birkaç tohum deneniyor. Gürültü ölçeği de daha düşük:
    // insanlar kendi bildikleri özel adları dikkatli yazar.
    let names = ["sencagri", "ayşenur", "zeynepcim", "mustafam", "elifnaz",
                 "berkayhan", "ecrinnaz", "kaanhan", "duygunur", "alperenn",
                 "melisnur", "yiğithan", "iremsu", "bariscan", "ozgecan",
                 "furkancan", "esraberk", "tunahann", "seherhan", "onurcan",
                 "denizhan", "kubilay", "nurgul", "serkanm", "burcunur",
                 "hakanberk", "gizemnur", "arda", "efehan", "mertcan"]
    var okDeltas: [Double] = []
    var okShown: [(String, Double, String)] = []
    for n in names {
        for seed in 0..<40 {
            var sim2 = TouchSimulator(layout: layout, seed: 999 &+ UInt64(seed))
            sim2.sigmaScale = 0.22
            sim2.omissionRate = 0; sim2.insertionRate = 0; sim2.transpositionRate = 0
            sim2.heavyTailRate = 0
            guard let ts = sim2.touches(for: n) else { continue }
            guard literalOf(ts) == n else { continue }       // doğru çıktı
            guard let (d, best) = delta(touches: ts, literal: n), d.isFinite else { continue }
            okDeltas.append(d)
            if okShown.count < 6 { okShown.append((n, d, best)) }
            break
        }
    }

    typoDeltas.sort(); okDeltas.sort()
    func pct(_ a: [Double], _ q: Double) -> Double {
        a.isEmpty ? .nan : a[min(Int(Double(a.count) * q), a.count - 1)]
    }

    print("  A) TYPO — düzeltilmeli  (\(typoDeltas.count) örnek)")
    for (lit, want, d, best) in typoShown {
        print(String(format: "     %-12@ (→%-12@) Δ = %7.2f  aday: %@",
                     lit as NSString, want as NSString, d, best as NSString))
    }
    print(String(format: "     p5 %.2f · p25 %.2f · medyan %.2f · p75 %.2f",
                 pct(typoDeltas, 0.05), pct(typoDeltas, 0.25),
                 pct(typoDeltas, 0.50), pct(typoDeltas, 0.75)))

    print("\n  B) DOĞRU YAZILMIŞ SÖZLÜK DIŞI — korunmalı  (\(okDeltas.count) örnek)")
    for (n, d, best) in okShown {
        print(String(format: "     %-12@                Δ = %7.2f  aday: %@",
                     n as NSString, d, best as NSString))
    }
    print(String(format: "     medyan %.2f · p75 %.2f · p90 %.2f · MAKS %.2f",
                 pct(okDeltas, 0.50), pct(okDeltas, 0.75),
                 pct(okDeltas, 0.90), okDeltas.last ?? .nan))

    // θ seçimi: B ailesini korumak birinci öncelik (asimetri, §5c).
    // B'nin p90'ının üstünde bir eşik seç, A'nın ne kadarını yakaladığını gör.
    let candidates = [pct(okDeltas, 0.90), pct(okDeltas, 0.95), okDeltas.last ?? 0]
    print("\n  θ adayları (B'yi koruyacak şekilde):")
    for t in candidates where t.isFinite {
        let caught = typoDeltas.filter { $0 > t }.count
        let broken = okDeltas.filter { $0 > t }.count
        print(String(format: "     θ = %6.2f → typo'ların %%%.0f'ı düzelir, doğru kelimelerin %%%.0f'ı bozulur",
                     t, 100 * Double(caught) / Double(max(typoDeltas.count, 1)),
                     100 * Double(broken) / Double(max(okDeltas.count, 1))))
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


// MARK: - Harf tekrarı: `w_ins_repeat` taraması
//
//   kbdiag --repeat <tr-TR.bkt>
//
// Plan §4.B uzatmaların "kuralla çözülmesini" istiyor. Ayrı bir kural yerine
// sözleşmenin `F_ins,k` sınıflarına üçüncü bir sınıf eklendi: fazladan dokunma
// en son emit edilen karakterin tuşuna düşüyorsa **tekrar insertion'ı**.
//
// Ağırlık elle seçilmemeli. Bu tarama geniş bir kelime kümesinde uzatma üretip
// her ağırlıkta top-1 geri kazanımını ölçüyor — ve **bozulma** tarafını da:
// çok ucuz bir insertion decoder'ın rastgele dokunma yutmasına izin verir.
if dargs.count >= 3, dargs[1] == "--repeat" {
    let td = try Data(contentsOf: URL(fileURLWithPath: dargs[2]), options: .mappedIfSafe)
    let rt = try FormTrie(data: td)
    let ls = LexiconSet(formTrie: rt, morphology: nil)

    var words: [String] = []
    if let t = try? String(contentsOfFile: "LanguagePacks/tr-TR/wordlist.tsv", encoding: .utf8) {
        for line in t.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t")
            guard f.count == 2, let c = Double(f[1]) else { continue }
            words.append(String(f[0]))
            _ = c
        }
    }
    let sample = Array(words.prefix(600)).filter { $0.count >= 3 && $0.count <= 8 }
    // Çift harfli kelimeler seyrek: 600'lük örneklemde bir avuç çıkıyor ve
    // bundan sonuç çıkarılamaz. Onları listenin tamamından ayrıca topluyoruz.
    let doubledPool = words.filter { w in
        guard w.count >= 3, w.count <= 10 else { return false }
        let c = Array(w)
        return (1..<c.count).contains { c[$0] == c[$0 - 1] }
    }.prefix(300)

    /// Kelimenin son harfini `extra` kez tekrarlayarak dokunma üretir.
    func stretched(_ w: String, extra: Int) -> [TouchSample]? {
        var chars = Array(w)
        guard let last = chars.last else { return nil }
        chars.append(contentsOf: Array(repeating: last, count: extra))
        var ts: [TouchSample] = []
        var t = 0.0
        for ch in chars {
            guard let k = layout.keyIndex(for: ch) else { return nil }
            ts.append(TouchSample(down: layout.keys[k].center, timestamp: t))
            t += 0.09                 // τ_fast'ın ÜSTÜNDE: bilerek uzatma
        }
        return ts
    }

    print("\n=== harf tekrarı: w_ins_repeat taraması ===")
    print("  uzatma dokunmaları τ_fast'ın ÜSTÜNDE (bilerek uzatma, hızlı çift basış değil)")
    // **Asıl risk**: gerçekten çift harfli kelimeler. Insertion fazla ucuzsa
    // `anne` yazımı `ane`+insertion olarak açıklanır ve kelime bozulur.
    let doubled = Array(doubledPool)
    print("  örneklem: \(sample.count) kelime · çift harfli ayrı küme: \(doubled.count)")
    print(String(format: "\n  %8@ %10@ %10@ %10@ %10@",
                 "w_rep" as NSString, "uzatma✓" as NSString,
                 "normal✓" as NSString, "çiftHarf✓" as NSString, "gürültülü✓" as NSString))

    for w in [4.5, 3.0, 2.0, 1.5, 1.0, 0.6, 0.3] {
        var weights = ScoreWeights()
        weights.wInsRepeat = w
        let dec = Decoder(layout: layout, spatial: spatial, lexicon: ls,
                          weights: weights, beamWidth: Decoder.defaultBeamWidth)

        var okStretch = 0, nStretch = 0
        var okPlain = 0, nPlain = 0
        for word in sample {
            // Uzatılmış hâli doğru kelimeye dönüyor mu?
            if let ts = stretched(word, extra: 2) {
                nStretch += 1
                if dec.decode(touches: ts, topK: 1).first?.word == word { okStretch += 1 }
            }
            // BOZULMA kontrolü: normal yazım hâlâ doğru mu?
            var ts: [TouchSample] = []
            var t = 0.0
            var ok = true
            for ch in word {
                guard let k = layout.keyIndex(for: ch) else { ok = false; break }
                ts.append(TouchSample(down: layout.keys[k].center, timestamp: t)); t += 0.15
            }
            if ok {
                nPlain += 1
                if dec.decode(touches: ts, topK: 1).first?.word == word { okPlain += 1 }
            }
        }
        var okDouble = 0, nDouble = 0
        for word in doubled {
            var ts: [TouchSample] = []
            var t = 0.0
            var ok = true
            for ch in word {
                guard let k = layout.keyIndex(for: ch) else { ok = false; break }
                ts.append(TouchSample(down: layout.keys[k].center, timestamp: t)); t += 0.15
            }
            guard ok else { continue }
            nDouble += 1
            if dec.decode(touches: ts, topK: 1).first?.word == word { okDouble += 1 }
        }

        // **Gürültülü kontrol.** Yukarıdaki iki sütun tam tuş merkezine
        // basıyor; ucuz insertion'ın asıl riski orada görünmez. Gerçek
        // parmakta kayan bir dokunma "son harfin tekrarı" gibi görünüp
        // yutulabilir.
        var okNoisy = 0, nNoisy = 0
        var sim = TouchSimulator(layout: layout, seed: 7)
        sim.sigmaScale = 0.45
        sim.omissionRate = 0; sim.insertionRate = 0; sim.transpositionRate = 0
        for word in sample.prefix(300) {
            guard let ts = sim.touches(for: word) else { continue }
            nNoisy += 1
            if dec.decode(touches: ts, topK: 1).first?.word == word { okNoisy += 1 }
        }
        let nz = 100.0 * Double(okNoisy) / Double(max(nNoisy, 1))

        let a = 100.0 * Double(okStretch) / Double(max(nStretch, 1))
        let b = 100.0 * Double(okPlain) / Double(max(nPlain, 1))
        let d = 100.0 * Double(okDouble) / Double(max(nDouble, 1))
        print(String(format: "  %8.1f %9.1f%% %9.1f%% %9.1f%% %9.1f%%", w, a, b, d, nz))
    }
    print("\n  gürültülü✓ = sigma 0.45 ile normal yazım. Bu sütun düşüyorsa")
    print("  insertion fazla ucuz demektir: kayan dokunma 'tekrar' sanılıp yutuluyor.")
}
