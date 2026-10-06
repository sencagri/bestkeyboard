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
    /// Sert ünsüzler — ek başındaki `D`/`C` arşifonemini `t`/`ç` yapanlar.
    ///
    /// `x` Türkçe alfabede yok ama **köklerde var**: `netflix`, `linux`,
    /// `unix`. Türkçe onu "ks" diye okuyor ve ek sert geliyor —
    /// `Netflix'ten`, `Linux'ta`. Sette olmadığı için `netflixden`
    /// üretiliyordu.
    ///
    /// `q` ve `w` de aynı sebeple burada değil: ikisi de ötümlü okunuyor
    /// (`w` → "v", `q` → "k" ama kelime sonunda pratikte hiç gelmiyor).
    public static let voicelessConsonants: Set<Character> = ["f", "s", "t", "k", "ş", "ç", "h", "p", "x"]

    @inline(__always) public static func isVowel(_ c: Character) -> Bool { vowels.contains(c) }
    @inline(__always) public static func isBack(_ c: Character) -> Bool { backVowels.contains(c) }
    @inline(__always) public static func isRounded(_ c: Character) -> Bool { roundedVowels.contains(c) }
    @inline(__always) public static func isVoiceless(_ c: Character) -> Bool { voicelessConsonants.contains(c) }

    /// Son ünsüz yumuşaması **sözlüksel bir alternasyon sınıfıdır**, son harften
    /// türetilemez:
    /// - `kitap → kitab-` ama `at → at-`      (aynı `t`/`p` sınıfı, farklı davranış)
    /// - `çocuk → çocuğ-` ama `renk → reng-`  (aynı `k`, **farklı hedef**)
    ///
    /// Tek bir `k → ğ` tablosu `renği` üretirdi. Bu yüzden hedef harf kökün
    /// kendisinde saklanır.
    public enum Alternation: UInt8, Sendable, CaseIterable {
        case pToB, çToC, tToD, kToĞ, kToG

        public var target: Character {
            switch self {
            case .pToB: return "b"
            case .çToC: return "c"
            case .tToD: return "d"
            case .kToĞ: return "ğ"
            case .kToG: return "g"
            }
        }

        public var source: Character {
            switch self {
            case .pToB: return "p"
            case .çToC: return "ç"
            case .tToD: return "t"
            case .kToĞ, .kToG: return "k"
            }
        }
    }

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
