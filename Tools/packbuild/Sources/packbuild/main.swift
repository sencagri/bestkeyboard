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
let maxSurfaceLen = args.count > 3 ? Int(args[3]) ?? 40 : 40

guard let text = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    fail("girdi okunamadı: \(inputPath)")
}

var counts: [String: Double] = [:]
var lineNo = 0
var skipped = 0
for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
    lineNo += 1
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let parts = line.split(separator: "\t")
    guard parts.count == 2, let c = Double(parts[1]) else {
        skipped += 1
        continue
    }
    let word = String(parts[0])
    // Boşluk içeren "kelimeler" form listesine girmez — tek token olmalı.
    if word.contains(" ") { skipped += 1; continue }
    counts[word, default: 0] += c
}

guard !counts.isEmpty else { fail("hiç geçerli kelime okunamadı") }

let entries: [FormTrieBuilder.Entry]
do {
    entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
} catch {
    fail("frekans doğrulaması: \(error)")
}

// (I2): kullanılacak ağırlık profilinden türetilir.
let w = ScoreWeights()
let termination = FormTrieBuilder.TerminationInvariant(
    minOmissionCost: min(w.wOmGem, min(w.wOmInit, w.wOm)),
    wLen: w.wLen,
    wLex: w.wLex)

do {
    let (bytes, alphabet) = try FormTrieBuilder().build(
        entries: entries, maxSurfaceLen: maxSurfaceLen, termination: termination)
    try Data(bytes).write(to: URL(fileURLWithPath: outputPath))

    // Doğrulama: yazılan paket okunabilmeli ve round-trip korunmalı.
    let reread = try FormTrie(bytes: bytes)
    var worst = 0.0
    for e in entries {
        guard let got = reread.lookup(e.word) else { fail("round-trip: '\(e.word)' bulunamadı") }
        worst = max(worst, abs(got - e.lexCost))
    }
    guard worst < 1e-4 else { fail("round-trip sapması çok büyük: \(worst)") }

    let kb = Double(bytes.count) / 1024.0
    print("""
    paket üretildi: \(outputPath)
      kelime      : \(entries.count)
      alfabe      : \(alphabet.count) skaler
      düğüm       : \(reread.nodeCount)
      ark         : \(reread.arcCount)
      boyut       : \(String(format: "%.1f", kb)) KB  (\(String(format: "%.1f", Double(bytes.count) / Double(entries.count))) bayt/kelime)
      round-trip  : max sapma \(String(format: "%.2e", worst))
      atlanan satır: \(skipped)
      (I2)        : geçti
    """)
} catch {
    fail("\(error)")
}
