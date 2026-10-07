import Foundation
import Testing
import KBFoundation
import KBGeometry
@testable import KBRuntime

/// Türkçe metin kuralları ve noktalama kümeleri — tek kaynaktan.
@Suite("Türkçe metin kuralları")
struct TurkishTextTests {

    @Test("Büyük harf Türkçe: i → İ, ı → I")
    func uppercase() {
        #expect(TurkishText.uppercased("istanbul ılık") == "İSTANBUL ILIK")
        #expect(TurkishText.uppercased(Character("i")) == "İ")
        #expect(TurkishText.uppercased(Character("ı")) == "I")
    }

    @Test("Biçim: caps-lock en az iki harf ister")
    func casing() {
        #expect(TurkishText.casing(of: "KALEM") == .allCaps)
        #expect(TurkishText.casing(of: "Kslem") == .capitalized)
        #expect(TurkishText.casing(of: "K") == .capitalized)
        #expect(TurkishText.casing(of: "kalem") == .none)
        #expect(TurkishText.casing(of: "1a") == .none)
        #expect(TurkishText.casing(of: "") == .none)
    }

    @Test("Biçim adaya Türkçe kuralla taşınıyor")
    func applying() {
        #expect(TurkishText.applying(.capitalized, to: "istanbul") == "İstanbul")
        #expect(TurkishText.applying(.allCaps, to: "ılık") == "ILIK")
        #expect(TurkishText.applying(.none, to: "ev") == "ev")
        #expect(TurkishText.applying(.allCaps, to: "") == "")
    }

    /// Locale'siz karşılaştırma `İ`'yi iki skalere açıyor ve casing olgusu tam
    /// Türkçe harfte yanlış kaydediliyordu.
    @Test("Yalnız büyük harf farkı Türkçe harfte de tanınıyor")
    func casingAppliedTurkish() {
        #expect(InputCoordinator.casingApplied(committed: "İstanbul", literal: "istanbul"))
        #expect(InputCoordinator.casingApplied(committed: "Ilık", literal: "ılık"))
        #expect(!InputCoordinator.casingApplied(committed: "ali", literal: "ali"))
        #expect(!InputCoordinator.casingApplied(committed: "Ali", literal: "veli"))
    }

    @Test("Token uçlarından noktalama atılıyor, içi korunuyor")
    func tokenEdges() {
        #expect(Punctuation.trimmingTokenEdges("«akşam,»") == "akşam")
        #expect(Punctuation.trimmingTokenEdges("192.168.1.10.") == "192.168.1.10")
        #expect(Punctuation.trimmingTokenEdges("...") == "")
    }
}
