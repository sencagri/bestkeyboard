import Foundation

/// Türkçe fonolojisi — yüzey kuralları yürüyüş sırasında uygulanır (§4).
///
/// Ekler **arşifonemlerle** yazılır; yüzey biçimi bağlamdan türetilir:
/// - `A` → `a`/`e`      (2'li ünlü uyumu: kalınlık)
/// - `I` → `ı`/`i`/`u`/`ü` (4'lü ünlü uyumu: kalınlık + yuvarlaklık)
/// - `D` → `d`/`t`      (ünsüz benzeşmesi: öncesi sert ise `t`)
/// - `C` → `c`/`ç`
/// - `(y)`, `(s)`, `(n)` → kaynaştırma ünsüzleri; yalnız gerekli bağlamda
public enum Phonology {

    public static let vowels: Set<Character> = ["a", "e", "ı", "i", "o", "ö", "u", "ü"]

    /// Kalın ünlüler. İnce olanlar: e i ö ü
    public static let backVowels: Set<Character> = ["a", "ı", "o", "u"]

    /// Yuvarlak ünlüler. Düz olanlar: a e ı i
    public static let roundedVowels: Set<Character> = ["o", "ö", "u", "ü"]

    /// Sert (ötümsüz) ünsüzler — "fıstıkçı şahap".
    public static let voicelessConsonants: Set<Character> = ["f", "s", "t", "k", "ç", "ş", "h", "p"]

    /// Sonda yumuşayabilen ünsüzler ve yumuşamış karşılıkları.
    /// `kitap + ı → kitabı`. Sözlüksel istisna vardır (`at + ı → atı`), bu yüzden
    /// kökün `softensFinal` bayrağı olmadan uygulanmaz.
    public static let softening: [Character: Character] = ["p": "b", "ç": "c", "t": "d", "k": "ğ"]

    @inline(__always) public static func isVowel(_ c: Character) -> Bool { vowels.contains(c) }
    @inline(__always) public static func isBack(_ c: Character) -> Bool { backVowels.contains(c) }
    @inline(__always) public static func isRounded(_ c: Character) -> Bool { roundedVowels.contains(c) }
    @inline(__always) public static func isVoiceless(_ c: Character) -> Bool { voicelessConsonants.contains(c) }

    /// Ünlü uyumu için gereken bağlam: son ünlünün kalınlık ve yuvarlaklığı.
    public struct VowelContext: Equatable, Sendable {
        public var isBack: Bool
        public var isRounded: Bool
        public init(isBack: Bool, isRounded: Bool) {
            self.isBack = isBack
            self.isRounded = isRounded
        }
    }

    /// `A` arşifoneminin yüzey biçimi.
    public static func realizeA(_ ctx: VowelContext) -> Character { ctx.isBack ? "a" : "e" }

    /// `I` arşifoneminin yüzey biçimi.
    public static func realizeI(_ ctx: VowelContext) -> Character {
        switch (ctx.isBack, ctx.isRounded) {
        case (true, false):  return "ı"
        case (false, false): return "i"
        case (true, true):   return "u"
        case (false, true):  return "ü"
        }
    }

    /// `D` arşifoneminin yüzey biçimi — önceki ses sert ise `t`.
    public static func realizeD(precedingIsVoiceless: Bool) -> Character {
        precedingIsVoiceless ? "t" : "d"
    }

    public static func realizeC(precedingIsVoiceless: Bool) -> Character {
        precedingIsVoiceless ? "ç" : "c"
    }

    /// Bir yüzey dizisinin son ünlüsünden uyum bağlamını çıkarır.
    /// Ünlü yoksa `nil` (yabancı kök/kısaltma durumunda ünlü uyumu tanımsızdır).
    public static func vowelContext(of s: [Character]) -> VowelContext? {
        for c in s.reversed() where isVowel(c) {
            return VowelContext(isBack: isBack(c), isRounded: isRounded(c))
        }
        return nil
    }
}
