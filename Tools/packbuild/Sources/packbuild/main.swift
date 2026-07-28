import Foundation
import KBLexicon
import KBMorphology
import KBDecoder

/// Dil paketi üreticisi. TSV (kelime<TAB>sayım) → `.bkt` binary.
///
/// (I2) sonlanma invariantı burada denetlenir (§2.5): ihlalde üretim başarısız olur.

/// Kök sözlüğü TSV'sini binary pakete çevirir.
///
/// Biçim: `kök<TAB>pos<TAB>sayım<TAB>alternasyon<TAB>ünlüDüşmesi`
/// Alternasyon sınıfı **sözlükseldir** — `çocuk→çocuğu` ama `renk→rengi`;
/// tek bir `k→ğ` kuralı `renği` üretirdi.
func buildRootPack(input: String, output: String) {
    guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
        fail("kök dosyası okunamadı: \(input)")
    }
    var roots: [Root] = []
    var rejected: [String] = []
    var total = 0.0
    var raw: [(String, Root.POS, Double, Phonology.Alternation?, Bool)] = []

    for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        let f = t.split(separator: "\t")
        guard f.count >= 5 else { rejected.append("satır \(n+1): 5 alan bekleniyordu → '\(t)'"); continue }

        let surface = String(f[0])
        guard let pos = Root.POS(name: String(f[1])) else {
            rejected.append("satır \(n+1): bilinmeyen POS '\(f[1])'"); continue
        }
        guard let count = Double(f[2]), count.isFinite, count > 0 else {
            rejected.append("satır \(n+1): geçersiz sayım '\(f[2])'"); continue
        }
        let alt: Phonology.Alternation?
        switch f[3] {
        case "none":      alt = nil
        case "pToB":      alt = .pToB
        case "cToC":      alt = .çToC
        case "tToD":      alt = .tToD
        case "kToG":      alt = .kToG
        case "kToGSoft":  alt = .kToĞ
        default: rejected.append("satır \(n+1): bilinmeyen alternasyon '\(f[3])'"); continue
        }
        let drops = (f[4] == "1")
        total += count
        raw.append((surface, pos, count, alt, drops))
    }

    if !rejected.isEmpty {
        let preview = rejected.prefix(8).joined(separator: "\n  ")
        fail("\(rejected.count) geçersiz satır:\n  \(preview)")
    }
    guard !raw.isEmpty, total > 0 else { fail("hiç geçerli kök okunamadı") }

    for (surface, pos, count, alt, drops) in raw {
        roots.append(Root(surface, pos: pos, lexCost: -log(count / total),
                          finalAlternation: alt, dropsVowel: drops))
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

    let outURL = URL(fileURLWithPath: output)
    let tmpURL = outURL.deletingLastPathComponent()
        .appendingPathComponent(".\(outURL.lastPathComponent).tmp")
    do {
        try Data(bytes).write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)
    } catch { fail("yazma başarısız: \(error)") }

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
    guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
        fail("kelime dosyası okunamadı: \(input)")
    }

    var words: [String] = []
    var lineNo = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lineNo += 1
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let w = parts.first, !w.isEmpty else {
            fail("satır \(lineNo): boş kelime alanı")
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

    let outURL = URL(fileURLWithPath: output)
    let tmpURL = outURL.deletingLastPathComponent()
        .appendingPathComponent(".\(outURL.lastPathComponent).tmp")
    do {
        try Data(bytes).write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)
    } catch { fail("yazma başarısız: \(error)") }

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

/// Genişletme haritasını binary pakete çevirir (plan §4.D).
func buildExpansionMap(input: String, output: String) {
    guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
        fail("harita okunamadı: \(input)")
    }
    var entries: [(String, String)] = []
    var lineNo = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lineNo += 1
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        let f = t.split(separator: "\t")
        guard f.count == 2, !f[0].isEmpty, !f[1].isEmpty else {
            fail("satır \(lineNo): `kısaltma<TAB>açılım` bekleniyordu → '\(t)'")
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

    let outURL = URL(fileURLWithPath: output)
    let tmpURL = outURL.deletingLastPathComponent()
        .appendingPathComponent(".\(outURL.lastPathComponent).tmp")
    do {
        try Data(bytes).write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)
    } catch { fail("yazma başarısız: \(error)") }

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

extension Root.POS {
    init?(name: String) {
        switch name {
        case "noun": self = .noun
        case "verb": self = .verb
        case "adjective", "adj": self = .adjective
        case "adverb", "adv": self = .adverb
        case "proper": self = .proper
        default: return nil
        }
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("hata: " + msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    kullanım:
      packbuild <kelime.tsv> <çıktı.bkt> [maxSurfaceLen]   form listesi paketi
             [--informal <argo.tsv>]                        gayrıresmî katmanı birleştir
      packbuild --roots <kök.tsv> <çıktı.bkr>              kök sözlüğü paketi
      packbuild --charngram <kelime.tsv> <çıktı.bkc>       literal kanalı modeli
      packbuild --expansions <harita.tsv> <çıktı.bkx>      genişletme haritası
    """)
    exit(2)
}

// --- Kök sözlüğü modu ---
if args[1] == "--roots" {
    guard args.count >= 4 else { fail("kullanım: packbuild --roots <kök.tsv> <çıktı.bkr>") }
    buildRootPack(input: args[2], output: args[3])
    exit(0)
}

// --- Genişletme haritası modu ---
if args[1] == "--expansions" {
    guard args.count >= 4 else { fail("kullanım: packbuild --expansions <harita.tsv> <çıktı.bkx>") }
    buildExpansionMap(input: args[2], output: args[3])
    exit(0)
}

// --- Karakter n-gram modu ---
if args[1] == "--charngram" {
    guard args.count >= 4 else { fail("kullanım: packbuild --charngram <kelime.tsv> <çıktı.bkc>") }
    buildCharNGramPack(input: args[2], output: args[3])
    exit(0)
}
let inputPath = args[1]
let outputPath = args[2]
var maxSurfaceLen = 40
// 4. konumsal argüman opsiyonel; bayrakla karıştırılmamalı.
if args.count > 3, !args[3].hasPrefix("--") {
    guard let v = Int(args[3]), (1...65535).contains(v) else {
        fail("maxSurfaceLen 1..65535 aralığında bir tamsayı olmalı: '\(args[3])'")
    }
    maxSurfaceLen = v
}

guard let text = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    fail("girdi okunamadı: \(inputPath)")
}

var counts: [String: Double] = [:]
var lineNo = 0
var rejected: [String] = []
let allowInvalid = args.contains("--allow-invalid")
for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
    lineNo += 1
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let parts = line.split(separator: "\t")
    guard parts.count == 2, let c = Double(parts[1]) else {
        rejected.append("satır \(lineNo): TAB ile ayrılmış iki alan bekleniyordu → '\(line)'")
        continue
    }
    let word = String(parts[0])
    // Form listesi tek token tutar; çok kelimeli girdiler burada değil,
    // ileride ifade/kısayol tablosunda yerini alacak.
    if word.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) {
        rejected.append("satır \(lineNo): çok kelimeli girdi → '\(word)'")
        continue
    }
    counts[word, default: 0] += c
}

guard !counts.isEmpty else { fail("hiç geçerli kelime okunamadı") }

// --- Gayrıresmî katmanın birleştirilmesi (plan §4.B) ---
//
// Argo/kısaltma listesi ayrı bir DOSYADA duruyor (yazım kolaylığı ve lisans
// ayrımı için) ama pakete **tek trie** olarak giriyor.
//
// Ayrı bir kaynak olarak yüklemek §7'yi ihlal ediyordu: aynı yüzey iki
// trie'de bulunduğunda decoder ucuz olanı seçiyor, oysa iki liste **farklı
// toplamlara göre** normalize edilmiş ve maliyetleri karşılaştırılabilir
// değil. Sözleşme her `(yüzey, dil)` için TEK bir `F_lex` istiyor.
//
// Çakışma **derleme hatası**: sessizce birini seçmek, hangi frekansın
// kullanıldığını belirsiz bırakırdı. Zaten resmî listede olan bir form
// gayrıresmî listede durmamalı — orada olması gereken tek şey resmî listenin
// kapsamadığı formlar.
if let i = args.firstIndex(of: "--informal"), i + 1 < args.count {
    let path = args[i + 1]
    guard let itext = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("gayrıresmî liste okunamadı: \(path)")
    }
    var informal: [String: Double] = [:]
    var collisions: [String] = []
    var iLine = 0
    for raw in itext.split(separator: "\n", omittingEmptySubsequences: false) {
        iLine += 1
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let f = line.split(separator: "\t")
        guard f.count == 2, let c = Double(f[1]), c > 0 else {
            fail("gayrıresmî satır \(iLine): `form<TAB>sayım` bekleniyordu → '\(line)'")
        }
        let w = String(f[0])
        if counts[w] != nil { collisions.append(w); continue }
        informal[w, default: 0] += c
    }
    if !collisions.isEmpty {
        fail("""
        \(collisions.count) form resmî listede ZATEN var — gayrıresmî listeden çıkarın.
        Aynı yüzeyin iki kaynakta olması §7 tek sahiplik kuralını ihlal eder ve
        hangi frekansın kullanıldığını belirsiz bırakır:
          \(collisions.prefix(20).joined(separator: " "))
        """)
    }
    guard !informal.isEmpty else { fail("gayrıresmî listede yeni form yok: \(path)") }
    for (w, c) in informal { counts[w] = c }
    print("gayrıresmî katman birleştirildi: \(informal.count) yeni form")
}

// Üretim aracı varsayılan olarak fail-fast: sessizce atılan satır, sessizce
// eksik paket demektir. Tolerans açıkça istenmeli.
if !rejected.isEmpty {
    let preview = rejected.prefix(10).joined(separator: "\n  ")
    if allowInvalid {
        print("uyarı: \(rejected.count) satır atlandı:\n  \(preview)")
    } else {
        fail("\(rejected.count) geçersiz satır (--allow-invalid ile yok sayabilirsin):\n  \(preview)")
    }
}

let entries: [FormTrieBuilder.Entry]
do {
    entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
} catch {
    fail("frekans doğrulaması: \(error)")
}

// (I2) ve w_lex > 0, kullanılacak ağırlık profilinden türetilir.
//
// UYARI: profil şu an koddaki yerleşik varsayılan. Ağırlıklar gerçek veriyle
// fit edildiğinde bu, sürümlenmiş bir profil dosyasından okunmalı ve profil
// kimliği paket manifestine yazılmalı — aksi halde araç "I2 geçti" derken
// çalışma anındaki farklı profil invariantı ihlal edebilir.
let w = ScoreWeights()
guard w.satisfiesLexPositivity else { fail("w_lex > 0 kısıtı ihlal edildi (§7.1)") }
let termination = FormTrieBuilder.TerminationInvariant(
    minOmissionCost: min(w.wOmGem, min(w.wOmInit, w.wOm)),
    wLen: w.wLen,
    wLex: w.wLex)

do {
    let (bytes, alphabet) = try FormTrieBuilder().build(
        entries: entries, maxSurfaceLen: maxSurfaceLen, termination: termination)

    // ÖNCE bellekte tüm doğrulamalar, SONRA atomik yayımlama.
    // Doğrudan hedefe yazmak, doğrulama başarısız olursa bozuk paket bırakır
    // ve yazma kesilirse mevcut geçerli paketi de yok eder.
    let reread = try FormTrie(bytes: bytes)
    var worst = 0.0
    for e in entries {
        guard let got = reread.lookup(e.word) else { fail("round-trip: '\(e.word)' bulunamadı") }
        worst = max(worst, abs(got - e.lexCost))
    }
    guard worst < 1e-4 else { fail("round-trip sapması çok büyük: \(worst)") }

    // Atomik yayımlama: aynı dizinde geçici dosya + rename.
    let outURL = URL(fileURLWithPath: outputPath)
    let tmpURL = outURL.deletingLastPathComponent()
        .appendingPathComponent(".\(outURL.lastPathComponent).tmp")
    try Data(bytes).write(to: tmpURL, options: .atomic)
    _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)

    let kb = Double(bytes.count) / 1024.0
    print("""
    paket üretildi: \(outputPath)
      kelime      : \(entries.count)
      alfabe      : \(alphabet.count) skaler
      düğüm       : \(reread.nodeCount)
      ark         : \(reread.arcCount)
      boyut       : \(String(format: "%.1f", kb)) KB  (\(String(format: "%.1f", Double(bytes.count) / Double(entries.count))) bayt/kelime)
      round-trip  : max sapma \(String(format: "%.2e", worst))
      ağırlık profili: yerleşik ScoreWeights (w_lex=\(w.wLex), w_len=\(w.wLen))
      (I2)        : geçti
      yayımlama   : atomik (geçici dosya + rename)
    """)
} catch {
    fail("\(error)")
}
