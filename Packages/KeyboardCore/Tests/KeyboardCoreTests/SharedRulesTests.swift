import XCTest
import KBFoundation
import KBGeometry
import KBLexicon
import KBMorphology
import KBRuntime
import KBLearning

/// Tek kaynağa taşınan ortak kurallar: biri kayarsa öğrenme, bağlam ve paket
/// anahtarları birbirini tutmaz.
final class SharedRulesTests: XCTestCase {
    func testTurkishKeyLowersDottedAndDotlessI() {
        XCTAssertEqual(TurkishText.key("İSTANBUL"), "istanbul")
        XCTAssertEqual(TurkishText.key("IŞIK"), "ışık")
        // `İ` locale'siz çevrilince `i` + birleşen nokta olurdu.
        XCTAssertEqual(TurkishText.key("İ").unicodeScalars.count, 1)
    }

    func testTurkishKeyNormalizesDecomposedInput() {
        let decomposed = "c\u{0327}ay"   // c + birleşen çengel
        XCTAssertEqual(TurkishText.key(decomposed), "çay")
        XCTAssertEqual(TurkishText.key(decomposed), TurkishText.key("ÇAY"))
    }

    func testSentenceTerminatorsAreContextBreakers() {
        XCTAssertTrue(Punctuation.sentenceTerminators.isSubset(of: Punctuation.contextBreakers))
        // Kasıtlı fark: `:` bağlamı keser ama büyük harf istemez.
        XCTAssertTrue(Punctuation.contextBreakers.contains(":"))
        XCTAssertFalse(Punctuation.sentenceTerminators.contains(":"))
    }

    func testSurfaceLengthLimitIsShared() {
        XCTAssertEqual(TurkishMorphotactics.maxSurfaceLen, LexiconLimits.maxSurfaceLength)
        XCTAssertEqual(PersonalLexicon.maxLength, LexiconLimits.maxSurfaceLength)
    }
}

final class FNV1aTests: XCTestCase {
    /// Kayıtlı dosyaların checksum'ı bu değerlere bağlı: sabitler kayarsa yakala.
    func testKnownVectors() {
        XCTAssertEqual(FNV1a.hash([UInt8]()), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(FNV1a.hash("a".utf8), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(FNV1a.hash("foobar".utf8), 0x8594_4171_f739_67e8)
    }

    /// Silme atfının kanonik biçimi: üretici indirgiyor, denetleyici aynı
    /// kuralla soruyor.
    func testDeletedSpanCanonicalForm() {
        let raw: [DeletedSpan] = [.separator, .separator, .removedToken(TokenID(raw: 1)),
                                  .unattributed, .unattributed, .separator]
        let canonical = DeletedSpan.canonical(raw)
        XCTAssertEqual(canonical, [.separator, .removedToken(TokenID(raw: 1)),
                                   .unattributed, .separator])
        XCTAssertFalse(DeletedSpan.isCanonical(raw))
        XCTAssertTrue(DeletedSpan.isCanonical(canonical))
        XCTAssertTrue(DeletedSpan.isCanonical([]))
    }
}
