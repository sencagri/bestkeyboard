import Foundation
import KBLexicon
import KBMorphology
import KBDecoder
import KBGeometry
import KBAssembly
import KBToolSupport

/// Dil paketi üreticisi. TSV (kelime<TAB>sayım) → `.bkt` binary.
///
/// (I2) sonlanma invariantı burada denetlenir (§2.5): ihlalde üretim başarısız olur.

/// Kök sözlüğü TSV'sini binary pakete çevirir.
///
/// Biçim: `kök<TAB>pos<TAB>sayım<TAB>alternasyon<TAB>ünlüDüşmesi[<TAB>aorist<TAB>ettirgen]`
///
/// Son iki sütun **isteğe bağlı** ve yoksa `unknown` oluyor. Sebep: 30 bin
/// kökün tamamına sınıf yazmak tek turda mümkün değil ve yarısı yazılmış bir
/// dosya reddedilmemeli. `unknown` "üretme" demek, "tahmin et" değil.
/// Alternasyon sınıfı **sözlükseldir** — `çocuk→çocuğu` ama `renk→rengi`;
/// tek bir `k→ğ` kuralı `renği` üretirdi.
func buildRootPack(input: String, output: String) {
    guard let text = TSV.text(at: input) else { fail("kök dosyası okunamadı: \(input)") }
    var roots: [Root] = []
    var rejected: [String] = []
    var total = 0.0
    var raw: [(String, Root.POS, Double, Phonology.Alternation?, Bool, Root.AoristClass, Root.CausativeClass, String?)] = []

    // **Boş alanlar korunuyor.** Varsayılan `split` onları atıyor ve isteğe
    // bağlı sütunlar (aorist, ettirgen, okunuş) kayıyordu: yalnız okunuş
    // yazılmış bir satırda okunuş `aorist` sanılıyordu.
    for r in TSV.records(text, keepingEmptyFields: true) {
        let f = r.fields, n = r.line
        guard f.count >= 5 else { rejected.append("satır \(n): 5 alan bekleniyordu → '\(r.text)'"); continue }
        /// İsteğe bağlı sütun; yoksa boş.
        func column(_ i: Int) -> String { f.count > i ? String(f[i]) : "" }

        let surface = String(f[0])
        guard let pos = Root.POS(name: String(f[1])) else {
            rejected.append("satır \(n): bilinmeyen POS '\(f[1])'"); continue
        }
        guard let count = Double(f[2]), count.isFinite, count > 0 else {
            rejected.append("satır \(n): geçersiz sayım '\(f[2])'"); continue
        }
        guard let alt = RootPack.SourceNames.alternation[String(f[3])] else {
            rejected.append("satır \(n): bilinmeyen alternasyon '\(f[3])'"); continue
        }
        let drops = (f[4] == "1")
        guard let aorist = RootPack.SourceNames.aorist[column(5)] else {
            rejected.append("satır \(n): bilinmeyen aorist '\(f[5])'"); continue
        }
        guard let caus = RootPack.SourceNames.causative[column(6)] else {
            rejected.append("satır \(n): bilinmeyen ettirgen '\(f[6])'"); continue
        }
        let pron = column(7).isEmpty ? nil : column(7)
        total += count
        raw.append((surface, pos, count, alt, drops, aorist, caus, pron))
    }

    if !rejected.isEmpty {
        let preview = rejected.prefix(8).joined(separator: "\n  ")
        fail("\(rejected.count) geçersiz satır:\n  \(preview)")
    }
    guard !raw.isEmpty, total > 0 else { fail("hiç geçerli kök okunamadı") }

    for (surface, pos, count, alt, drops, aorist, caus, pron) in raw {
        roots.append(Root(surface, pos: pos, lexCost: -log(count / total),
                          finalAlternation: alt, dropsVowel: drops,
                          aoristClass: aorist, causativeClass: caus,
                          pronunciation: pron))
    }

    let bytes = RootPack.build(roots: roots)
    // Doğrulama ÖNCE bellekte, sonra atomik yayımlama — bozuk paket bırakma.
    guard let reread = try? RootPack(data: Data(bytes)) else { fail("üretilen paket okunamadı") }
    guard reread.roots.count == roots.count else { fail("round-trip: kök sayısı değişti") }
    for (a, b) in zip(reread.roots, roots) {
        guard String(a.surface) == String(b.surface), a.pos == b.pos,
              a.finalAlternation == b.finalAlternation, a.dropsVowel == b.dropsVowel else {
            fail("round-trip bozuk: \(String(b.surface))")
        }
    }

    publish(bytes, to: output)

    var byAlt: [String: Int] = [:]
    for r in roots { byAlt[r.finalAlternation.map { "\($0)" } ?? "none", default: 0] += 1 }
    print("""
    kök paketi üretildi: \(output)
      kök         : \(roots.count)
      boyut       : \(String(format: "%.1f", Double(bytes.count) / 1024)) KB  \
    (\(String(format: "%.1f", Double(bytes.count) / Double(roots.count))) bayt/kök)
      alternasyon : \(byAlt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
      ünlü düşen  : \(roots.filter(\.dropsVowel).count)
      round-trip  : geçti
      yayımlama   : atomik
    """)
}

/// Kelime listesinden literal kanalının karakter n-gram modelini üretir.
///
/// Model **tipler** üzerinde eğitilir, sıklıkla ağırlıklandırılmaz: modellenen
/// şey "görülmemiş bir token neye benzer" ve görülmemiş token'lar tip
/// dağılımından gelir. Sıklıkla ağırlıklandırmak modeli en sık birkaç yüz
/// kelimenin şekline bükerdi.
func buildCharNGramPack(input: String, output: String) {
    guard let text = TSV.text(at: input) else { fail("kelime dosyası okunamadı: \(input)") }

    var words: [String] = []
    for r in TSV.records(text, keepingEmptyFields: true) {
        guard let w = r.fields.first, !w.isEmpty else {
            fail("satır \(r.line): boş kelime alanı")
        }
        words.append(String(w))
    }
    guard !words.isEmpty else { fail("kelime yok: \(input)") }

    let model: CharNGram
    do { model = try CharNGramBuilder.build(words: words) }
    catch { fail("model kurulamadı: \(error)") }
    let bytes = model.packBytes()

    // Doğrulama ÖNCE bellekte, sonra atomik yayımlama.
    guard let reread = try? CharNGram(packData: Data(bytes)) else {
        fail("üretilen paket okunamadı")
    }
    guard reread.alphabet == model.alphabet else { fail("round-trip: alfabe değişti") }

    // Sözleşme kapısı: **her sonlu Unicode token'ı sonlu maliyet almalı** (§0).
    // Burada başarısız olan bir paket sevk edilirse commit kararı kilitlenir.
    let probes = ["kalem", "zzzzz", "", "192.168.1.42", "😀", "日本語",
                  String(repeating: "a", count: 500), "\u{0}\u{1}"]
    for p in probes {
        let s = reread.score(p)
        guard s.cost.isFinite, s.cost >= 0 else {
            fail("sonlu maliyet kapısı: '\(p.prefix(20))' → \(s.cost)")
        }
    }
    // Round-trip maliyet eşitliği — kuantizasyon iki tarafta da aynı olmalı.
    for p in probes where !p.isEmpty {
        guard abs(reread.score(p).cost - model.score(p).cost) < 1e-9 else {
            fail("round-trip maliyet farkı: '\(p.prefix(20))'")
        }
    }

    publish(bytes, to: output)

    // Teşhis: bilinen bir kelime ile aynı uzunlukta anlamsız bir dizi arasındaki
    // maliyet farkı modelin ayrım gücünü gösterir. Fark küçükse model işe yaramaz.
    let known = model.score("kalem").cost
    let noise = model.score("kqxwj").cost
    print("""
    karakter n-gram paketi üretildi: \(output)
      kelime tipi : \(words.count)
      alfabe      : \(model.alphabet.count) karakter (sembol \(model.alphabet.count + 2))
      tablo       : \(model.symbolCount * model.symbolCount * model.symbolCount) giriş
      boyut       : \(String(format: "%.1f", Double(bytes.count) / 1024)) KB
      ayrım gücü  : 'kalem' \(String(format: "%.2f", known)) nat · \
    'kqxwj' \(String(format: "%.2f", noise)) nat · fark \(String(format: "%.2f", noise - known))
      sonlu maliyet kapısı : geçti (\(probes.count) sonda)
      round-trip  : geçti
      yayımlama   : atomik
    """)
}

/// Kelime bigramı paketini üretir — sözleşme §2 öznitelik 13 (`F_ctx`).
///
/// ## İki girdi, **aynı korpus**
///
/// `bigram.tsv`: `ctx<TAB>w<TAB>sayım`, `unigram.tsv`: `w<TAB>sayım`. İkisi de
/// **aynı** korpustan gelmeli: paket `log P̂(w) − log P̂(w|ctx)` saklıyor ve iki
/// ayrı korpusun normalizasyonunu karıştırmak farkı anlamsız yapardı. Form
/// listesinin frekansları burada kullanılamaz — o başka bir sayım.
///
/// Yüzeyler form listesiyle **aynı kanonik biçimde** normalize ediliyor (NFC +
/// Türkçe küçük harf); aksi hâlde `Ali` bağlamı `ali` adayını hiç bulamazdı.
func buildBigramPack(bigrams: String, unigrams: String, output: String) {
    guard let uniText = TSV.text(at: unigrams) else { fail("unigram dosyası okunamadı: \(unigrams)") }
    var unigramCounts: [String: Double] = [:]
    for r in TSV.records(uniText) {
        guard case let (w, c)? = TSV.wordCount(r), c > 0 else { continue }
        unigramCounts[TurkishText.key(w), default: 0] += c
    }
    guard !unigramCounts.isEmpty else { fail("unigram sayımı yok: \(unigrams)") }

    guard let biText = TSV.text(at: bigrams) else { fail("bigram dosyası okunamadı: \(bigrams)") }
    var pairs: [BigramCount] = []
    var unknownTargets = 0
    for r in TSV.records(biText) {
        let parts = r.fields
        guard parts.count == 3, let c = Double(parts[2]), c > 0 else { continue }
        let ctx = TurkishText.key(String(parts[0]))
        let w = TurkishText.key(String(parts[1]))
        // Unigram sayımı olmayan hedef **atılıyor**: `log P̂(w)` olmadan delta
        // hesaplanamaz ve sıfır varsaymak, kelimeyi bağlamda sonsuz avantajlı
        // gösterirdi.
        guard unigramCounts[w] != nil else { unknownTargets += 1; continue }
        pairs.append(BigramCount(context: ctx, word: w, count: c))
    }
    guard !pairs.isEmpty else { fail("kullanılabilir bigram yok: \(bigrams)") }

    do {
        let (bytes, report) = try BigramPackBuilder().build(unigrams: unigramCounts,
                                                           bigrams: pairs)
        // Round-trip: yazılan paket **okunabiliyor** ve deltalar geri geliyor.
        // Bir sonda seti yeterli değil; sıralama hatası ancak aramayla görünür.
        let reread = try BigramPack(packData: Data(bytes))
        var worst = 0.0
        for p in pairs.prefix(2000) {
            guard let c = reread.id(of: p.context), let w = reread.id(of: p.word) else { continue }
            let got = reread.delta(context: c, word: w)
            // Kaydedilmemiş (seyrek) çiftler 0 döner; onlar karşılaştırılmıyor.
            if got == 0 { continue }
            worst = max(worst, abs(got - Double(Float(got))))
        }
        guard worst < 1e-4 else { fail("round-trip sapması çok büyük: \(worst)") }

        publish(bytes, to: output)

        print("""
        bigram paketi üretildi: \(output)
          yüzey       : \(report.surfaces)
          çift        : \(report.pairs)
          düşen       : \(report.droppedRare) (sayım < \(BigramPackBuilder.minPairCount))
          kırpılan    : \(report.clamped) (|F_ctx| > \(BigramPackBuilder.deltaBound))
          unigramsız  : \(unknownTargets) hedef atıldı
          boyut       : \(String(format: "%.1f", Double(bytes.count) / 1024)) KB
          round-trip  : geçti
          yayımlama   : atomik
        """)
    } catch {
        fail("\(error)")
    }
}

/// Genişletme haritasını binary pakete çevirir (plan §4.D).
func buildExpansionMap(input: String, output: String) {
    guard let text = TSV.text(at: input) else { fail("harita okunamadı: \(input)") }
    var entries: [(String, String)] = []
    // Boş alanlar korunuyor: `slm<TAB><TAB>selam` iki alan sayılıp kabul
    // edilmemeli.
    for r in TSV.records(text, keepingEmptyFields: true) {
        let f = r.fields
        guard f.count == 2, !f[0].isEmpty, !f[1].isEmpty else {
            fail("satır \(r.line): `kısaltma<TAB>açılım` bekleniyordu → '\(r.text)'")
        }
        entries.append((String(f[0]), String(f[1])))
    }
    guard !entries.isEmpty else { fail("harita boş: \(input)") }

    let map = ExpansionMap(entries: entries)
    let bytes = map.packBytes()

    // Doğrulama ÖNCE bellekte, sonra atomik yayımlama.
    guard let reread = try? ExpansionMap(packData: Data(bytes)) else {
        fail("üretilen paket okunamadı")
    }
    guard reread.count == map.count else { fail("round-trip: giriş sayısı değişti") }
    for (k, _) in entries {
        guard reread.expansions(of: k) == map.expansions(of: k) else {
            fail("round-trip bozuk: '\(k)'")
        }
    }
    // Determinizm: aynı girdi aynı binary'yi üretmeli.
    guard ExpansionMap(entries: entries).packBytes() == bytes else {
        fail("üretim deterministik değil")
    }

    publish(bytes, to: output)

    print("""
    genişletme haritası üretildi: \(output)
      kısaltma    : \(map.count)
      giriş       : \(entries.count)
      boyut       : \(bytes.count) bayt
      round-trip  : geçti
      determinizm : geçti
      yayımlama   : atomik
    """)
}

/// Doğrulanmış paketi **atomik** yayımlar (`AtomicFile`): yazma kesilirse
/// mevcut geçerli paket bozulmaz. Hedef yoksa da çalışır — yerel kopya
/// `replaceItemAt`'e güveniyordu ve ilk üretimde düşüyordu.
func publish(_ bytes: [UInt8], to path: String) {
    do { try AtomicFile.publish(Data(bytes), to: URL(fileURLWithPath: path)) }
    catch { fail("yazma başarısız: \(error)") }
}

let args = CommandLine.arguments
// --- Tam üretim planı ---
//
// `build-packs.sh` paket düzenini (klasörler, yerel adları, uzantılar) kendi
// içinde yeniden yazıyordu; `PackPaths` bir adı değiştirse betik sessizce eski
// dosyaları üretmeye devam ederdi. Plan artık burada ve düzeni `PackPaths`'ten
// alıyor; betik yalnız bunu çağırıyor.
if args.count >= 2, args[1] == "--all" {
    guard args.count <= 3 else { fail("kullanım: packbuild --all [paket-kökü]") }
    buildAll(root: args.count == 3 ? args[2] : PackPaths.root)
    exit(0)
}
if args.count == 2, args[1] == "--print-plan" {
    for step in BuildPlan.steps(root: PackPaths.root) { print(step.summary) }
    exit(0)
}

guard args.count >= 3 else {
    print("""
    kullanım:
      packbuild --all [paket-kökü]                         TÜM paketler (plan: --print-plan)
      packbuild <kelime.tsv> <çıktı.bkt> [maxSurfaceLen]   form listesi paketi
             [--informal <argo.tsv>]                        gayrıresmî katmanı birleştir
      packbuild --roots <kök.tsv> <çıktı.bkr>              kök sözlüğü paketi
      packbuild --charngram <kelime.tsv> <çıktı.bkc>       literal kanalı modeli
      packbuild --expansions <harita.tsv> <çıktı.bkx>      genişletme haritası
      packbuild --bigrams <bigram.tsv> <unigram.tsv> <çıktı.bkg>
                                                          kelime bigramı (F_ctx)
    """)
    exit(2)
}

// --- Kök sözlüğü modu ---
if args[1] == "--roots" {
    // **Tam** argüman sayısı: `>= 4` fazla konumsal argümanı ve sondaki
    // bilinmeyen bayrağı sessizce yutuyordu — form listesi modundaki katılığın
    // aynısı burada da geçerli.
    guard args.count == 4 else { fail("kullanım: packbuild --roots <kök.tsv> <çıktı.bkr>") }
    buildRootPack(input: args[2], output: args[3])
    exit(0)
}

// --- Genişletme haritası modu ---
if args[1] == "--expansions" {
    // **Tam** argüman sayısı: `>= 4` fazla konumsal argümanı ve sondaki
    // bilinmeyen bayrağı sessizce yutuyordu — form listesi modundaki katılığın
    // aynısı burada da geçerli.
    guard args.count == 4 else { fail("kullanım: packbuild --expansions <harita.tsv> <çıktı.bkx>") }
    buildExpansionMap(input: args[2], output: args[3])
    exit(0)
}

// --- Karakter n-gram modu ---
if args[1] == "--charngram" {
    // **Tam** argüman sayısı: `>= 4` fazla konumsal argümanı ve sondaki
    // bilinmeyen bayrağı sessizce yutuyordu — form listesi modundaki katılığın
    // aynısı burada da geçerli.
    guard args.count == 4 else { fail("kullanım: packbuild --charngram <kelime.tsv> <çıktı.bkc>") }
    buildCharNGramPack(input: args[2], output: args[3])
    exit(0)
}
// --- Kelime bigramı modu ---
if args[1] == "--bigrams" {
    guard args.count == 5 else {
        fail("kullanım: packbuild --bigrams <bigram.tsv> <unigram.tsv> <çıktı.bkg>")
    }
    buildBigramPack(bigrams: args[2], unigrams: args[3], output: args[4])
    exit(0)
}

// --- Form listesi modu: argümanlar TEK GEÇİŞTE ayrıştırılır ---
//
// Önceki sürüm yalnız "4. argüman `--` ile mi başlıyor" diye bakıyordu.
// Bilinmeyen bayrak sessizce yok sayılıyordu: `--informl` yazan biri (ya da
// bayrağı unutan bir betik) hatasız biçimde **gayrıresmî katmansız** paket
// üretiyordu. Tam da az önce düzelttiğimiz regresyonun geri gelme yolu buydu.
//
// Artık: bilinmeyen bayrak, eksik değer, tekrarlanan bayrak ve fazla konumsal
// argüman **hata**.
let inputPath = args[1]
let outputPath = args[2]
var maxSurfaceLen = LexiconLimits.maxSurfaceLength
var informalPath: String?
var allowInvalid = false
var sawMaxLen = false

var ai = 3
while ai < args.count {
    let a = args[ai]
    switch a {
    case "--informal":
        guard informalPath == nil else { fail("--informal iki kez verildi") }
        guard ai + 1 < args.count, !args[ai + 1].hasPrefix("--") else {
            fail("--informal bir dosya yolu ister")
        }
        informalPath = args[ai + 1]
        ai += 2
    case "--allow-invalid":
        guard !allowInvalid else { fail("--allow-invalid iki kez verildi") }
        allowInvalid = true
        ai += 1
    default:
        guard !a.hasPrefix("--") else { fail("bilinmeyen seçenek: \(a)") }
        guard !sawMaxLen else { fail("fazla konumsal argüman: \(a)") }
        guard let v = Int(a), (1...65535).contains(v) else {
            fail("maxSurfaceLen 1..65535 aralığında bir tamsayı olmalı: '\(a)'")
        }
        maxSurfaceLen = v
        sawMaxLen = true
        ai += 1
    }
}

buildFormPack(input: inputPath, output: outputPath, maxSurfaceLen: maxSurfaceLen,
              informalPath: informalPath, allowInvalid: allowInvalid)
