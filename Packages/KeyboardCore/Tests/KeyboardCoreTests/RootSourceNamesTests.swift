import Testing
import KBMorphology

/// Kök sözlüğü kaynağının sütun adları — ikili bayrak kodlarıyla aynı yerde.
///
/// Bir sınıf eklenip adı unutulursa paket üreticisi o sınıfı yazan her satırı
/// "bilinmeyen" diye reddeder; bu test eklenen her durumun bir adı olmasını
/// zorluyor.
@Suite("Kök kaynağı adları")
struct RootSourceNamesTests {

    @Test("Her durumun kaynak dosyasında bir adı var")
    func everyCaseNamed() {
        let names = RootPack.SourceNames.self
        #expect(Set(names.pos.values) == Set(Root.POS.allCases))
        #expect(Set(names.alternation.values.compactMap { $0 })
                == Set(Phonology.Alternation.allCases))
        #expect(names.alternation["none"] == .some(nil))
        #expect(Set(names.aorist.values) == Set(Root.AoristClass.allCases))
        #expect(Set(names.causative.values) == Set(Root.CausativeClass.allCases))
    }

    @Test("POS adı ve kısaltması")
    func posNames() {
        #expect(Root.POS(name: "adj") == .adjective)
        #expect(Root.POS(name: "adverb") == .adverb)
        #expect(Root.POS(name: "isim") == nil)
    }
}
