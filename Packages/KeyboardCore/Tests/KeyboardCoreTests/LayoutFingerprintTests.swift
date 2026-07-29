import Foundation
import Testing
@testable import KBGeometry

/// Layout parmak izi — plan v8 §2.8.
///
/// Parmak izinin işi tek: replay'de görülen farkın **kod** farkı mı yoksa
/// sessizce değişmiş bir layout mu olduğunu ayırt etmek. Bu yüzden iki şeyi
/// birden kanıtlamak gerekiyor — aynı layout hep aynı izi vermeli (yoksa her
/// koşuda sahte "ortam değişti" raporu), farklı layout farklı iz vermeli
/// (yoksa gerçek değişiklik kod regresyonu sanılır).
@Suite("Layout parmak izi")
struct LayoutFingerprintTests {

    private func layout(id: String = "test",
                        keys: [Key]? = nil,
                        ascii: [Character: Character] = ["ı": "i"]) -> KeyLayout {
        KeyLayout(id: id,
                  keys: keys ?? [
                    Key(char: "a", center: .init(x: 0.1, y: 0.5),
                        width: 0.1, height: 0.3),
                    Key(char: "b", center: .init(x: 0.3, y: 0.5),
                        width: 0.1, height: 0.3),
                  ],
                  asciiBase: ascii)
    }

    @Test("Aynı layout aynı parmak izini veriyor")
    func stable() {
        #expect(layout().fingerprint == layout().fingerprint)
    }

    /// `Hasher` sürüm başına tohumlanıyor, `Dictionary` sırası çalıştırmalar
    /// arasında değişiyor. Platformun hash'ini kullansaydık iz her süreçte
    /// başka çıkardı; bu test tam olarak onu dışlıyor.
    @Test("Sözlük sırası parmak izini etkilemiyor")
    func dictionaryOrderIrrelevant() {
        let a = layout(ascii: ["ı": "i", "ş": "s", "ğ": "g"])
        let b = layout(ascii: ["ğ": "g", "ı": "i", "ş": "s"])
        #expect(a.fingerprint == b.fingerprint)
    }

    /// Tuş **sırası** anlamlı: `keyIndex` bütün kalibrasyon dizilerinin
    /// indeksi. Sıra değişirse sapmalar başka tuşlara uygulanır — parmak izi
    /// bunu görmek zorunda.
    @Test("Tuş sırası değişince parmak izi değişiyor")
    func keyOrderMatters() {
        let keys = [
            Key(char: "a", center: .init(x: 0.1, y: 0.5), width: 0.1, height: 0.3),
            Key(char: "b", center: .init(x: 0.3, y: 0.5), width: 0.1, height: 0.3),
        ]
        #expect(layout(keys: keys).fingerprint
                != layout(keys: keys.reversed()).fingerprint)
    }

    @Test("Geometri kayması parmak izini değiştiriyor")
    func geometryMatters() {
        let moved = [
            Key(char: "a", center: .init(x: 0.1, y: 0.5), width: 0.1, height: 0.3),
            Key(char: "b", center: .init(x: 0.31, y: 0.5), width: 0.1, height: 0.3),
        ]
        #expect(layout().fingerprint != layout(keys: moved).fingerprint)
    }

    /// **Asıl tuzak buydu:** `layoutID` aynı kalırken içerik değişebiliyor.
    @Test("Aynı kimlik farklı içerik: iz ayırıyor, kimlik ayırmıyor")
    func sameIDDifferentContent() {
        let a = layout(id: "tr-q")
        let b = layout(id: "tr-q", ascii: ["ı": "i", "ş": "s"])
        #expect(a.id == b.id)
        #expect(a.fingerprint != b.fingerprint)
    }

    /// Yalnız hash saklasaydık, iz tutmadığında elimizde "farklı" bilgisinden
    /// fazlası olmazdı. Kanonik metin hangi tuşun kaydığını doğrudan gösteriyor.
    @Test("Kanonik metin diff'lenebilir")
    func descriptionIsReadable() {
        let text = layout().canonicalDescription
        #expect(text.contains("key 0 a"))
        #expect(text.contains("ascii ı i"))
    }
}
