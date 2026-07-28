import Foundation
import KBLexicon
import KBDecoder

/// Dil paketi üreticisi. TSV (kelime<TAB>sayım) → `.bkt` binary.
///
/// (I2) sonlanma invariantı burada denetlenir (§2.5): ihlalde üretim başarısız olur.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("hata: " + msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("kullanım: packbuild <girdi.tsv> <çıktı.bkt> [maxSurfaceLen]")
    exit(2)
}
let inputPath = args[1]
let outputPath = args[2]
var maxSurfaceLen = 40
if args.count > 3 {
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
