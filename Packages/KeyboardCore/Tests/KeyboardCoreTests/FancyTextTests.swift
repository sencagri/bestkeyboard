import Testing
@testable import KBRuntime

@Suite("FancyText")
struct FancyTextTests {
    @Test("Kalın harf ve rakam")
    func bold() { #expect(FancyText.apply(.bold, to: "Ab1") == "𝐀𝐛𝟏") }

    @Test("Bloktaki boşluklar doğru harfle dolduruluyor")
    func holes() {
        #expect(FancyText.apply(.script, to: "Be") == "ℬℯ")
        #expect(FancyText.apply(.italic, to: "h") == "ℎ")
        #expect(FancyText.apply(.doubleStruck, to: "R") == "ℝ")
    }

    @Test("Türkçe harf birleşen işaretle")
    func turkish() {
        #expect(FancyText.apply(.bold, to: "ç") == "𝐜\u{0327}")
        #expect(FancyText.apply(.bold, to: "Ğ") == "𝐆\u{0306}")
        #expect(FancyText.apply(.italic, to: "ı") == "𝚤")
        #expect(FancyText.apply(.bold, to: "ı") == "ı")
    }

    @Test("Yuvarlak rakamlar")
    func circledDigits() { #expect(FancyText.apply(.circled, to: "a0 9") == "ⓐ⓪ ⑨") }

    @Test("Noktalama ve emoji olduğu gibi")
    func passthrough() { #expect(FancyText.apply(.fraktur, to: "!? 😂") == "!? 😂") }
}
