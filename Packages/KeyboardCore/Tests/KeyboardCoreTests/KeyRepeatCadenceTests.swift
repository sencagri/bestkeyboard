import XCTest
@testable import KBRuntime

final class KeyRepeatCadenceTests: XCTestCase {

    private let c = KeyRepeatCadence()

    func testFirstRepeatIsACharacterDelete() {
        XCTAssertEqual(c.stage(forTick: 1), .character)
    }

    func testStageSwitchesToWordAfterTheConfiguredCharacterCount() {
        XCTAssertEqual(c.stage(forTick: c.charactersBeforeWordStage), .character)
        XCTAssertEqual(c.stage(forTick: c.charactersBeforeWordStage + 1), .word)
    }

    func testStageNeverReturnsToCharacter() {
        for tick in (c.charactersBeforeWordStage + 1)...200 {
            XCTAssertEqual(c.stage(forTick: tick), .word, "tick \(tick)")
        }
    }

    /// Aralık **bir sonraki** tekrarın kademesinden okunmalı; yoksa kelime
    /// kademesinin ilk silmesi hâlâ karakter hızında gelirdi.
    func testIntervalSwitchesOneTickBeforeTheStageItServes() {
        let last = c.charactersBeforeWordStage
        XCTAssertEqual(c.interval(afterTick: last - 1), c.characterInterval)
        XCTAssertEqual(c.interval(afterTick: last), c.wordInterval)
    }

    /// Kelime silme karakter hızında akarsa kullanıcı nerede durduğunu göremez.
    func testWordStageIsSlowerThanCharacterStage() {
        XCTAssertGreaterThan(c.wordInterval, c.characterInterval)
    }

    /// İlk gecikme normal bir dokunuşun çok üstünde olmalı, yoksa hızlı yazan
    /// biri istemeden tekrar tetikler.
    func testInitialDelayIsWellAboveAnOrdinaryTap() {
        XCTAssertGreaterThan(c.initialDelay, 4 * c.characterInterval)
    }

    /// Kelime kademesine geçiş ~1.2 sn basılı tutmaya denk gelmeli — kaza eseri
    /// ulaşılacak kadar erken, sabır isteyecek kadar geç olmamalı.
    func testTimeToReachWordStageStaysInAUsableRange() {
        let t = c.initialDelay + Double(c.charactersBeforeWordStage - 1) * c.characterInterval
        XCTAssertGreaterThan(t, 0.8)
        XCTAssertLessThan(t, 2.5)
    }
}

/// Kademelerin **kullanıcı ayarı** olması.
///
/// Değerler artık dışarıdan geliyor (ayar ekranı, kaydedilmiş depo). Geçersiz
/// bir cadence tuşu kullanılamaz hâle getirebilirdi; kırpma `init`'te.
final class KeyRepeatCadenceSettingsTests: XCTestCase {

    func testOutOfRangeValuesAreClamped() {
        let c = KeyRepeatCadence(initialDelay: 99, characterInterval: 0,
                                 wordInterval: 99, charactersBeforeWordStage: -5)
        XCTAssertEqual(c.initialDelay, KeyRepeatCadence.initialDelayRange.upperBound)
        XCTAssertEqual(c.characterInterval, KeyRepeatCadence.characterIntervalRange.lowerBound)
        XCTAssertEqual(c.wordInterval, KeyRepeatCadence.wordIntervalRange.upperBound)
        XCTAssertEqual(c.charactersBeforeWordStage,
                       KeyRepeatCadence.charactersBeforeWordStageRange.lowerBound)
    }

    /// Kelime silme karakterden hızlı akarsa kullanıcı nerede durduğunu göremez
    /// ve basılı tutan biri bir anda paragrafı kaybeder.
    func testWordIntervalCanNeverBeFasterThanCharacterInterval() {
        for ci in stride(from: 0.03, through: 0.20, by: 0.01) {
            let c = KeyRepeatCadence(characterInterval: ci, wordInterval: 0.10)
            XCTAssertGreaterThanOrEqual(c.wordInterval, c.characterInterval,
                                        "karakter aralığı \(ci)")
        }
    }

    /// `with(...)` da `init`'ten geçmeli — yoksa kırpma tek yerde kalmazdı.
    func testWithGoesThroughTheClampingInitializer() {
        let c = KeyRepeatCadence.default.with(initialDelay: 99)
        XCTAssertEqual(c.initialDelay, KeyRepeatCadence.initialDelayRange.upperBound)
        XCTAssertEqual(c.characterInterval, KeyRepeatCadence.default.characterInterval)
    }

    /// Sürgünün ulaşabildiği **her** ayarda tekrar hâlâ anlamlı olmalı:
    /// ilk tekrar sıradan bir dokunuşun üstünde, kelime kademesi karakter
    /// kademesinden sonra.
    /// Kademe 1 ms olduğu için tam tarama 4.7 milyon kombinasyon — testin
    /// süresi bilgiye değmiyor. İnvariantlar bu parametrelerde monoton;
    /// uçlar ve seyrek örnekleme yeterli.
    func testEveryReachableSettingStaysCoherent() {
        let r = KeyRepeatCadence.self
        for d in stride(from: r.initialDelayRange.lowerBound,
                        through: r.initialDelayRange.upperBound, by: 0.05) {
            for ci in stride(from: r.characterIntervalRange.lowerBound,
                             through: r.characterIntervalRange.upperBound,
                             by: 0.01) {
                for n in stride(from: r.charactersBeforeWordStageRange.lowerBound,
                                through: r.charactersBeforeWordStageRange.upperBound,
                                by: 4) {
                    let c = KeyRepeatCadence(initialDelay: d, characterInterval: ci,
                                             charactersBeforeWordStage: n)
                    XCTAssertEqual(c.stage(forTick: 1), .character)
                    XCTAssertEqual(c.stage(forTick: c.charactersBeforeWordStage + 1), .word)
                    XCTAssertGreaterThan(c.timeToWordStage, c.initialDelay - 1e-9)
                    XCTAssertGreaterThanOrEqual(c.wordInterval, c.characterInterval)
                }
            }
        }
    }

    /// 1 ms ızgarası: sürgü `Float` üzerinden geldiği için ham değer
    /// 0.0850000001 olabiliyor; depoya kanonik değer yazılmalı.
    func testTimingsAreSnappedToTheMillisecond() {
        let c = KeyRepeatCadence(initialDelay: 0.4503,
                                 characterInterval: 0.08549,
                                 wordInterval: 0.22001)
        XCTAssertEqual(c.initialDelay, 0.450, accuracy: 1e-9)
        XCTAssertEqual(c.characterInterval, 0.085, accuracy: 1e-9)
        XCTAssertEqual(c.wordInterval, 0.220, accuracy: 1e-9)
    }

    /// `NaN` kırpmadan da yuvarlamadan da sağ çıkıp `Timer`'a geçersiz bir
    /// aralık olarak giderdi.
    func testNonFiniteValuesFallBackToDefaults() {
        let d = KeyRepeatCadence.default
        let c = KeyRepeatCadence(initialDelay: .nan, characterInterval: .nan,
                                 wordInterval: .nan)
        XCTAssertEqual(c.initialDelay, d.initialDelay, accuracy: 1e-9)
        XCTAssertEqual(c.characterInterval, d.characterInterval, accuracy: 1e-9)
        XCTAssertEqual(c.wordInterval, d.wordInterval, accuracy: 1e-9)
        XCTAssertTrue(c.timeToWordStage.isFinite)
    }

    /// Kırpılan bir hareket **kanonik sonucu** vermeli: kelime aralığını
    /// karakterin altına çekmek eski ham değeri gizlemeye devam etmemeli.
    func testWordIntervalClampIsVisibleInTheResult() {
        let fast = KeyRepeatCadence(characterInterval: 0.20, wordInterval: 0.10)
        XCTAssertEqual(fast.wordInterval, 0.20, accuracy: 1e-9)
        // Karakter aralığını sonradan düşürmek gizli 100 ms'yi geri getirmemeli.
        let slower = fast.with(characterInterval: 0.03)
        XCTAssertEqual(slower.wordInterval, 0.20, accuracy: 1e-9)
    }

    func testDefaultIsUnchanged() {
        let c = KeyRepeatCadence.default
        XCTAssertEqual(c.initialDelay, 0.45, accuracy: 1e-9)
        XCTAssertEqual(c.characterInterval, 0.085, accuracy: 1e-9)
        XCTAssertEqual(c.wordInterval, 0.22, accuracy: 1e-9)
        XCTAssertEqual(c.charactersBeforeWordStage, 14)
    }
}
