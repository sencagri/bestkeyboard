import XCTest
import Foundation
import KBGeometry
import KBSpatial
@testable import KBLexicon
@testable import KBDecoder
@testable import KBRuntime
@testable import KBSessions

/// Kelime bigramı — sözleşme §2 öznitelik 13 (`F_ctx`).
///
/// Üç kapı ayrı ayrı tutuluyor: paketin kendisi (bayt formatı + arama),
/// terminal terimin decoder'a girişi, ve `Δ`'nın iki tarafının **aynı** terimi
/// taşıması.
final class BigramTests: XCTestCase {

    private let layout = TurkishQ.layout()

    /// `ve kalem` bol, `ve işlem` yok — bağlam `kalem`'i ucuzlatmalı.
    private func pack(minCount: Double = 5) throws -> BigramPack {
        let unigrams = ["kalem": 900.0, "işlem": 1500, "ve": 20000, "bir": 15000]
        let bigrams = [
            BigramCount(context: "ve", word: "kalem", count: 400),
            BigramCount(context: "ve", word: "işlem", count: minCount),
            BigramCount(context: "bir", word: "kalem", count: 50),
        ]
        let (bytes, _) = try BigramPackBuilder().build(unigrams: unigrams,
                                                       bigrams: bigrams)
        return try BigramPack(packData: Data(bytes))
    }

    // MARK: - Paket

    func testRoundTripAndLookup() throws {
        let p = try pack()
        XCTAssertEqual(p.surfaceCount, 4, "bağlam ve hedef yüzeylerin birleşimi")
        // `ve kalem` beklenenden **daha sık** → delta negatif (ucuzlatıyor).
        XCTAssertLessThan(p.delta(context: "ve", word: "kalem"), 0)
        // `ve işlem` beklenenden nadir → delta pozitif.
        XCTAssertGreaterThan(p.delta(context: "ve", word: "işlem"), 0)
    }

    /// Kayıtlı olmayan çift **0** — kanıtın yokluğu ceza değil (§5c).
    func testUnseenPairIsNeutral() throws {
        let p = try pack()
        XCTAssertEqual(p.delta(context: "bir", word: "işlem"), 0)
        XCTAssertEqual(p.delta(context: "yok", word: "kalem"), 0)
        XCTAssertEqual(p.delta(context: "ve", word: "yok"), 0)
    }

    /// Yüzey tablosu ikili aramayla sorgulanıyor; sırasız bir tablo sessizce
    /// **yanlış kelimeyi** bulurdu. Her yüzey kendi kimliğini bulmalı.
    func testEverySurfaceResolvesToItsOwnIdentity() throws {
        let p = try pack()
        for i in 0..<p.surfaceCount {
            let s = try XCTUnwrap(p.surface(i))
            XCTAssertEqual(p.id(of: s), UInt32(i), "'\(s)' kendi kimliğini bulmalı")
        }
    }

    /// Türkçe yüzeyler çok baytlı; sıralama **UTF-8 bayt sırasına** göre ve
    /// arama da öyle. İkisi ayrışırsa `şey` gibi kelimeler bulunamaz.
    func testMultibyteSurfacesResolve() throws {
        let unigrams = ["şey": 100.0, "çok": 200, "güzel": 300, "ağaç": 50, "iş": 80]
        let bigrams = [
            BigramCount(context: "çok", word: "güzel", count: 40),
            BigramCount(context: "şey", word: "ağaç", count: 10),
            BigramCount(context: "iş", word: "güzel", count: 5),
        ]
        let (bytes, _) = try BigramPackBuilder().build(unigrams: unigrams, bigrams: bigrams)
        let p = try BigramPack(packData: Data(bytes))
        for i in 0..<p.surfaceCount {
            let s = try XCTUnwrap(p.surface(i))
            XCTAssertEqual(p.id(of: s), UInt32(i))
        }
        XCTAssertNotEqual(p.delta(context: "çok", word: "güzel"), 0)
    }

    /// Bozuk paket **reddediliyor**: checksum'ı geçen ama yapısı bozuk bir
    /// dosya sıcak yolda yanlış bağlam üretirdi.
    func testCorruptPackIsRejected() throws {
        let (bytes, _) = try BigramPackBuilder().build(
            unigrams: ["a": 1.0, "b": 1], bigrams: [BigramCount(context: "a", word: "b", count: 2)])
        var broken = bytes
        broken[broken.count - 1] ^= 0xFF
        XCTAssertThrowsError(try BigramPack(packData: Data(broken)))
    }

    /// Seyrek çift **pakete girmiyor**: tek gözlemin log-oranı korpus
    /// büyüklüğü kadar sapabilir ve o değer veriden değil kazadan gelir.
    func testRarePairsAreDropped() throws {
        let (_, report) = try BigramPackBuilder().build(
            unigrams: ["a": 10.0, "b": 10],
            bigrams: [BigramCount(context: "a", word: "b", count: 1)])
        XCTAssertEqual(report.pairs, 0)
        XCTAssertEqual(report.droppedRare, 1)
    }

    /// Sınıra dayanan çiftler **raporlanıyor** — sessizce kırpmak veriyi
    /// modelmiş gibi göstermek olurdu.
    func testClampingIsReported() throws {
        // `b`, `a`'dan sonra neredeyse kesin; tek başına ise çok nadir.
        let (_, report) = try BigramPackBuilder().build(
            unigrams: ["a": 1_000_000.0, "b": 2, "c": 1_000_000],
            bigrams: [BigramCount(context: "a", word: "b", count: 1000)])
        XCTAssertEqual(report.pairs, 1)
        XCTAssertEqual(report.clamped, 1)
    }

    // MARK: - Decoder

    private func decoder(_ counts: [String: Double], bigrams: BigramPack?) throws -> Decoder {
        try TestLexicon.decoder(counts, layout: layout, bigrams: bigrams)
    }

    private func touches(_ word: String) -> [TouchSample] {
        word.compactMap { ch in
            layout.keyIndex(for: ch).map {
                TouchSample(down: layout.keys[$0].center, timestamp: 0)
            }
        }
    }

    /// Paket yokken **hiçbir şey değişmiyor**: `F_ctx ≡ 0` ve motor bugünkü
    /// davranışını birebir koruyor. Özellik kendi verisi gelene kadar kapalı.
    func testNoPackMeansIdenticalCosts() throws {
        let counts = ["kalem": 900.0, "işlem": 1500]
        let plain = try decoder(counts, bigrams: nil)
        var withPack = try decoder(counts, bigrams: try pack())
        withPack.contextWord = nil          // bağlam yok → terim yok

        let t = touches("kalem")
        let a = plain.decode(touches: t, topK: 3)
        let b = withPack.decode(touches: t, topK: 3)
        XCTAssertEqual(a.map(\.word), b.map(\.word))
        for (x, y) in zip(a, b) { XCTAssertEqual(x.cost, y.cost, accuracy: 1e-12) }
    }

    /// Bağlam terimi **aday maliyetine** giriyor ve tam olarak `w_ctx · F_ctx`
    /// kadar. Başka bir yere sızıyorsa fark tutmaz.
    func testContextShiftsCandidateCostByExactlyTheTerm() throws {
        let counts = ["kalem": 900.0, "işlem": 1500]
        let p = try pack()
        var d = try decoder(counts, bigrams: p)
        let t = touches("kalem")

        let without = d.decode(touches: t, topK: 3).first { $0.word == "kalem" }
        d.contextWord = "ve"
        let with = d.decode(touches: t, topK: 3).first { $0.word == "kalem" }

        let expected = d.weights.wCtx * p.delta(context: "ve", word: "kalem")
        let withCost = try XCTUnwrap(with).cost
        let withoutCost = try XCTUnwrap(without).cost
        XCTAssertEqual(withCost - withoutCost, expected, accuracy: 1e-9)
        XCTAssertLessThan(expected, 0, "bu bağlamda kelime ucuzlamalı")
    }

    /// Bağlam **sıralamayı çevirebilmeli** — özelliğin varlık sebebi bu.
    ///
    /// Test hangi kelimenin bağlamsız kazandığını **varsaymıyor**: kazananı
    /// ölçüp ikinciye bağlam avantajı veriyor. Sabit bir çift seçmek, leksikon
    /// ya da uzamsal model değiştiğinde testi sessizce anlamsızlaştırırdı.
    func testContextCanReorderCandidates() throws {
        // Son dokunma `m` ile `n`'in **tam ortasında**: iki yüzeyin uzamsal
        // terimi eşit, aralarındaki tek fark `F_lex`. Böylece boşluk
        // kontrollü ve `deltaBound`'un altında kalıyor — aksi hâlde test
        // "bağlam çeviremedi" değil "boşluk çok büyüktü" derdi.
        let counts = ["kalem": 900.0, "kalen": 330]
        let mid = layout.keys[layout.keyIndex(for: "m")!].center
        let n = layout.keys[layout.keyIndex(for: "n")!].center
        let t = touches("kale") + [TouchSample(
            down: Point(x: (mid.x + n.x) / 2, y: (mid.y + n.y) / 2), timestamp: 0)]

        let plain = try decoder(counts, bigrams: nil)
        let ranked = plain.decode(touches: t, topK: 2)
        let first = try XCTUnwrap(ranked.first)
        let second = try XCTUnwrap(ranked.dropFirst().first)
        let winner = first.word
        let runnerUp = second.word
        let gap = second.cost - first.cost
        XCTAssertLessThan(gap, BigramPackBuilder.deltaBound,
                          "kurgu bozuk: boşluk tek bir bağlam teriminden büyük")

        // İkinciyi bağlamda **beklenenden çok daha sık** yapıyoruz; kazananın
        // bağlamla ilgili bir kaydı yok, yani onun terimi 0 kalıyor.
        let unigrams = counts.merging(["ve": 20000.0]) { a, _ in a }
        let bigrams = [BigramCount(context: "ve", word: runnerUp, count: 19000)]
        let (bytes, _) = try BigramPackBuilder().build(unigrams: unigrams, bigrams: bigrams)
        let p = try BigramPack(packData: Data(bytes))

        var d = try decoder(counts, bigrams: p)
        d.contextWord = "ve"
        let after = d.decode(touches: t, topK: 2)

        XCTAssertLessThan(p.delta(context: "ve", word: runnerUp), 0)
        XCTAssertEqual(after.first?.word, runnerUp,
                       "bağlam sıralamayı çevirmeliydi (bağlamsız kazanan: \(winner))")
    }

    /// Bağlam **prefix-causal** (§3): token ortasında değişmesi aktif beam'i
    /// etkilemiyor. `IncrementalDecoder` kurulurken snapshot alınıyor.
    func testContextIsSnapshottedAtTokenStart() throws {
        let counts = ["kalem": 900.0, "işlem": 1500]
        var d = try decoder(counts, bigrams: try pack())
        d.contextWord = nil
        var inc = IncrementalDecoder(decoder: d)
        for t in touches("kalem") { inc.append(t) }
        let costBefore = inc.results(topK: 1).first?.cost

        // Decoder bir **değer tipi**: `inc` kendi kopyasını taşıyor.
        d.contextWord = "ve"
        XCTAssertEqual(inc.results(topK: 1).first?.cost, costBefore,
                       "token ortasında bağlam değişmemeli")
    }

    /// Oracle da aynı terimi taşımalı; taşımazsa §5.4/1 eşdeğerlik kapısı
    /// `F_ctx` eklendiği anda kırılır ve fark "beam yanlış" diye okunur.
    func testOracleCarriesTheSameTerminalTerm() throws {
        let counts = ["kalem": 900.0, "işlem": 1500]
        let p = try pack()
        let lex = try TestLexicon.trie(counts).1

        var d = try decoder(counts, bigrams: p)
        d.contextWord = "ve"
        var oracle = Oracle(layout: layout, spatial: SpatialModel(layout: layout),
                            weights: d.weights, bigrams: p, contextWord: "ve")

        let t = touches("kalem")
        let fromBeam = try XCTUnwrap(d.decode(touches: t, topK: 3)
            .first { $0.word == "kalem" })
        let fromOracle = try XCTUnwrap(oracle.best(touches: t, lexicon: lex, topK: 3)
            .first { $0.word == "kalem" })
        // Tolerans §5.4 eşdeğerlik kapısıyla **aynı** (1e-6): paketteki `F_lex`
        // deltaları f32, oracle ise tam hassasiyetli `lexCost` kullanıyor.
        // Daha dar bir tolerans bu bilinen farkı `F_ctx` hatası gibi gösterirdi.
        XCTAssertEqual(fromBeam.cost, fromOracle.cost, accuracy: 1e-6)

        // Kontrol: oracle terimi taşımasaydı fark tam olarak o terim kadardı.
        oracle.contextWord = nil
        let unaware = try XCTUnwrap(oracle.best(touches: t, lexicon: lex, topK: 3)
            .first { $0.word == "kalem" })
        XCTAssertEqual(unaware.cost - fromOracle.cost,
                       -d.weights.wCtx * p.delta(context: "ve", word: "kalem"),
                       accuracy: 1e-9)
    }

    // MARK: - `Δ`'nın iki tarafı

    /// Literal kanalı **aynı** terimi taşımalı. Yalnız decoder tarafına
    /// eklemek, `Δ = cost(literal) − cost(best)`'i bağlam gücü kadar şişirir —
    /// yani `θ` eşiği sessizce düşmüş olurdu.
    func testLiteralChannelCarriesTheContextTerm() throws {
        let counts = ["kalem": 900.0, "işlem": 1500]
        let lex = try TestLexicon.lexicon(counts)
        let p = try pack()

        var channel = LiteralChannel(vocabulary: lex, charModels: [])
        channel.bigrams = p
        let score = channel.score("kalem")

        let neutral = channel.totalLexicalCost(score, token: "kalem")
        channel.contextWord = "ve"
        let contextual = channel.totalLexicalCost(score, token: "kalem")
        XCTAssertEqual(contextual - neutral,
                       channel.weights.wCtx * p.delta(context: "ve", word: "kalem"),
                       accuracy: 1e-9)

        // Yüzey verilmezse terim uygulanmıyor: `Score` yüzeyi taşımıyor ve
        // bağlamsız çağrı yerleri aynı sayıyı almaya devam etmeli.
        XCTAssertEqual(channel.totalLexicalCost(score), neutral, accuracy: 1e-12)
    }

    // MARK: - Bağlamın yaşam döngüsü

    /// Yalnız sona yazan belge — replay'in kullandığı tampon.
    private typealias Doc = RecordingTestSupport.Doc

    private func coordinator() throws -> InputCoordinator {
        try TestLexicon.coordinator(layout: layout, bigrams: try pack())
    }

    private func type(_ word: String, _ c: inout InputCoordinator, _ doc: Doc) {
        for ch in word {
            guard let k = layout.keyIndex(for: ch) else { continue }
            c.insertLetter(ch, touch: TouchSample(down: layout.keys[k].center,
                                                  timestamp: 0), into: doc)
        }
    }

    /// Kapanan token bir sonrakinin bağlamı olur.
    func testCommittedWordBecomesTheContext() throws {
        var c = try coordinator()
        let doc = Doc()
        type("ve", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.engine?.decoder.contextWord, "ve")
        XCTAssertEqual(c.engine?.literalChannel.contextWord, "ve",
                       "kanal ve decoder aynı bağlamı görmeli")
    }

    /// Cümle sonlandırıcı bağlamı **kesiyor**: `.`'dan sonraki kelime
    /// öncekinin devamı değil.
    func testSentenceEndingPunctuationClearsTheContext() throws {
        var c = try coordinator()
        let doc = Doc()
        type("ve", &c, doc)
        c.space(into: doc)
        type("kalem", &c, doc)
        c.insertSymbol(".", into: doc)
        XCTAssertNil(c.engine?.decoder.contextWord)
    }

    /// Virgül kesmiyor — orada cümle sürüyor.
    func testCommaKeepsTheContext() throws {
        var c = try coordinator()
        let doc = Doc()
        type("kalem", &c, doc)
        c.insertSymbol(",", into: doc)
        XCTAssertEqual(c.engine?.decoder.contextWord, "kalem")
    }

    /// Art arda boşluk bağlamı düşürmüyor: boş token, önceki kelimenin bağlam
    /// olmaktan çıkması demek değil.
    func testEmptyTokenKeepsTheContext() throws {
        var c = try coordinator()
        let doc = Doc()
        type("ve", &c, doc)
        c.space(into: doc)
        c.space(into: doc)
        XCTAssertEqual(c.engine?.decoder.contextWord, "ve")
    }

    /// İmleç oynadıysa bağlam **bilinmiyor**a düşüyor: önündeki kelime artık
    /// bizim kapattığımız token olmayabilir.
    func testCursorMovementClearsTheContext() throws {
        var c = try coordinator()
        let doc = Doc()
        type("ve", &c, doc)
        c.space(into: doc)
        c.handleSelection(nil, into: doc)
        XCTAssertNil(c.engine?.decoder.contextWord)
    }

    /// Büyük harfli commit küçük harfe kanonikleşiyor: paket küçük harfli
    /// yüzeyler taşıyor ve `Ve` ile `ve` aynı bağlam.
    func testContextIsCanonicalized() throws {
        var c = try coordinator()
        let doc = Doc()
        c.insertUppercaseLetter("v", uppercase: "V",
                                touch: TouchSample(
                                    down: layout.keys[layout.keyIndex(for: "v")!].center,
                                    timestamp: 0), into: doc)
        type("e", &c, doc)
        c.space(into: doc)
        XCTAssertEqual(c.engine?.decoder.contextWord, "ve")
    }

    /// Kalibrasyon uygulanınca decoder yeniden kuruluyor; bigram paketi ve
    /// bağlam **taşınmalı**, yoksa her kalibrasyon `F_ctx`'i sessizce kapatır.
    func testRebuildingTheDecoderKeepsTheBigramPack() throws {
        var c = try coordinator()
        let doc = Doc()
        type("ve", &c, doc)
        c.space(into: doc)
        c.applyCalibration()
        XCTAssertNotNil(c.engine?.decoder.bigrams)
        XCTAssertEqual(c.engine?.decoder.contextWord, "ve")
    }
}
