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
