import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLexicon
@testable import KBMorphology
@testable import KBDecoder

/// Çok dilli eşzamanlı kod çözme — skor sözleşmesi §5b.
///
/// Kullanıcının somut isteği: *"production da herhangi bir incident oldu mu?"*
/// gibi karışık cümleler layout değiştirmeden yazılabilmeli.
final class MultilingualTests: XCTestCase {

    private static let layout = TurkishQ.layout()
    private static let spatial = SpatialModel(layout: layout)

    private static func trie(_ counts: [String: Double]) throws -> FormTrie {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
        let (bytes, _) = try FormTrieBuilder().build(entries: entries)
        return try FormTrie(data: Data(bytes))
    }

    /// İki dil, tek layout. Türkçe = 0, İngilizce = 1.
    private static func bilingual(trOffset: Double = 0,
                                  enOffset: Double = 0) throws -> LexiconSet {
        let tr = try trie(["kalem": 900, "işlem": 1500, "kalan": 700,
                           "olduk": 200, "bir": 5000, "oldu": 3000, "mu": 2000,
                           "herhangi": 400, "it": 50])
        let en = try trie(["production": 800, "incident": 600, "deploy": 400,
                           "it": 9000, "the": 20000, "and": 15000,
                           "cache": 300, "commit": 350])
        return LexiconSet(sources: [
            .forms(tr, language: 0, offset: trOffset),
            .forms(en, language: 1, offset: enOffset),
        ])
    }

    private static func touches(_ s: String) -> [TouchSample] {
        s.enumerated().compactMap { i, ch in
            guard let k = layout.keyIndex(for: ch) else { return nil }
            return TouchSample(down: layout.keys[k].center, timestamp: Double(i) * 0.15)
        }
    }

    private func decode(_ typed: String, _ lex: LexiconSet,
                        configure: (inout Decoder) -> Void = { _ in }) -> [DecodeResult] {
        var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                        lexicon: lex, beamWidth: 128)
        configure(&d)
        return d.decode(touches: Self.touches(typed), topK: 3)
    }

    // MARK: - Her iki dil de aynı beam'de

    func testBothLanguagesAreReachableFromOneLayout() throws {
        let lex = try Self.bilingual()

        let turkish = decode("kalem", lex)
        XCTAssertEqual(turkish.first?.word, "kalem")
        XCTAssertEqual(turkish.first?.language, 0)

        let english = decode("production", lex)
        XCTAssertEqual(english.first?.word, "production")
        XCTAssertEqual(english.first?.language, 1, "İngilizce aday dil 1 etiketli olmalı")
    }

    /// Kullanıcının golden vakası. Her token bozulmadan geçmeli.
    func testCodeSwitchedSentenceSurvivesTokenByToken() throws {
        let lex = try Self.bilingual()
        for token in ["production", "herhangi", "bir", "incident", "oldu", "mu"] {
            let r = decode(token, lex)
            XCTAssertEqual(r.first?.word, token, "'\(token)' bozuldu → \(r.first?.word ?? "—")")
        }
    }

    /// `it` iki dilde de var. Dil etiketi doğru gelmezse Türkçe casing kuralı
    /// (`i→İ`) İngilizce kelimeye uygulanır ve cümle başında `İt` çıkar.
    func testHomographCarriesTheLanguageOfTheWinningSource() throws {
        let lex = try Self.bilingual()
        let r = decode("it", lex)
        XCTAssertEqual(r.first?.word, "it")
        XCTAssertEqual(r.first?.language, 1,
                       "İngilizce 'it' 9000, Türkçe 50 — İngilizce kazanmalı")
    }

    // MARK: - Dedup: iki dil aynı duruma çökmemeli

    /// Aynı yüzey iki dilde de varsa **iki ayrı aday** üretilmeli. Dil dedup
    /// anahtarında olmasaydı biri diğerini yutardı ve dil etiketi kaybolurdu.
    func testSameSurfaceInTwoLanguagesProducesDistinctStates() throws {
        let lex = try Self.bilingual()
        var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                        lexicon: lex, beamWidth: 512)
        // Dilleri eşitleyip ikisinin de hayatta kaldığını görelim.
        d.languageModel.prior = [0: 0, 1: 0]
        let all = d.decode(touches: Self.touches("it"), topK: 10)
        // `results()` yüzeye göre tekilleştiriyor, ama iki kaynak da erişilebilir
        // olmalı: kaynak indeksleri farklı.
        XCTAssertTrue(all.contains { $0.word == "it" })

        // Türkçeyi çok güçlü öncelersek kazanan değişmeli — iki durum gerçekten
        // ayrı yaşıyor demektir.
        d.languageModel.prior = [0: 0, 1: 20]
        let trWins = d.decode(touches: Self.touches("it"), topK: 3)
        XCTAssertEqual(trWins.first?.language, 0,
                       "önsel değişince kazanan dil de değişmeli")
    }

    // MARK: - Dil önseli ve geçiş cezası

    func testLanguagePriorShiftsTheWinner() throws {
        let lex = try Self.bilingual()
        var withEnglish = decode("it", lex) { $0.languageModel.prior = [0: 0, 1: 0] }
        XCTAssertEqual(withEnglish.first?.language, 1)

        withEnglish = decode("it", lex) { $0.languageModel.prior = [0: 0, 1: 15] }
        XCTAssertEqual(withEnglish.first?.language, 0, "ağır önsel dili çevirmeli")
    }

    /// `χ` rastgele dil zıplamasını bastırır: önceki kelime Türkçeyse aynı
    /// maliyetteki Türkçe aday kazanmalı.
    func testSwitchPenaltyFavoursStayingInTheSameLanguage() throws {
        let lex = try Self.bilingual()
        var w = ScoreWeights()
        w.wSwitch = 30                    // baskın olsun ki etkisi ölçülebilsin
        var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                        lexicon: lex, weights: w, beamWidth: 256)
        d.languageModel.previous = 0
        let r = d.decode(touches: Self.touches("it"), topK: 3)
        XCTAssertEqual(r.first?.language, 0, "geçiş cezası aynı dilde kalmayı ödüllendirmeli")
    }

    func testNoSwitchPenaltyOnTheFirstWord() throws {
        let lex = try Self.bilingual()
        var w = ScoreWeights()
        w.wSwitch = 30
        var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                        lexicon: lex, weights: w, beamWidth: 256)
        d.languageModel.previous = nil          // oturumun ilk kelimesi
        let r = d.decode(touches: Self.touches("it"), topK: 3)
        XCTAssertEqual(r.first?.language, 1, "ilk kelimede geçiş cezası olmamalı")
    }

    // MARK: - Gauge sabitleme (§5b.4)

    /// Referans dil offset'i 0 sabit. Her iki offset'i birlikte kaydırmak
    /// sıralamayı değiştirmemeli — değiştirseydi aynı sıralamayı veren sonsuz
    /// katsayı seti oluşurdu ve kalibrasyon tanımsız kalırdı.
    func testUniformOffsetShiftDoesNotChangeRanking() throws {
        let a = try Self.bilingual(trOffset: 0, enOffset: 0)
        let b = try Self.bilingual(trOffset: 5, enOffset: 5)
        for token in ["it", "kalem", "production"] {
            XCTAssertEqual(decode(token, a).map(\.word), decode(token, b).map(\.word),
                           "'\(token)': ortak kaydırma sıralamayı değiştirdi")
        }
    }

    func testRelativeOffsetDoesChangeRanking() throws {
        let neutral = try Self.bilingual(enOffset: 0)
        let penalised = try Self.bilingual(enOffset: 15)
        XCTAssertEqual(decode("it", neutral).first?.language, 1)
        XCTAssertEqual(decode("it", penalised).first?.language, 0,
                       "göreli offset dili çevirmeli")
    }

    // MARK: - Tek dil geriye dönük uyumluluk

    /// Çoklu dil kod yolu tek dilde de aynı sonucu vermeli — plan §5b:
    /// *"Faz 1'den itibaren aynı kod yolu, tek dilde bile."*
    func testSingleLanguageResultsAreUnchangedByTheMultiSourcePath() throws {
        let tr = try Self.trie(["kalem": 900, "işlem": 1500, "kalan": 700])
        let viaShortcut = LexiconSet(formTrie: tr, morphology: nil)
        let viaSources = LexiconSet(sources: [.forms(tr, language: 0)])

        for token in ["lslem", "kalem", "islem"] {
            let a = decode(token, viaShortcut)
            let b = decode(token, viaSources)
            XCTAssertEqual(a.map(\.word), b.map(\.word), "'\(token)' yüzeyleri ayrıştı")
            for (x, y) in zip(a, b) {
                XCTAssertEqual(x.cost, y.cost, accuracy: 1e-12, "'\(token)' maliyet ayrıştı")
            }
        }
    }

    /// Asıl vaka hâlâ çalışmalı: `lslem → kalem`, `işlem` DEĞİL.
    ///
    /// Marj ölçülüyor, sıra değil. `işlem` listede ikinci sırada durabilir —
    /// önemli olan **kazanamaması** ve farkın uzantının gösterim penceresinden
    /// (3 nat) geniş olması. "Top-3'te hiç görünmesin" demek testi ikinci dilin
    /// aday sayısını değiştirmesine karşı kırılgan yapardı.
    func testTheOriginalCaseStillHoldsWithTwoLanguagesLoaded() throws {
        let lex = try Self.bilingual()
        let r = decode("lslem", lex)
        XCTAssertEqual(r.first?.word, "kalem")

        guard let rival = r.first(where: { $0.word == "işlem" }) else { return }
        XCTAssertGreaterThan(rival.cost - r[0].cost, 3.0,
                             "kalem ile işlem arasındaki marj gösterim penceresinden dar")
    }

    /// İkinci dilin varlığı Türkçe marjı **daraltmamalı**. Daraltsaydı çoklu
    /// dil desteği tek dilli doğruluğu sessizce bozardı.
    func testAddingASecondLanguageDoesNotShrinkTheTurkishMargin() throws {
        let tr = try Self.trie(["kalem": 900, "işlem": 1500, "kalan": 700,
                                "olduk": 200, "bir": 5000, "oldu": 3000, "mu": 2000,
                                "herhangi": 400, "it": 50])
        let mono = LexiconSet(sources: [.forms(tr, language: 0)])
        let bi = try Self.bilingual()

        func margin(_ lex: LexiconSet) -> Double {
            let r = decode("lslem", lex)
            guard let best = r.first, let rival = r.first(where: { $0.word == "işlem" })
            else { return .infinity }
            return rival.cost - best.cost
        }
        XCTAssertEqual(margin(mono), margin(bi), accuracy: 1e-9,
                       "ikinci dil Türkçe adaylar arasındaki farkı değiştirmemeli")
    }

    // MARK: - Morfoloji + ikinci dil bir arada

    func testMorphologyAndSecondLanguageCoexist() throws {
        let en = try Self.trie(["production": 800, "incident": 600])
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lex = LexiconSet(sources: [
            .morphology(MorphologyAutomaton(roots: roots), language: 0),
            .forms(en, language: 1),
        ])
        XCTAssertEqual(decode("kalemler", lex).first?.word, "kalemler")
        XCTAssertEqual(decode("kalemler", lex).first?.language, 0)
        XCTAssertEqual(decode("incident", lex).first?.word, "incident")
        XCTAssertEqual(decode("incident", lex).first?.language, 1)
    }

    // MARK: - Literal kanalı iki dilde

    /// `V` iki dilin birleşimi: İngilizce bir kelime Türkçe listede yok diye
    /// "bilinmeyen" sayılmamalı, yoksa doğru yazılmış her İngilizce kelime
    /// düzeltme riski altına girerdi.
    func testVocabularyIsTheUnionOfBothLanguages() throws {
        let lex = try Self.bilingual()
        let model = try CharNGramBuilder.build(words: ["kalem", "işlem", "kalan"])
        var channel = LiteralChannel(vocabulary: lex, charModel: model)
        channel.autoCorrectsOutOfVocabulary = true

        XCTAssertTrue(channel.score("production").isInVocabulary,
                      "İngilizce kelime sözlük dışı sayılmamalı")
        XCTAssertTrue(channel.score("kalem").isInVocabulary)
        XCTAssertFalse(channel.score("qwzxjv").isInVocabulary)
    }
}

// MARK: - Codex turunda açılan boşluklar

extension MultilingualTests {

    /// `offset` **kendi katsayısını taşımaz** (§0 düz vektör). `wLang·offset`
    /// yazmak, ağırlık ayarının paket kalibrasyonunu da kaydırması demekti.
    func testOffsetIsIndependentOfTheLanguageWeight() throws {
        let lex = try Self.bilingual(enOffset: 4.0)

        func cost(wLang: Double) -> Double {
            var w = ScoreWeights()
            w.wLang = wLang
            var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                            lexicon: lex, weights: w, beamWidth: 256)
            d.languageModel.prior = [:]          // önsel sıfır → yalnız offset kalır
            return d.languageCost(ofSource: 1)   // İngilizce kaynak
        }
        XCTAssertEqual(cost(wLang: 1.0), 4.0, accuracy: 1e-12)
        XCTAssertEqual(cost(wLang: 3.0), 4.0, accuracy: 1e-12,
                       "wLang offset'i ölçeklememeli")
    }

    /// Önsel `wLang` ile ölçeklenir — offset'ten farklı olarak.
    func testPriorIsScaledByTheLanguageWeight() throws {
        let lex = try Self.bilingual()
        func cost(wLang: Double) -> Double {
            var w = ScoreWeights()
            w.wLang = wLang
            var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                            lexicon: lex, weights: w, beamWidth: 256)
            d.languageModel.prior = [1: 2.0]
            return d.languageCost(ofSource: 1)
        }
        XCTAssertEqual(cost(wLang: 1.0), 2.0, accuracy: 1e-12)
        XCTAssertEqual(cost(wLang: 3.0), 6.0, accuracy: 1e-12)
    }

    /// §7 sahipliği `(yüzey, dil)` anahtarında. Küresel "form listesi kazanır"
    /// kuralı, İngilizce listesindeki bir yüzeyin Türkçe morfoloji adayını dil
    /// terimleri karşılaştırılmadan elemesine yol açardı.
    func testCrossLanguageCollisionKeepsBothCandidates() throws {
        // `kalemler` hem İngilizce listede (uydurma) hem Türkçe morfolojide.
        let en = try Self.trie(["kalemler": 100, "production": 800])
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lex = LexiconSet(sources: [
            .morphology(MorphologyAutomaton(roots: roots), language: 0),
            .forms(en, language: 1),
        ])

        let m = lex.matches(ofSurface: "kalemler")
        XCTAssertEqual(m.count, 2, "iki dil de kabul etmeli, biri diğerini elememeli")
        XCTAssertTrue(m.contains { $0.language == 0 && !$0.isFormList })
        XCTAssertTrue(m.contains { $0.language == 1 && $0.isFormList })
    }

    /// Aynı dil içinde form listesi morfolojiyi ezer (§7 tek sahiplik).
    func testWithinOneLanguageTheFormListStillWins() throws {
        let tr = try Self.trie(["kalemler": 500])
        let roots = [Root("kalem", pos: .noun, lexCost: 99.0)]
        let lex = LexiconSet(sources: [
            .forms(tr, language: 0),
            .morphology(MorphologyAutomaton(roots: roots), language: 0),
        ])
        let m = lex.matches(ofSurface: "kalemler")
        XCTAssertEqual(m.count, 1, "aynı dilde tek bir maliyet olmalı")
        XCTAssertTrue(m[0].isFormList)
        XCTAssertEqual(m[0].lexCost, tr.lookup("kalemler")!, accuracy: 1e-9)
    }

    /// Literal kanalı ile decoder **aynı** dili seçmeli. Ham `F_lex`'te minimum
    /// almak farklı bir dil seçebilirdi — o zaman `Δ` iki farklı adayın farkı
    /// olurdu ve commit kararı anlamını yitirirdi.
    func testLiteralChannelPicksTheSameLanguageAsTheDecoder() throws {
        let lex = try Self.bilingual()
        let model = try CharNGramBuilder.build(words: ["kalem", "işlem"])

        for prior in [[UInt8: Double](), [1: 20.0], [0: 20.0]] {
            var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                            lexicon: lex, beamWidth: 256)
            d.languageModel.prior = prior

            var ch = LiteralChannel(vocabulary: lex, charModel: model)
            ch.languageModel.prior = prior
            ch.weights = d.weights

            let decoded = d.decode(touches: Self.touches("it"), topK: 1).first
            let scored = ch.score("it")
            XCTAssertEqual(decoded?.language, scored.language,
                           "önsel \(prior): decoder ve literal kanalı ayrıştı")
        }
    }

    /// Literal kanalının **tam** maliyeti decoder'ın aday maliyetiyle aynı
    /// terimleri içermeli: `w_lex·F_lex + F_lang`.
    func testLiteralTotalMatchesTheDecoderCostDecomposition() throws {
        let lex = try Self.bilingual(enOffset: 2.5)
        let model = try CharNGramBuilder.build(words: ["kalem"])
        var w = ScoreWeights()
        w.wLang = 2.0
        var ch = LiteralChannel(vocabulary: lex, charModel: model)
        ch.weights = w
        ch.languageModel.prior = [1: 1.5]

        let s = ch.score("production")
        XCTAssertTrue(s.isInVocabulary)
        XCTAssertEqual(s.language, 1)

        // Elle: w_lex·F_lex + w_lang·prior + offset  (switch yok, previous nil)
        let expected = w.wLex * s.lexCost + w.wLang * 1.5 + 2.5
        XCTAssertEqual(ch.totalLexicalCost(s), expected, accuracy: 1e-12)
    }

    /// Model **token sınırında** değişir: `IncrementalDecoder` kurulurken
    /// snapshot alır, sonraki değişiklik aktif beam'i etkilemez (§11.C.1).
    func testChangingTheLanguageModelDoesNotDisturbAnActiveToken() throws {
        let lex = try Self.bilingual()
        var d = Decoder(layout: Self.layout, spatial: Self.spatial,
                        lexicon: lex, beamWidth: 256)
        var inc = IncrementalDecoder(decoder: d)
        for t in Self.touches("it") { inc.append(t) }
        let before = inc.results(topK: 1).first

        d.languageModel.prior = [1: 50]      // decoder'ı değiştir
        let after = inc.results(topK: 1).first
        XCTAssertEqual(before?.language, after?.language,
                       "aktif token model değişiminden etkilenmemeli")

        // Yeni token yeni modeli görmeli.
        var next = IncrementalDecoder(decoder: d)
        for t in Self.touches("it") { next.append(t) }
        XCTAssertEqual(next.results(topK: 1).first?.language, 0,
                       "sonraki token güncel modeli kullanmalı")
    }

    /// Kaynak yapısal değişmezi: tam olarak bir yük, `kind` ile uyumlu.
    /// İkisi birden verilirse morfoloji düğümü trie düğümü gibi yorumlanırdı.
    func testSourceRejectsMismatchedPayload() throws {
        let tr = try Self.trie(["kalem": 900])
        // Doğru kurulumlar sorunsuz.
        _ = LexiconSet.Source.forms(tr, language: 0)
        _ = LexiconSet.Source.morphology(
            MorphologyAutomaton(roots: [Root("kalem", pos: .noun, lexCost: 4)]), language: 0)
        // Yanlış kurulum `precondition` ile ölür; burada yalnız fabrikaların
        // doğru yükü seçtiğini doğruluyoruz.
        XCTAssertNotNil(LexiconSet.Source.forms(tr).formTrie)
        XCTAssertNil(LexiconSet.Source.forms(tr).morphology)
    }
}

// MARK: - Commit edilen dilin doğruluğu

extension MultilingualTests {

    /// Commit edilen **metnin** dili kaydedilmeli, en iyi adayınki değil.
    ///
    /// Korumalı bir literal commit edilirken başka bir kelimenin dilini yazmak,
    /// sonraki token'ın geçiş cezasını yanlış dile göre hesaplatırdı.
    func testProtectedLiteralReportsItsOwnLanguageNotTheBestCandidates() throws {
        let lex = try Self.bilingual()
        let model = try CharNGramBuilder.build(words: ["kalem", "işlem"])
        var ch = LiteralChannel(vocabulary: lex, charModel: model)
        ch.weights = ScoreWeights()

        let english = ch.score("production")
        XCTAssertTrue(english.demandsProtection)
        XCTAssertEqual(english.language, 1)

        let turkish = ch.score("kalem")
        XCTAssertTrue(turkish.demandsProtection)
        XCTAssertEqual(turkish.language, 0)
    }

    /// `offset` eşleşmeyi **üreten kaynaktan** gelmeli. Aynı dilde farklı
    /// offset taşıyan iki kaynak varsa dilin "ilk" kaynağından okumak literal
    /// ve decoder maliyetlerini ayrıştırırdı.
    func testMatchCarriesTheOffsetOfItsOwnSource() throws {
        let forms = try Self.trie(["kalemler": 500])
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lex = LexiconSet(sources: [
            .morphology(MorphologyAutomaton(roots: roots), language: 0, offset: 7.0),
            .forms(forms, language: 0, offset: 1.0),
        ])
        let m = lex.matches(ofSurface: "kalemler")
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].isFormList, "aynı dilde form listesi kazanmalı")
        XCTAssertEqual(m[0].offset, 1.0, "kazanan kaynağın offset'i taşınmalı")
    }

    /// Morfoloji kazandığında da kendi offset'ini taşımalı.
    ///
    /// Aynı dilde **iki** kaynak var ve form listesi bu yüzeyi kabul etmiyor —
    /// eski `offsetFor(language:)` dilin ilk kaynağını okuduğu için form
    /// listesinin offset'ini (1.0) döndürürdü. Tek kaynaklı bir kurulum bu
    /// hatayı yakalayamazdı.
    func testMorphologyMatchCarriesItsOwnOffsetWhenFormListDoesNotMatch() throws {
        let forms = try Self.trie(["başka": 500])          // `kalemler` YOK
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lex = LexiconSet(sources: [
            .forms(forms, language: 0, offset: 1.0),        // dilin İLK kaynağı
            .morphology(MorphologyAutomaton(roots: roots), language: 0, offset: 7.0),
        ])
        let m = lex.matches(ofSurface: "kalemler")
        XCTAssertEqual(m.count, 1)
        XCTAssertFalse(m[0].isFormList)
        XCTAssertEqual(m[0].offset, 7.0,
                       "morfolojinin offset'i taşınmalı, dilin ilk kaynağınınki değil")
    }

    /// Aynı zincir `LiteralChannel` üzerinden: `Score.offset` ve
    /// `totalLexicalCost` kazanan kaynağın offset'ini kullanmalı.
    func testLiteralTotalUsesTheWinningSourcesOffset() throws {
        let forms = try Self.trie(["başka": 500])
        let roots = [Root("kalem", pos: .noun, lexCost: 4.2)]
        let lex = LexiconSet(sources: [
            .forms(forms, language: 0, offset: 1.0),
            .morphology(MorphologyAutomaton(roots: roots), language: 0, offset: 7.0),
        ])
        var ch = LiteralChannel(vocabulary: lex, charModel: try CharNGramBuilder.build(words: ["kalem"]))
        ch.weights = ScoreWeights()

        let s = ch.score("kalemler")
        XCTAssertTrue(s.isInVocabulary)
        XCTAssertEqual(s.offset, 7.0)
        XCTAssertEqual(ch.totalLexicalCost(s),
                       ch.weights.wLex * s.lexCost + 7.0, accuracy: 1e-12)
    }
}
