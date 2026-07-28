import XCTest
import KBGeometry
@testable import KBRuntime

/// Shift ve otomatik büyük harf — plan §8.
final class ShiftPolicyTests: XCTestCase {

    // MARK: - Elle shift

    func testSingleTapGivesOneShotUppercase() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        XCTAssertEqual(s.mode, .oneShot)
        XCTAssertTrue(s.isUppercase)
    }

    /// Tek harften sonra düşer — normal shift davranışı.
    func testOneShotFallsAfterOneLetter() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.didEmitLetter()
        XCTAssertEqual(s.mode, .off)
    }

    func testSecondTapWithinTheWindowLocks() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.tapShift(at: 0.2)
        XCTAssertEqual(s.mode, .locked)
    }

    func testSecondTapOutsideTheWindowJustToggles() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.tapShift(at: 1.0)
        XCTAssertEqual(s.mode, .off, "yavaş ikinci dokunuş kilitlememeli")
    }

    /// Kilit harflerden etkilenmez — kilidin anlamı bu.
    func testLockSurvivesLetters() {
        var s = ShiftPolicy()
        s.tapShift(at: 0); s.tapShift(at: 0.2)
        for _ in 0..<5 { s.didEmitLetter() }
        XCTAssertEqual(s.mode, .locked)
        XCTAssertTrue(s.isUppercase)
    }

    /// Kilitliyken **tek** dokunuş kapatır. Çift dokunuş beklemek tuzak
    /// olurdu: kullanıcının kilidi bırakmasının başka yolu yok.
    func testSingleTapUnlocks() {
        var s = ShiftPolicy()
        s.tapShift(at: 0); s.tapShift(at: 0.2)
        XCTAssertEqual(s.mode, .locked)
        s.tapShift(at: 1.0)
        XCTAssertEqual(s.mode, .off)
    }

    /// Kilidi açan dokunuş, hemen ardından gelen dokunuşla yeniden
    /// kilitlememeli — yoksa kapatmak imkânsız olurdu.
    func testUnlockingThenTappingAgainDoesNotRelock() {
        var s = ShiftPolicy()
        s.tapShift(at: 0); s.tapShift(at: 0.2)     // kilit
        s.tapShift(at: 0.3)                        // kilidi aç
        XCTAssertEqual(s.mode, .off)
        s.tapShift(at: 0.4)
        XCTAssertEqual(s.mode, .oneShot, "yeniden kilitlenmemeli")
    }

    /// Araya harf giren iki shift dokunuşu **ardışık değildir**.
    /// Kesilmeseydi `shift → harf → shift` 0.35 sn içinde yanlışlıkla
    /// caps-lock açardı — hızlı yazan biri bunu sürekli yaşardı.
    func testALetterBetweenTapsBreaksTheDoubleTapChain() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.didEmitLetter()
        s.tapShift(at: 0.2)
        XCTAssertEqual(s.mode, .oneShot, "araya harf girdi, kilit olmamalı")
    }

    func testANonLetterInputBreaksTheChain() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.didInterruptChain()
        s.tapShift(at: 0.2)
        // İddia **kilitlenmemesi**: shift açıkken dokunmak onu kapatır,
        // bu doğru geçiş.
        XCTAssertNotEqual(s.mode, .locked, "araya sembol girdi, kilit olmamalı")
        XCTAssertEqual(s.mode, .off, "açık shift'e dokunmak kapatır")
    }

    func testAutoCapitalizationBreaksTheChain() {
        var s = ShiftPolicy()
        s.tapShift(at: 0)
        s.autoCapitalize(false)
        s.tapShift(at: 0.2)
        XCTAssertEqual(s.mode, .oneShot)
    }

    // MARK: - Otomatik büyük harf

    /// Otomatik mantık kullanıcının **açık** kararını ezmemeli.
    func testAutoCapitalizationDoesNotBreakTheLock() {
        var s = ShiftPolicy()
        s.tapShift(at: 0); s.tapShift(at: 0.2)
        s.autoCapitalize(false)
        XCTAssertEqual(s.mode, .locked)
    }

    func testAutoCapitalizationSetsOneShot() {
        var s = ShiftPolicy()
        s.autoCapitalize(true)
        XCTAssertEqual(s.mode, .oneShot)
        s.autoCapitalize(false)
        XCTAssertEqual(s.mode, .off)
    }

    // MARK: - Cümle başı kararı

    func testSentencesCapitalizesAtTheStartOfText() {
        XCTAssertTrue(ShiftPolicy.shouldCapitalize(context: "", type: .sentences))
        XCTAssertTrue(ShiftPolicy.shouldCapitalize(context: nil, type: .sentences))
    }

    func testSentencesCapitalizesAfterTerminator() {
        for c in ["Merhaba. ", "Nasılsın? ", "Dur! ", "Bir satır\n"] {
            XCTAssertTrue(ShiftPolicy.shouldCapitalize(context: c, type: .sentences), c)
        }
    }

    func testSentencesDoesNotCapitalizeMidSentence() {
        for c in ["merhaba ", "bir iki ", "kalem "] {
            XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: c, type: .sentences), c)
        }
    }

    /// Kelime ortasında **hiçbir zaman** büyük harf: boşluk görülmediyse
    /// token sürüyor demektir.
    func testSentencesDoesNotCapitalizeInsideAWord() {
        XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: "kale", type: .sentences))
        XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: "Merhaba.k", type: .sentences))
    }

    func testWordsCapitalizesAfterAnySpace() {
        XCTAssertTrue(ShiftPolicy.shouldCapitalize(context: "bir ", type: .words))
        XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: "bir", type: .words))
    }

    func testAllCharactersAlwaysCapitalizes() {
        XCTAssertTrue(ShiftPolicy.shouldCapitalize(context: "abc", type: .allCharacters))
    }

    func testNoneNeverCapitalizes() {
        XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: "", type: .none))
        XCTAssertFalse(ShiftPolicy.shouldCapitalize(context: "Merhaba. ", type: .none))
    }
}

/// Rakam/sembol düzlemleri — plan §8.
final class SymbolPlaneTests: XCTestCase {

    /// Düzlemler harf düzlemiyle **aynı** satır yüksekliğini kullanmalı:
    /// tuşlar yerinden oynarsa kas hafızası her geçişte bozulur.
    func testPlanesShareTheLetterRowHeight() {
        XCTAssertEqual(SymbolPlanes.rowHeight, TurkishQ.rowHeight)
    }

    /// Vuruş **çerçeve** testiyle: burada uzamsal model yok, dolayısıyla
    /// tuşun dışına basmak karakter üretmemeli.
    func testTouchOutsideAKeyProducesNothing() {
        let p = SymbolPlanes.numbers
        // 4. satır sembol düzleminde tuş taşımıyor.
        XCTAssertNil(p.hit(at: Point(x: 0.5, y: 0.9)))
    }

    func testTouchOnAKeyProducesThatKey() {
        let p = SymbolPlanes.numbers
        let k = p.keys[0]
        let i = p.hit(at: k.center)
        XCTAssertNotNil(i)
        XCTAssertEqual(p.keys[i!].char, "1")
    }

    /// En yakın merkez kullanılsaydı iki sembol arasındaki boşluk rastgele
    /// birini yazardı — `3` isteyene `4` vermek düpedüz hata.
    func testGapBetweenKeysIsNotSnappedToTheNearest() {
        let p = SymbolPlanes.numbers
        // 3. satır ortalanmış, kenarlarda tuş yok.
        XCTAssertNil(p.hit(at: Point(x: 0.02, y: SymbolPlanes.rowHeight * 2.5)))
    }

    func testNumbersPlaneHasTheDigits() {
        let chars = SymbolPlanes.numbers.keys.map(\.char)
        for d in "1234567890" { XCTAssertTrue(chars.contains(d), String(d)) }
    }

    func testSymbolsPlaneHasCommonSymbols() {
        let chars = SymbolPlanes.symbols.keys.map(\.char)
        for c in "[]{}#%^*+=" { XCTAssertTrue(chars.contains(c), String(c)) }
    }

    /// Her iki düzlemde de noktalama olmalı — kullanıcı nokta için düzlem
    /// değiştirmek zorunda kalmamalı.
    func testBothPlanesCarryPunctuation() {
        for p in [SymbolPlanes.numbers, SymbolPlanes.symbols] {
            let chars = p.keys.map(\.char)
            for c in ".,?!'" { XCTAssertTrue(chars.contains(c), String(c)) }
        }
    }

    /// Hiçbir tuş çakışmamalı.
    func testKeysDoNotOverlap() {
        for p in [SymbolPlanes.numbers, SymbolPlanes.symbols] {
            for (i, a) in p.keys.enumerated() {
                for b in p.keys[(i + 1)...] {
                    let dx = abs(a.center.x - b.center.x)
                    let dy = abs(a.center.y - b.center.y)
                    XCTAssertTrue(dx >= (a.width + b.width) / 2 - 1e-9
                                  || dy >= (a.height + b.height) / 2 - 1e-9,
                                  "\(a.char) ile \(b.char) çakışıyor")
                }
            }
        }
    }
}

// MARK: - Vuruş alanı görsel tuşla hizalı

extension SymbolPlaneTests {

    /// Çizim tuşları içeri çekiyor; vuruş alanı da o kadar daralmalı, yoksa
    /// **görünen boşluğa** dokunmak karakter üretir.
    func testGapBetweenAdjacentKeysProducesNothing() {
        let p = SymbolPlanes.numbers
        let a = p.keys[0], b = p.keys[1]
        // İki tuşun tam sınırı — görsel boşluğun ortası.
        let border = Point(x: (a.center.x + b.center.x) / 2, y: a.center.y)
        XCTAssertNil(p.hit(at: border), "komşu tuşlar arasındaki boşluk boş olmalı")
    }

    /// Sınırda çakışma olmamalı: `<=` ile iki hücre aynı noktayı sahipleniyor
    /// ve ilk tuş kazanıyordu.
    func testKeyBoundariesDoNotOverlap() {
        let p = SymbolPlanes.numbers
        for (i, k) in p.keys.enumerated() {
            let right = Point(x: k.center.x + k.width / 2, y: k.center.y)
            if let hit = p.hit(at: right) {
                XCTAssertEqual(hit, i, "sınır iki tuş tarafından sahiplenilmemeli")
            }
        }
    }

    /// Tuşun ortası her zaman vurulmalı — daraltma fazla olmamalı.
    func testEveryKeyCentreIsHittable() {
        for p in [SymbolPlanes.numbers, SymbolPlanes.symbols] {
            for (i, k) in p.keys.enumerated() {
                XCTAssertEqual(p.hit(at: k.center), i, String(k.char))
            }
        }
    }
}
