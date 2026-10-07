import Foundation
import KBFoundation
import KBGeometry

/// Sözlük sorgusu
///
/// "Klavye yazacağım kelimeyi tanımıyor" şikâyetinin **veri toplamayan** cevabı:
/// kelime pakette var mı, maliyeti ne, hangi kaynaktan geliyor. Cihazdan hiçbir
/// şey çekmeden koşuyor.
enum Lookup {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        let lexicon = ctx.lexicon
        print("\n=== sözlük sorgusu ===")
        for raw in opt.lookup {
            // Aynı normalizasyon: kayıt zinciri de NFC + Türkçe küçültme kullanıyor.
            let word = TurkishText.key(raw)
            let matches = lexicon.matches(ofSurface: word)
            if matches.isEmpty {
                let shown = raw == word ? word : "\(raw) → \(word)"
                print("  \(shown): **sözlükte YOK**")
                // Sözlük dışı token literal korumasına düşüyor (§8.1): klavye onu
                // düzeltmiyor ama başka bir kelimeye de çevirmiyor.
                print("    (literal kanalı onu sözlük dışı puanlar)")
                print("    → yazdığın gibi kalır; düzeltme adayı OLARAK da önerilmez")
            } else {
                let shown = raw == word ? word : "\(raw) → \(word)"
                print("  \(shown): sözlükte var")
                for m in matches.prefix(4) {
                    print(String(format: "    F_lex %.3f · dil %d%@",
                                 m.lexCost, Int(m.language),
                                 m.isFormList ? " · form listesi" : " · morfoloji"))
                }
            }
        }
        return 0
    }
}
