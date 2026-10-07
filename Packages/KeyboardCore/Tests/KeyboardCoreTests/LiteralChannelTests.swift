import XCTest
import Foundation
import KBFoundation
import KBGeometry
@testable import KBLexicon
@testable import KBDecoder
import KBMorphology

/// Skor sözleşmesi §0 — açık-vocabulary literal kanalı.
final class LiteralChannelTests: XCTestCase {

    /// Küçük ama gerçekçi bir Türkçe tip listesi. Model tipler üzerinde
    /// eğitildiği için sıklık verilmiyor.
    private static let words = [
        "kalem", "kalemler", "kitap", "kitabı", "çocuk", "çocuklar", "renk",
        "rengi", "burun", "burnu", "masa", "masalar", "ev", "evler", "gelmek",
        "geldi", "yapmak", "yaptı", "güzel", "güzeller", "işlem", "işlemler",
        "araba", "arabalar", "deniz", "denizler", "şehir", "şehirler",
        "yol", "yollar", "el", "eller", "göz", "gözler", "kapı", "kapılar",
    ]

    private static let model = try! CharNGramBuilder.build(words: words)

    /// Testlerin çoğu kanalın SKOR tarafını ölçüyor; OOV koruma kapısı ayrı
    /// testlerde. Kapı açıkken `demandsProtection` her OOV'de true döner ve
    /// ölçmek istediğimiz şeyi gizlerdi.
    private func channel(autoCorrectsOOV: Bool = true) -> LiteralChannel {
        var c = LiteralChannel(vocabulary: nil, charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = autoCorrectsOOV
        return c
    }

    // MARK: - Sonlu maliyet kapısı (§Doğrulama)

    /// **Her sonlu Unicode token'ı sonlu maliyet almalı.** Sonsuz dönen tek bir
    /// yol `Δ = cost(literal) − cost(best)`'i tanımsız bırakır ve commit kararı
    /// tam da en çok önemli olduğu yerde kilitlenir.
    func testEveryFiniteUnicodeTokenGetsFiniteCost() {
        let c = channel()
        let probes = [
            "kalem",                                  // sözlükteki bir tip
            "zzzzz",                                  // alfabede ama olmayacak dizi
            "192.168.1.42",                           // alfabe dışı karakterler
            "😀",                                     // emoji
            "👨‍👩‍👧‍👦",                                     // ZWJ grapheme cluster
            "日本語",                                   // alfabe dışı script
            "\u{0}\u{1}\u{7f}",                       // kontrol karakterleri
            "\u{301}",                                // tek başına birleştirici
            String(repeating: "a", count: 5000),      // uzunluk sınırının çok ötesi
            "aÄ±Ä±",                                   // mojibake
        ]
        for p in probes {
            let s = c.score(p)
            XCTAssertTrue(s.lexCost.isFinite, "sonsuz maliyet: \(p.debugDescription)")
            XCTAssertGreaterThanOrEqual(s.lexCost, 0, "negatif maliyet: \(p.debugDescription)")
        }
    }

    func testEmptyTokenIsFree() {
        XCTAssertEqual(channel().score("").lexCost, 0)
    }

    // MARK: - Ayrım gücü

    /// Kanal işe yaramıyorsa `θ` ayarlanamaz: Türkçeye benzeyen bir OOV kelime,
    /// tuş gürültüsünden **belirgin biçimde** ucuz olmalı.
    func testTurkishLookingOOVIsMuchCheaperThanKeyboardNoise() {
        let c = channel()
        let plausible = c.score("kalemlik").lexCost
        let noise = c.score("kqxwjf").lexCost
        XCTAssertLessThan(plausible, noise - 5,
                          "model ayrım yapmıyor: \(plausible) vs \(noise)")
    }

    /// Alfabe dışı karakterler ceza almalı, yoksa emoji dizisi "ucuz kelime"
    /// görünüp düzeltme kararını bozar.
    func testOutOfAlphabetCharactersAreCharged() {
        let c = channel()
        XCTAssertGreaterThan(c.score("ka😀em").lexCost, c.score("kalem").lexCost)
    }

    /// Uzun token'lar daha pahalı olmalı — kısaltmayı ödüllendiren bir kanal
    /// uzun ve doğru yazılmış kelimeleri sistematik olarak bozardı.
    func testCostGrowsWithLength() {
        let c = channel()
        XCTAssertLessThan(c.score("kale").lexCost, c.score("kalemlerimizden").lexCost)
    }

    // MARK: - Taşma kuralı

    func testOverflowIsFlaggedAndStillFinite() {
        let c = channel()
        let long = String(repeating: "kalem", count: 20)   // 100 karakter
        let s = c.score(long)
        XCTAssertTrue(s.overflowed)
        XCTAssertTrue(s.lexCost.isFinite)
        XCTAssertTrue(s.demandsProtection, "taşan token literal korumaya düşmeli")
    }

    func testNormalTokenDoesNotOverflow() {
        XCTAssertFalse(channel().score("kalemlerimizden").overflowed)
    }

    // MARK: - Tek sahiplik

    /// Sözlükteki bir kelime karakter n-gram kanalından maliyet **almamalı**.
    /// Alsaydı iki kez cezalandırılır ve uzun-ama-bilinen kelimeler sistematik
    /// olarak kaybederdi.
    func testInVocabularyWordSkipsTheCharacterChannelEntirely() throws {
        let trie = try Self.buildTrie(["kalem": 1000, "kitap": 500])
        var c = LiteralChannel(vocabulary: LexiconSet(formTrie: trie, morphology: nil),
                               charModel: Self.model, cUnk: 6.0)
        c.autoCorrectsOutOfVocabulary = true

        let known = c.score("kalem")
        XCTAssertTrue(known.isInVocabulary)
        XCTAssertEqual(known.lexCost, trie.lookup("kalem")!, accuracy: 1e-9,
                       "leksikal maliyetin üstüne n-gram eklenmemeli")

        let unknown = c.score("kalemlik")
        XCTAssertFalse(unknown.isInVocabulary)
        XCTAssertGreaterThan(unknown.lexCost, 0)
    }

    func testInVocabularyWordDemandsProtection() throws {
        let trie = try Self.buildTrie(["kalem": 1000])
        var c = LiteralChannel(vocabulary: LexiconSet(formTrie: trie, morphology: nil),
                               charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = true
        XCTAssertTrue(c.score("kalem").demandsProtection, "bilinen kelime bozulmamalı")
        XCTAssertFalse(c.score("kalemlik").demandsProtection)
    }

    /// `V` = form listesi **∪ morfoloji**. Yalnız listeye bakmak,
    /// `kalemlerimizden` gibi türetilmiş ama listede olmayan formları
    /// "bilinmeyen" sayardı — motoru eklerken hedeflediğimiz kelimeler tam da
    /// en çok korunması gereken yerde korumasız kalırdı.
    func testMorphologicallyDerivedFormCountsAsInVocabulary() throws {
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lexicon = LexiconSet(formTrie: nil, morphology: MorphologyAutomaton(roots: roots))
        var c = LiteralChannel(vocabulary: lexicon, charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = true

        let derived = c.score("kalemlerimizden")
        XCTAssertTrue(derived.isInVocabulary,
                      "morfolojinin ürettiği form sözlük dışı sayılmamalı")
        XCTAssertTrue(derived.demandsProtection, "doğru yazılmış türev bozulmamalı")

        // Morfolojinin de üretemediği bir dizi hâlâ n-gram kanalından geçer.
        let noise = c.score("kqxwjf")
        XCTAssertFalse(noise.isInVocabulary)
    }

    /// Tek sahiplik morfoloji tarafında da geçerli: form listesinde varsa değer
    /// **oradan** gelir, morfoloji aynı yüzeye ulaşsa bile kendi maliyetini
    /// eklemez.
    func testFormListWinsWhenBothSourcesAcceptTheSameSurface() throws {
        let trie = try Self.buildTrie(["kalem": 1000])
        let roots = [Root("kalem", pos: .noun, lexCost: 99.0)]
        let lexicon = LexiconSet(formTrie: trie, morphology: MorphologyAutomaton(roots: roots))
        let c = LiteralChannel(vocabulary: lexicon, charModel: Self.model)

        XCTAssertEqual(c.score("kalem").lexCost, trie.lookup("kalem")!, accuracy: 1e-9,
                       "form listesi öncelikli olmalı, morfoloji maliyeti eklenmemeli")
    }

    // MARK: - Kanonik yüzey kimliği (§7)

    /// Leksikal anahtar **NFC-normalize** yüzeydir. `FormTrie.lookup` kendi
    /// içinde normalize ettiği için, kanal normalize etmezse hata yalnız
    /// morfoloji ve n-gram tarafında görünürdü — yani sessizce.
    func testDecomposedAndComposedFormsScoreIdentically() throws {
        let trie = try Self.buildTrie(["çocuk": 500, "kalem": 1000])
        var c = LiteralChannel(vocabulary: LexiconSet(formTrie: trie, morphology: nil),
                               charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = true

        let composed = "çocuk"                                  // U+00E7
        let decomposed = "c\u{327}ocuk"                          // c + U+0327
        XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count)

        XCTAssertEqual(c.score(composed).lexCost, c.score(decomposed).lexCost, accuracy: 1e-9)
        XCTAssertTrue(c.score(decomposed).isInVocabulary,
                      "ayrık yazılmış aynı kelime sözlük dışı sayılmamalı")
    }

    /// Yalnız morfolojinin kabul ettiği bir türev de normalize edilmeli —
    /// bu yol form trie'nin kendi normalizasyonundan geçmiyor.
    func testDecomposedMorphologicalDerivativeIsStillInVocabulary() throws {
        let roots = [Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ)]
        let lexicon = LexiconSet(formTrie: nil, morphology: MorphologyAutomaton(roots: roots))
        var c = LiteralChannel(vocabulary: lexicon, charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = true

        let composed = "çocuklar"
        let decomposed = "c\u{327}ocuklar"
        XCTAssertTrue(c.score(composed).isInVocabulary, "önce composed çalışmalı")
        XCTAssertEqual(c.score(decomposed).lexCost, c.score(composed).lexCost, accuracy: 1e-9)
    }

    // MARK: - OOV kapısı koruması

    /// `kbdiag --theta` ölçümü: typo Δ aralığı 7.55…20.74, doğru yazılmış
    /// sözlük dışı kelimelerin Δ aralığı 2.63…17.56 — **iç içe**. Hiçbir `θ`
    /// ikisini ayıramıyor. §5c: eşik korumadan yana.
    func testOutOfVocabularyIsProtectedWhileGateIsClosed() {
        let c = channel(autoCorrectsOOV: false)
        let s = c.score("zeynepcim")
        XCTAssertFalse(s.isInVocabulary)
        XCTAssertTrue(s.protectedByOOVGate)
        XCTAssertTrue(s.demandsProtection, "kapı kapalıyken OOV değiştirilmemeli")
    }

    /// Koruma sözlükteki kelimelerin düzeltilmesini engellemez: orada `Δ` iki
    /// bilinen kelime arasında ve kanal ölçekleri ortak.
    func testProtectionDoesNotBlockInVocabularyCorrection() throws {
        let trie = try Self.buildTrie(["kalem": 1000, "kalan": 700])
        var c = LiteralChannel(vocabulary: LexiconSet(formTrie: trie, morphology: nil),
                               charModel: Self.model)
        c.autoCorrectsOutOfVocabulary = false

        // `kalan` sözlükte → korumalı (kendisi doğru bir kelime).
        XCTAssertTrue(c.score("kalan").isInVocabulary)
        // Ama koruma sebebi OOV kapısı DEĞİL — kapı açılınca da aynı kalır.
        XCTAssertFalse(c.score("kalan").protectedByOOVGate)
    }

    /// Kapı ile kalibrasyon **ayrı** koşullar: kapı elle açılsa bile karakter
    /// modeli yoksa koruma sürer, yoksa uydurma bir yedek sabitle düzeltme
    /// yapılırdı.
    func testMissingCharModelProtectsEvenWithTheGateOpen() {
        var c = LiteralChannel(vocabulary: nil, charModel: nil)
        c.autoCorrectsOutOfVocabulary = true
        XCTAssertTrue(c.score("zeynepcim").protectedByOOVGate)
        XCTAssertTrue(c.score("zeynepcim").demandsProtection)
    }

    func testGateIsOffByDefault() {
        let c = LiteralChannel(vocabulary: nil, charModel: Self.model)
        XCTAssertFalse(c.autoCorrectsOutOfVocabulary,
                       "varsayılan korumacı olmalı; kapı ölçümle açılır")
    }

    // MARK: - Builder sözleşmesi

    /// Bellek modeli ile paket okuyucu **aynı** şeyi reddetmeli; yoksa builder
    /// çalışan bir model üretip paket onu reddediyordu.
    func testEmptyTrainingSetIsRejected() {
        XCTAssertThrowsError(try CharNGramBuilder.build(words: []))
        XCTAssertThrowsError(try CharNGramBuilder.build(words: ["", "", ""]))
    }

    func testSingleCharacterAlphabetWorks() throws {
        let m = try CharNGramBuilder.build(words: ["aaa", "aa", "a"])
        XCTAssertEqual(m.alphabet.count, 1)
        XCTAssertTrue(m.score("aa").cost.isFinite)
        XCTAssertTrue(m.score("b").cost.isFinite, "alfabe dışı yine sonlu olmalı")
    }

    /// Her `(h₁,h₂)` bağlamında kuantize olasılıklar toplamı ~1 olmalı.
    /// Olmasa uzunluk yanlılığı doğar: her karakter sistematik bir sabit
    /// eklerdi ve uzun kelimeler haksız yere pahalılaşırdı.
    func testQuantizedDistributionsSumToOnePerContext() {
        let m = Self.model
        let s = m.symbolCount
        var worst = 0.0
        for h1 in 0..<s {
            for h2 in 0..<s {
                var mass = 0.0
                for c in 0..<s {
                    mass += exp(-m.negLogP(UInt16(c), UInt16(h1), UInt16(h2)))
                }
                worst = max(worst, abs(mass - 1))
            }
        }
        // Kuantizasyon çözünürlüğü ~0.001 nat; sembol başına birikince
        // %1 mertebesinde sapma beklenir, daha fazlası hata demektir.
        // Analitik sınır: en yakın değere yuvarlamada giriş başına en fazla
        // yarım kuantizasyon adımı (1/2048 nat) hata; bağıl kütle hatası bunun
        // mertebesinde kalır. %2 gibi geniş bir tolerans indeksleme ya da
        // normalizasyon hatasını gizlerdi.
        XCTAssertLessThan(worst, 0.001, "en kötü bağlamda kütle sapması: \(worst)")
    }

    // MARK: - Bozuk paket alanları

    func testZeroMaxLengthIsRejected() throws {
        var bytes = Self.model.packBytes()
        bytes[10] = 0; bytes[11] = 0
        Self.refreshChecksum(&bytes)
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes)))
    }

    func testNaNWeightIsRejected() throws {
        var bytes = Self.model.packBytes()
        let nan = Float.nan.bitPattern
        for i in 0..<4 { bytes[12 + i] = UInt8(truncatingIfNeeded: nan >> (8 * UInt32(i))) }
        Self.refreshChecksum(&bytes)
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes)))
    }

    func testNegativeWeightIsRejected() throws {
        var bytes = Self.model.packBytes()
        let neg = Float(-1).bitPattern
        for i in 0..<4 { bytes[16 + i] = UInt8(truncatingIfNeeded: neg >> (8 * UInt32(i))) }
        Self.refreshChecksum(&bytes)
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes)))
    }

    /// Başlık alanı bozulunca checksum hâlâ tutar (checksum yalnız yükü
    /// kapsıyor), yani bu testler gerçekten **alan doğrulamasını** sınıyor.
    private static func refreshChecksum(_ bytes: inout [UInt8]) {
        let h = FNV1a.hash(bytes[CharNGramPackFormat.container.headerSize...])
        for i in 0..<8 { bytes[32 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
    }

    // MARK: - Paket round-trip

    func testPackRoundTripPreservesEveryCost() throws {
        let bytes = Self.model.packBytes()
        let reread = try CharNGram(packData: Data(bytes))

        XCTAssertEqual(reread.alphabet, Self.model.alphabet)
        for w in ["kalem", "kqxwj", "😀", "", "a", String(repeating: "z", count: 60)] {
            XCTAssertEqual(reread.score(w).cost, Self.model.score(w).cost, accuracy: 1e-12,
                           "maliyet round-trip'te değişti: \(w.debugDescription)")
            XCTAssertEqual(reread.score(w).overflowed, Self.model.score(w).overflowed)
        }
    }

    func testCorruptedChecksumIsRejected() throws {
        var bytes = Self.model.packBytes()
        bytes[CharNGramPackFormat.container.headerSize + 4] ^= 0xFF
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes)))
    }

    func testTruncatedPackIsRejected() throws {
        let bytes = Self.model.packBytes()
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes.prefix(bytes.count / 2))))
    }

    func testBadMagicIsRejected() throws {
        var bytes = Self.model.packBytes()
        bytes[0] = 0
        XCTAssertThrowsError(try CharNGram(packData: Data(bytes)))
    }

    // MARK: - Model yokken

    /// Paket eksikse kanal çalışmaya devam eder ama bunu **söyler**; `θ`
    /// kalibrasyonu buna göre okunmalı.
    func testMissingModelFallsBackAndAnnouncesItself() {
        var c = LiteralChannel(vocabulary: nil, charModel: nil)
        c.autoCorrectsOutOfVocabulary = true
        XCTAssertFalse(c.isCalibrated)
        XCTAssertEqual(c.score("herhangi").lexCost, LiteralChannel.fallbackOOVCost)
        XCTAssertTrue(c.score("herhangi").lexCost.isFinite)
    }

    func testLoadedModelReportsCalibrated() {
        XCTAssertTrue(channel().isCalibrated)
    }

    // MARK: - Yardımcı

    private static func buildTrie(_ counts: [String: Double]) throws -> FormTrie {
        try TestLexicon.formTrie(counts)
    }
}

// MARK: - Dil başına karakter modeli

extension LiteralChannelTests {

    private static let englishWords = [
        "the", "and", "for", "with", "that", "this", "have", "from", "they",
        "will", "would", "there", "their", "what", "about", "which", "when",
        "make", "like", "time", "just", "know", "take", "people", "into",
        "year", "your", "good", "some", "could", "them", "than", "then",
        "look", "only", "come", "over", "think", "also", "back", "after",
    ]

    /// **Codex'in yakaladığı hata.** İkinci dilin karakter modeli üretiliyor
    /// ama yüklenmiyordu; İngilizce sözlük dışı kelimeler **Türkçe** modelle
    /// puanlanıyordu. Türkçeye göre implausible görünüp `Δ` şişiyor ve kelime
    /// düzeltiliyordu.
    func testEnglishOOVIsScoredByTheEnglishModelWhenPresent() throws {
        let tr = Self.model
        let en = try CharNGramBuilder.build(words: Self.englishWords)

        var trOnly = LiteralChannel(vocabulary: nil, charModel: tr)
        trOnly.autoCorrectsOutOfVocabulary = true
        var both = LiteralChannel(vocabulary: nil, charModels: [tr, en])
        both.autoCorrectsOutOfVocabulary = true

        // İngilizceye benzeyen ama iki listede de olmayan bir dizi.
        let word = "thinking"
        XCTAssertLessThan(both.score(word).lexCost, trOnly.score(word).lexCost,
                          "İngilizce model devredeyken maliyet düşmeli")
    }

    /// Türkçe kelimeler İngilizce modelin varlığından **zarar görmemeli**:
    /// minimum alındığı için maliyet ancak düşer.
    func testAddingAModelNeverIncreasesCost() throws {
        let tr = Self.model
        let en = try CharNGramBuilder.build(words: Self.englishWords)
        let one = LiteralChannel(vocabulary: nil, charModel: tr)
        let two = LiteralChannel(vocabulary: nil, charModels: [tr, en])

        for w in ["kalemlik", "çocuklar", "thinking", "qwzxjv"] {
            XCTAssertLessThanOrEqual(two.score(w).lexCost, one.score(w).lexCost + 1e-12, w)
        }
    }

    /// Tek model verildiğinde davranış aynen korunur.
    func testSingleModelBehaviourIsUnchanged() {
        let a = LiteralChannel(vocabulary: nil, charModel: Self.model)
        let b = LiteralChannel(vocabulary: nil, charModels: [Self.model])
        for w in ["kalem", "kqxwj", "😀"] {
            XCTAssertEqual(a.score(w).lexCost, b.score(w).lexCost, accuracy: 1e-12, w)
        }
    }

    /// Model listesi boşsa yedek sabite düşülür ve **korunur**.
    func testEmptyModelListFallsBackAndProtects() {
        var c = LiteralChannel(vocabulary: nil, charModels: [])
        c.autoCorrectsOutOfVocabulary = true
        XCTAssertFalse(c.isCalibrated)
        XCTAssertEqual(c.score("herhangi").lexCost, LiteralChannel.fallbackOOVCost)
        XCTAssertTrue(c.score("herhangi").protectedByOOVGate,
                      "kalibre model yokken otomatik düzeltme olmamalı")
    }

    /// Taşma bayrağı kazanan modelden gelir ve sonlu kalır.
    func testOverflowStillFlaggedWithMultipleModels() throws {
        let en = try CharNGramBuilder.build(words: Self.englishWords)
        let c = LiteralChannel(vocabulary: nil, charModels: [Self.model, en])
        let s = c.score(String(repeating: "a", count: 200))
        XCTAssertTrue(s.overflowed)
        XCTAssertTrue(s.lexCost.isFinite)
    }
}
