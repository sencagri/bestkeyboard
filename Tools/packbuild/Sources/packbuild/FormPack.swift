import Foundation
import KBDecoder
import KBGeometry
import KBLexicon
import KBToolSupport

/// Form listesi paketi (`.bkt`): kelime sayımları → trie; isteğe bağlı
/// gayrıresmî katman **aynı trie'ye** birleştiriliyor.
///
/// Fonksiyon olmasının sebebi `--all`: tam üretim planı bu adımı diğer
/// paketlerle birlikte, aynı süreçte koşturuyor.
func buildFormPack(input inputPath: String, output outputPath: String,
                   maxSurfaceLen: Int, informalPath: String?,
                   allowInvalid: Bool) {
    guard let text = TSV.text(at: inputPath) else { fail("girdi okunamadı: \(inputPath)") }

    var counts: [String: Double] = [:]
    var rejected: [String] = []
    for r in TSV.records(text) {
        guard case let (word, c)? = TSV.wordCount(r) else {
            rejected.append("satır \(r.line): TAB ile ayrılmış iki alan bekleniyordu → '\(r.text)'")
            continue
        }
        // Form listesi tek token tutar; çok kelimeli girdiler burada değil,
        // ileride ifade/kısayol tablosunda yerini alacak.
        if word.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) {
            rejected.append("satır \(r.line): çok kelimeli girdi → '\(word)'")
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
    if let path = informalPath {
        guard let itext = TSV.text(at: path) else { fail("gayrıresmî liste okunamadı: \(path)") }
        var informal: [String: Double] = [:]
        var collisions: [String] = []
        for r in TSV.records(itext) {
            guard case let (w, c)? = TSV.wordCount(r), c > 0 else {
                fail("gayrıresmî satır \(r.line): `form<TAB>sayım` bekleniyordu → '\(r.text)'")
            }
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
        publish(bytes, to: outputPath)

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
}
