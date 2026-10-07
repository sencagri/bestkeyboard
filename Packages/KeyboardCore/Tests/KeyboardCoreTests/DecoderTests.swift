import Testing
import Foundation
@testable import KBDecoder
import KBGeometry
import KBLexicon
import KBSpatial

/// Bir karakter dizisini, her harfin tuş merkezine dokunulmuş gibi dokunma
/// dizisine çevirir. Kanonik test vakası bu şekilde kurulur:
/// kullanıcı `l s l e m` tuşlarına basar, sistem `kalem` bulmalıdır.
func touches(_ typed: String, layout: KeyLayout, dt: Double = 0.15) -> [TouchSample] {
    var out: [TouchSample] = []
    for (i, ch) in typed.enumerated() {
        guard let k = layout.keyIndex(for: ch) else {
            fatalError("layout'ta olmayan karakter: \(ch)")
        }
        out.append(TouchSample(down: layout.keys[k].center, timestamp: Double(i) * dt))
    }
    return out
}

@Suite("Geometri")
struct GeometryTests {
    @Test("Türkçe Q satır sayıları — R3 dokuz harf")
    func rowCounts() {
        #expect(TurkishQ.row1.count == 12)
        #expect(TurkishQ.row2.count == 11)
        #expect(TurkishQ.row3.count == 9)
        #expect(TurkishQ.layout().keys.count == 32)
    }

    @Test("Türkçe Q, İngilizce QWERTY harflerini kapsar")
    func coversEnglish() {
        let l = TurkishQ.layout()
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            #expect(l.keyIndex(for: ch) != nil, "eksik harf: \(ch)")
        }
    }

    @Test("Tuşlar [0,1]² içinde ve satır içinde örtüşmüyor")
    func bounds() {
        for k in TurkishQ.layout().keys {
            #expect(k.center.x - k.width / 2 >= -1e-9)
            #expect(k.center.x + k.width / 2 <= 1 + 1e-9)
            #expect(k.center.y - k.height / 2 >= -1e-9)
            #expect(k.center.y + k.height / 2 <= 1 + 1e-9)
        }
    }

    @Test("l ile k komşu, l ile i uzak — altın vakanın geometrik temeli")
    func neighbourhood() {
        let l = TurkishQ.layout()
        func dist(_ a: Character, _ b: Character) -> Double {
            let ka = l.keys[l.keyIndex(for: a)!].center
            let kb = l.keys[l.keyIndex(for: b)!].center
            return ((ka.x - kb.x) * (ka.x - kb.x) + (ka.y - kb.y) * (ka.y - kb.y)).squareRoot()
        }
        #expect(dist("l", "k") < dist("l", "i"))
        #expect(dist("s", "a") < dist("s", "ş"))
    }
}

@Suite("Uzamsal model")
struct SpatialTests {
    @Test("Truncate edilmiş yoğunluğun [0,1]² integrali 1")
    func mass() {
        let l = TurkishQ.layout()
        let m = SpatialModel(layout: l)
        // Kenardaki ve ortadaki tuşlar — truncation en çok kenarda etkili.
        for ch in ["q", "g", "ç", "ü"] {
            let idx = l.keyIndex(for: Character(ch))!
            let mass = m.numericalMass(keyIndex: idx, grid: 500)
            #expect(abs(mass - 1.0) < 0.02, "\(ch): kütle \(mass)")
        }
    }

    @Test("Merkeze dokunma, komşu tuştan daha ucuz")
    func monotone() {
        let l = TurkishQ.layout()
        let m = SpatialModel(layout: l)
        let kIdx = l.keyIndex(for: "k")!
        let lIdx = l.keyIndex(for: "l")!
        let t = TouchSample(down: l.keys[kIdx].center)
        #expect(m.negLogP(t, keyIndex: kIdx) < m.negLogP(t, keyIndex: lIdx))
    }

    @Test("sigmaMin uygulanıyor — −log p'nin alt sınırını belirler")
    func sigmaFloor() {
        let l = TurkishQ.layout()
        let t = TouchSample(down: l.keys[0].center)

        // Klavye ortasındaki bir tuş — truncation etkisi ihmal edilebilir.
        let g = l.keyIndex(for: "g")!
        let tg = TouchSample(down: l.keys[g].center)

        var loose = SpatialModel(layout: l, sigmaMin: 0.05)
        loose.setCalibration(KeyCalibration(sigmaX: 0.001, sigmaY: 0.001), at: g)

        var tight = SpatialModel(layout: l, sigmaMin: 0.001)
        tight.setCalibration(KeyCalibration(sigmaX: 0.001, sigmaY: 0.001), at: g)

        // Yoğunluk olduğu için −log p negatif OLABİLİR (§2.4); taban bunu sınırlar.
        #expect(loose.negLogP(tg, keyIndex: g) > tight.negLogP(tg, keyIndex: g))
        // sigmaMin=0.05 için merkezdeki alt sınır: log(2π·σ²) = log(2π·0.0025) ≈ −4.15
        #expect(abs(loose.negLogP(tg, keyIndex: g) - log(2 * Double.pi * 0.05 * 0.05)) < 0.05)
        _ = t
    }
}

@Suite("Form trie")
struct TrieTests {
    @Test("Round-trip: her kelime bulunur ve ham F_lex korunur")
    func roundTrip() throws {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: TestLexicon.counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let trie = try FormTrie(bytes: bytes)
        for e in entries {
            let found = trie.lookup(e.word)
            #expect(found != nil, "bulunamadı: \(e.word)")
            #expect(abs((found ?? 0) - e.lexCost) < 1e-4,
                    "\(e.word): beklenen \(e.lexCost), bulunan \(found ?? -1)")
        }
    }

    @Test("Sözlükte olmayan kelime nil döner")
    func missing() throws {
        let (trie, _) = try TestLexicon.trie()
        #expect(trie.lookup("zzzzq") == nil)
        #expect(trie.lookup("kale") == nil)   // önek var ama terminal değil
    }

    @Test("Bozuk checksum reddedilir")
    func checksum() throws {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: TestLexicon.counts)
        var (bytes, _) = try FormTrieBuilder().build(entries: entries)
        bytes[FormTrieFormat.container.headerSize + 4] ^= 0xFF
        #expect(throws: (any Error).self) { _ = try FormTrie(bytes: bytes) }
    }

    @Test("Maliyet itme: ark deltaları negatif değil (admissible alt sınır)")
    func pushedCostsNonNegative() throws {
        let (trie, _) = try TestLexicon.trie()
        for node in 0..<UInt32(trie.nodeCount) {
            for arc in trie.arcRange(node) {
                #expect(trie.arcLexDelta(arc) >= -1e-6)
            }
            #expect(trie.nodeTermExtra(node) >= -1e-6)
        }
    }
}

@Suite("Skor sözleşmesi invariantları")
struct ContractTests {
    @Test("w_lex > 0 kısıtı")
    func lexPositivity() {
        var w = ScoreWeights()
        #expect(w.satisfiesLexPositivity)
        w.wLex = 0
        #expect(!w.satisfiesLexPositivity)
    }

    @Test("(I2) sonlanma invariantı — negatif w_len'i kısıtlar")
    func terminationInvariant() {
        var w = ScoreWeights()
        // Varsayılan ağırlıklarla, en kötü durumda (ΔF_lex_min = 0) bile sağlanmalı.
        #expect(w.satisfiesTerminationInvariant(minLexDelta: 0))
        // Aşırı negatif w_len invariantı bozar → paket üretimi reddetmeli.
        w.wLen = -10
        #expect(!w.satisfiesTerminationInvariant(minLexDelta: 0))
    }
}

@Suite("Decoder — altın vakalar")
struct GoldenTests {
    func makeDecoder(beamWidth: Int = 256) throws -> (Decoder, Oracle, [(word: String, lexCost: Double)], KeyLayout) {
        let layout = TurkishQ.layout()
        let spatial = SpatialModel(layout: layout)
        let (trie, lex) = try TestLexicon.trie()
        let w = ScoreWeights()
        let d = Decoder(layout: layout, spatial: spatial, trie: trie, weights: w, beamWidth: beamWidth)
        let o = Oracle(layout: layout, spatial: spatial, weights: w)
        return (d, o, lex, layout)
    }

    /// Kanonik vaka. `işlem`'in **hiç üretilmemesi** decoder'ın garantisi değildir —
    /// sonlu maliyetli her kelime aday uzayındadır. Decoder'ın garantisi `kalem`'in
    /// açık farkla kazanmasıdır; `işlem`'in öneri çubuğunda görünüp görünmeyeceği
    /// ayrı bir **marj politikası** kararıdır (bkz. aşağıdaki test).
    ///
    /// Ölçülen: `kalem` = −10.7, `işlem` = −4.8. Farkı yaratan `l→i` (6.39, `i`'nin
    /// ASCII tabanı yok). `s→ş` eşdeğerlik üzerinden ucuzdur ve bu **doğrudur** —
    /// Türkçede `sey`/`şey` yazımı yaygındır.
    @Test("lslem → kalem, işlem'i açık farkla yener")
    func lslemToKalem() throws {
        let (d, _, _, layout) = try makeDecoder()
        let results = d.decode(touches: touches("lslem", layout: layout), topK: 5)
        #expect(!results.isEmpty)
        #expect(results.first?.word == "kalem",
                "top-1: \(results.map { "\($0.word)=\(String(format: "%.2f", $0.cost))" })")

        let byWord = Dictionary(uniqueKeysWithValues: results.map { ($0.word, $0.cost) })
        if let kalem = byWord["kalem"], let islem = byWord["işlem"] {
            #expect(islem - kalem > 3.0,
                    "kalem ile işlem arası marj yetersiz: \(islem - kalem) nat")
        }
        // İkinci öneri olarak da görünmemeli.
        #expect(!results.prefix(2).map(\.word).contains("işlem"),
                "işlem ikinci öneri olmamalı: \(results.map(\.word))")
    }

    /// Öneri çubuğu marj politikası: kazanandan çok geride kalan adaylar gösterilmez.
    /// Bu bir **UI politikasıdır**, skor sözleşmesinin parçası değildir.
    @Test("Marj politikası, uzak adayları öneri çubuğundan eler")
    func marginPolicy() throws {
        let (d, _, _, layout) = try makeDecoder()
        let results = d.decode(touches: touches("lslem", layout: layout), topK: 5)
        guard let best = results.first else { Issue.record("sonuç yok"); return }
        let shown = results.filter { $0.cost - best.cost <= 3.0 }
        #expect(!shown.map(\.word).contains("işlem"),
                "3 nat marjıyla işlem elenmeliydi: \(shown.map(\.word))")
    }

    @Test("Doğru yazılan kelime bozulmaz")
    func exactTyping() throws {
        let (d, _, _, layout) = try makeDecoder()
        for word in ["kalem", "kitap", "insan", "zaman", "deniz"] {
            let r = d.decode(touches: touches(word, layout: layout), topK: 3)
            #expect(r.first?.word == word, "\(word) → \(r.map(\.word))")
        }
    }

    @Test("guzel → güzel (deasciification, §2.3)")
    func deasciification() throws {
        let (d, _, _, layout) = try makeDecoder()
        let r = d.decode(touches: touches("guzel", layout: layout), topK: 3)
        #expect(r.first?.word == "güzel",
                "top-1: \(r.map { "\($0.word)=\(String(format: "%.2f", $0.cost))" })")
    }

    @Test("İkiz harf: eli dokunmalarından elli çıkarılabilir (F_om_gem)")
    func gemination() throws {
        let (d, _, _, layout) = try makeDecoder()
        let r = d.decode(touches: touches("eli", layout: layout), topK: 5)
        // `eli` doğru yazım olduğu için top-1 o olmalı, ama `elli` adaylar arasında bulunmalı.
        #expect(r.first?.word == "eli")
        #expect(r.map(\.word).contains("elli"), "elli aday olmalı: \(r.map(\.word))")
    }
}

@Suite("Model eşdeğerliği — beam vs exhaustive oracle")
struct OracleEquivalenceTests {
    /// Sözleşme §5.4/1: sonlu beam genişliğinde eşitlik tamlık kanıtı değildir,
    /// bu yüzden beam genişliği leksikon boyutundan büyük tutulur (fiilen budamasız).
    @Test("Beam ve oracle aynı top-1'i ve aynı maliyeti verir")
    func equivalence() throws {
        let layout = TurkishQ.layout()
        let spatial = SpatialModel(layout: layout)
        let (trie, lex) = try TestLexicon.trie()
        let w = ScoreWeights()
        // Gerçek budamasız mod — "beamWidth çok büyük" varsayımına dayanmaz.
        // Aday budaması da kapalı: o bir ARAMA sezgiseli (§3), oracle onu
        // tanımlamıyor. Açık bırakılırsa beam ile oracle kaçınılmaz ayrışır ve
        // test model hatasını arama hatasından ayırt edemez hâle gelir.
        let d = Decoder(layout: layout, spatial: spatial, trie: trie, weights: w,
                        disablePruning: true, disableCandidatePruning: true)
        let o = Oracle(layout: layout, spatial: spatial, weights: w)

        let inputs = ["lslem", "kalem", "guzel", "eli", "kitap", "znman", "gecw", "brr"]
        for typed in inputs {
            let t = touches(typed, layout: layout)
            let beam = d.decode(touches: t, topK: 1)
            let oracle = o.best(touches: t, lexicon: lex, topK: 1)

            #expect(!beam.isEmpty, "\(typed): beam boş")
            #expect(!oracle.isEmpty, "\(typed): oracle boş")
            guard let b = beam.first, let x = oracle.first else { continue }

            #expect(b.word == x.word,
                    "\(typed): beam=\(b.word)(\(String(format: "%.3f", b.cost))) oracle=\(x.word)(\(String(format: "%.3f", x.cost)))")
            #expect(abs(b.cost - x.cost) < 1e-6,
                    "\(typed): maliyet farkı beam=\(b.cost) oracle=\(x.cost)")

            // Top-1 eşitliği yetmez: **her yüzey** için minimum maliyet eşleşmeli.
            let beamAll = Dictionary(uniqueKeysWithValues:
                d.decode(touches: t, topK: Int.max).map { ($0.word, $0.cost) })
            for entry in o.best(touches: t, lexicon: lex, topK: Int.max) {
                guard let bc = beamAll[entry.word] else {
                    Issue.record("\(typed): beam '\(entry.word)' üretmedi (oracle \(entry.cost))")
                    continue
                }
                #expect(abs(bc - entry.cost) < 1e-6,
                        "\(typed)/\(entry.word): beam=\(bc) oracle=\(entry.cost)")
            }
        }
    }

    /// Gerçek dedup güvenliği: **dedup açık vs kapalı**, ikisi de budamasız.
    /// Aynı beam genişliğini iki kez denemek dedup'ı test etmez (her ikisinde de
    /// aynı birleştirme kodu çalışır).
    @Test("Dedup güvenliği: dedup açık/kapalı aynı sonuç (budamasız)")
    func dedupSafety() throws {
        let layout = TurkishQ.layout()
        let spatial = SpatialModel(layout: layout)
        let (trie, _) = try TestLexicon.trie()
        let w = ScoreWeights()
        let withDedup = Decoder(layout: layout, spatial: spatial, trie: trie, weights: w,
                                disableDedup: false, disablePruning: true)
        let noDedup = Decoder(layout: layout, spatial: spatial, trie: trie, weights: w,
                              disableDedup: true, disablePruning: true)

        for typed in ["lslem", "guzel", "kitap", "eli"] {
            let t = touches(typed, layout: layout)
            let a = withDedup.decode(touches: t, topK: 5)
            let b = noDedup.decode(touches: t, topK: 5)
            #expect(a.map(\.word) == b.map(\.word), "\(typed): dedup sıralamayı değiştirdi")
            for (x, y) in zip(a, b) {
                #expect(abs(x.cost - y.cost) < 1e-9,
                        "\(typed)/\(x.word): dedup maliyeti değiştirdi \(x.cost) vs \(y.cost)")
            }
        }
    }

    /// §5.4/3: artımlı decode ile sıfırdan tam decode **birebir aynı** olmalı.
    /// Üç yuvalı frontier bu fazın kritik özelliği; prefix başına doğrulanır.
    @Test("Artımlı decode = tam decode (prefix başına)")
    func incrementalEquality() throws {
        let layout = TurkishQ.layout()
        let spatial = SpatialModel(layout: layout)
        let (trie, _) = try TestLexicon.trie()
        let d = Decoder(layout: layout, spatial: spatial, trie: trie, disablePruning: true)

        for typed in ["lslem", "kalemler", "guzel", "anne"] {
            let all = touches(typed, layout: layout)
            var inc = IncrementalDecoder(decoder: d)
            for k in 1...all.count {
                inc.append(all[k - 1])
                let incR = inc.results(topK: 5)
                let fullR = d.decode(touches: Array(all.prefix(k)), topK: 5)
                #expect(incR.map(\.word) == fullR.map(\.word),
                        "\(typed)[0..<\(k)]: artımlı \(incR.map(\.word)) vs tam \(fullR.map(\.word))")
                for (a, b) in zip(incR, fullR) {
                    #expect(abs(a.cost - b.cost) < 1e-12, "\(typed)[0..<\(k)]/\(a.word): maliyet farkı")
                }
            }
        }
    }

    /// TR yolu hiçbir altın vakada kazanmıyordu; ara-düğüm yerine iki-sembollü
    /// atomik girdiye geçtikten sonra ayrıca sınanmalı (§2.2, §4.1).
    @Test("Transposition: harfleri ters basılmış kelime bulunur")
    func transposition() throws {
        let layout = TurkishQ.layout()
        let spatial = SpatialModel(layout: layout)
        // Küçük ve odaklı leksikon: `kitap` ile onun harf-yer-değiştirmiş rakibi yok.
        let entries = try FormTrieBuilder.lexCosts(fromCounts: ["kitap": 1000, "kalem": 500, "masa": 300])
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        let trie = try FormTrie(bytes: bytes)
        let d = Decoder(layout: layout, spatial: spatial, trie: trie, disablePruning: true)

        // `ki` yerine `ik` basılmış: i ve k ters.
        let r = d.decode(touches: touches("iktap", layout: layout), topK: 3)
        #expect(r.first?.word == "kitap", "top-1: \(r.map { "\($0.word)=\(String(format: "%.2f", $0.cost))" })")
        // Emisyon sayısı doğru olmalı — TR iki emisyon yapar.
        #expect(r.first?.emitCount == 5)
    }
}
