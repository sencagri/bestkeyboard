import Foundation

/// Kök sözlüğü girdisi.
///
/// Fonolojik bayraklar **sözlükseldir**, yüzeyden türetilemez:
/// `kitap → kitabı` yumuşar ama `at → atı` yumuşamaz; `burun → burnu` ünlü
/// düşürür ama `burun` biçimindeki her kök düşürmez.
public struct Root: Sendable {
    public enum POS: UInt8, Sendable, CaseIterable {
        case noun, verb, adjective, adverb, proper
    }

    public let surface: [Character]
    public let pos: POS
    /// Ham `F_lex` katkısı — `−log(freq/total)`.
    public let lexCost: Double
    /// Son ünsüzün **alternasyon sınıfı** — `nil` ise yumuşamaz.
    /// Sınıf sözlükseldir: `çocuk→çocuğ` ama `renk→reng`; tek bir `k→ğ`
    /// tablosu `renği` üretirdi.
    public let finalAlternation: Phonology.Alternation?
    /// Son hecedeki ünlü, ünlüyle başlayan ek önünde düşer mi (`burun → burn-`)?
    public let dropsVowel: Bool

    public init(_ surface: String, pos: POS, lexCost: Double,
                finalAlternation: Phonology.Alternation? = nil, dropsVowel: Bool = false) {
        self.surface = Array(surface.precomposedStringWithCanonicalMapping)
        self.pos = pos
        self.lexCost = lexCost
        self.finalAlternation = finalAlternation
        self.dropsVowel = dropsVowel
    }
}

/// Morfotaktik devam sınıfı — hangi ek grubunun gelebileceğini belirler.
public enum Continuation: UInt8, Sendable, CaseIterable {
    case nounRoot        // isim kökü: çoğul / iyelik / hâl / son
    case afterPlural     // çoğuldan sonra: iyelik / hâl / son
    /// 1./2. şahıs iyelikten sonra (-Im, -In, -ImIz): hâl eki **doğrudan** gelir.
    /// `kalemim + e → kalemime`
    case afterPossessive
    /// 3. şahıs iyelikten sonra (-(s)I, -lArI): araya **zamir n'si** girer.
    /// `kalemi + n + de → kaleminde`
    ///
    /// Bu ayrım olmadan `kalemimne` ve `kalemide` gibi formlar üretiliyordu —
    /// `-1A₂` teşhis çıktısının ortaya çıkardığı bir morfotaktik eksik.
    case afterPossessive3
    case afterCase       // hâlden sonra: son
    case verbRoot        // fiil kökü: olumsuzluk / kip
    case afterNegation   // olumsuzluktan sonra: kip
    /// -Iyor / -mIş / -AcAk sonrası: **ek-fiil** şahıs paradigması (-Im, -sIn, -Iz)
    case afterTense
    /// -DI sonrası: **iyelik kökenli** şahıs paradigması (-m, -n, -k, -nIz)
    /// `geldi+m → geldim` (❌ `geldiim`). İki paradigmayı ayırmadan doğru
    /// çekim üretilemez — bu ayrım `-1A₂` testlerinin ortaya çıkardığı bir eksikti.
    case afterPastTense
    case afterPerson     // şahıstan sonra: son
    case terminal        // yalnız son
}

/// Ek tanımı. Yüzey biçimi arşifonemlerle yazılır (§Phonology).
public struct Suffix: Sendable {
    public enum Piece: Sendable, Equatable {
        case literal(Character)
        case archiA          // a/e
        case archiI          // ı/i/u/ü
        case archiD          // d/t
        case archiC          // c/ç
        /// Kaynaştırma: yalnız önceki ses ünlüyse üretilir.
        case bufferIfVowel(Character)
        /// Ünlüyle başlayan ek: önceki kökte yumuşama/ünlü düşmesi tetikler.
        case optionalIVowel  // (I) — önceki ses ünsüzse üretilir
    }

    public let id: UInt8
    public let name: String
    public let pieces: [Piece]
    public let from: Continuation
    public let to: Continuation
    /// Ham `F_lex` katkısı. Morfem sayısı cezası da bunun içindedir (§2.1).
    public let cost: Double
    /// Ekin son ünsüzünün alternasyon sınıfı — `-AcAk + -Im → geleceğim`.
    /// Yumuşama yalnız köke özgü değildir, **her morfem sınırında** işler.
    public let finalAlternation: Phonology.Alternation?

    public init(id: UInt8, name: String, pieces: [Piece],
                from: Continuation, to: Continuation, cost: Double,
                finalAlternation: Phonology.Alternation? = nil) {
        self.id = id
        self.name = name
        self.pieces = pieces
        self.from = from
        self.to = to
        self.cost = cost
        self.finalAlternation = finalAlternation
    }

    /// Ek ünlüyle başlıyor mu? (Kökte yumuşama/ünlü düşmesi bunu gerektirir.)
    public var startsWithVowelSound: Bool {
        switch pieces.first {
        case .archiA, .archiI, .optionalIVowel: return true
        case let .literal(c): return Phonology.isVowel(c)
        case .bufferIfVowel: return true   // ünlü sonrası tampon, ünsüz sonrası ünlü
        default: return false
        }
    }
}

/// `-1A₂` spike'ı için Türkçe morfotaktik grafı.
///
/// **Kapsam bilinçli olarak dar**: amaç sözlük değil, ABI'yi ve state şemasını
/// gerçek kısıtlarla ölçmek. Tam graf (~200 morfem) Faz 4'te.
public enum TurkishMorphotactics {

    /// (I1) yapısal yüzey uzunluk sınırı — §2.5.
    public static let maxSurfaceLen = 40

    /// **Kapsam matrisi (spike).** Aşağıdakiler bilinçli olarak KAPSAM DIŞI ve
    /// Faz 4'e aittir; bit tahmini bu dar graftan "tam Türkçe ölçümü" diye
    /// sunulmamalıdır:
    ///   isim  : -(I)nIz (2çoğul iyelik), çoğul+2. şahıs iyelik, iyelik sonrası
    ///           genitif, -lArI (3çoğul iyelik), ilgi/aitlik ekleri
    ///   fiil  : -sInIz (2çoğul), emir, geniş zaman, gereklilik, şart, istek,
    ///           ettirgen/edilgen çatı, birleşik zamanlar
    ///   ünlüyle biten fiillerde daralma (`başla→başlıyor`, `ye→yiyor`)
    ///   özel ad kesme işareti (`Ankara'ya`)
    public static let suffixes: [Suffix] = [
        // --- İsim ---
        Suffix(id: 1, name: "-lAr", pieces: [.literal("l"), .archiA, .literal("r")],
               from: .nounRoot, to: .afterPlural, cost: 1.2),

        Suffix(id: 2, name: "-(I)m", pieces: [.optionalIVowel, .literal("m")],
               from: .nounRoot, to: .afterPossessive, cost: 1.6),
        Suffix(id: 3, name: "-(I)n", pieces: [.optionalIVowel, .literal("n")],
               from: .nounRoot, to: .afterPossessive, cost: 1.8),
        Suffix(id: 4, name: "-(s)I", pieces: [.bufferIfVowel("s"), .archiI],
               from: .nounRoot, to: .afterPossessive3, cost: 1.4),
        Suffix(id: 5, name: "-(I)mIz", pieces: [.optionalIVowel, .literal("m"), .archiI, .literal("z")],
               from: .nounRoot, to: .afterPossessive, cost: 2.2),

        Suffix(id: 6, name: "-(I)m/plural", pieces: [.optionalIVowel, .literal("m")],
               from: .afterPlural, to: .afterPossessive, cost: 1.6),
        Suffix(id: 7, name: "-(I)mIz/plural", pieces: [.optionalIVowel, .literal("m"), .archiI, .literal("z")],
               from: .afterPlural, to: .afterPossessive, cost: 2.2),
        Suffix(id: 8, name: "-(s)I/plural", pieces: [.bufferIfVowel("s"), .archiI],
               from: .afterPlural, to: .afterPossessive3, cost: 1.4),

        // Hâl ekleri — hem kökten, hem çoğuldan, hem iyelikten gelebilir.
        Suffix(id: 10, name: "-(y)I/acc", pieces: [.bufferIfVowel("y"), .archiI],
               from: .nounRoot, to: .afterCase, cost: 1.5),
        Suffix(id: 11, name: "-(y)A/dat", pieces: [.bufferIfVowel("y"), .archiA],
               from: .nounRoot, to: .afterCase, cost: 1.5),
        Suffix(id: 12, name: "-DA/loc", pieces: [.archiD, .archiA],
               from: .nounRoot, to: .afterCase, cost: 1.5),
        Suffix(id: 13, name: "-DAn/abl", pieces: [.archiD, .archiA, .literal("n")],
               from: .nounRoot, to: .afterCase, cost: 1.6),
        Suffix(id: 14, name: "-(n)In/gen", pieces: [.bufferIfVowel("n"), .archiI, .literal("n")],
               from: .nounRoot, to: .afterCase, cost: 1.7),

        Suffix(id: 20, name: "-(y)I/acc·pl", pieces: [.bufferIfVowel("y"), .archiI],
               from: .afterPlural, to: .afterCase, cost: 1.5),
        Suffix(id: 21, name: "-(y)A/dat·pl", pieces: [.bufferIfVowel("y"), .archiA],
               from: .afterPlural, to: .afterCase, cost: 1.5),
        Suffix(id: 22, name: "-DA/loc·pl", pieces: [.archiD, .archiA],
               from: .afterPlural, to: .afterCase, cost: 1.5),
        Suffix(id: 23, name: "-DAn/abl·pl", pieces: [.archiD, .archiA, .literal("n")],
               from: .afterPlural, to: .afterCase, cost: 1.6),

        // 1./2. şahıs iyelikten sonra: hâl eki doğrudan (`kalemim + e → kalemime`).
        Suffix(id: 30, name: "-(y)I/acc·poss12", pieces: [.bufferIfVowel("y"), .archiI],
               from: .afterPossessive, to: .afterCase, cost: 1.5),
        Suffix(id: 31, name: "-(y)A/dat·poss12", pieces: [.bufferIfVowel("y"), .archiA],
               from: .afterPossessive, to: .afterCase, cost: 1.5),
        Suffix(id: 32, name: "-DA/loc·poss12", pieces: [.archiD, .archiA],
               from: .afterPossessive, to: .afterCase, cost: 1.5),
        Suffix(id: 33, name: "-DAn/abl·poss12", pieces: [.archiD, .archiA, .literal("n")],
               from: .afterPossessive, to: .afterCase, cost: 1.6),

        // 3. şahıs iyelikten sonra: **zamir n'si** zorunlu
        // (`kalemi + n + de → kaleminde`).
        Suffix(id: 34, name: "-nI/acc·poss3", pieces: [.literal("n"), .archiI],
               from: .afterPossessive3, to: .afterCase, cost: 1.5),
        Suffix(id: 35, name: "-nA/dat·poss3", pieces: [.literal("n"), .archiA],
               from: .afterPossessive3, to: .afterCase, cost: 1.5),
        Suffix(id: 36, name: "-nDA/loc·poss3", pieces: [.literal("n"), .archiD, .archiA],
               from: .afterPossessive3, to: .afterCase, cost: 1.5),
        Suffix(id: 37, name: "-nDAn/abl·poss3", pieces: [.literal("n"), .archiD, .archiA, .literal("n")],
               from: .afterPossessive3, to: .afterCase, cost: 1.6),

        // --- Fiil ---
        Suffix(id: 40, name: "-mA/neg", pieces: [.literal("m"), .archiA],
               from: .verbRoot, to: .afterNegation, cost: 1.4),

        Suffix(id: 50, name: "-Iyor", pieces: [.optionalIVowel, .literal("y"), .literal("o"), .literal("r")],
               from: .verbRoot, to: .afterTense, cost: 1.3),
        Suffix(id: 51, name: "-DI/past", pieces: [.archiD, .archiI],
               from: .verbRoot, to: .afterPastTense, cost: 1.2),
        Suffix(id: 52, name: "-mIş/evid", pieces: [.literal("m"), .archiI, .literal("ş")],
               from: .verbRoot, to: .afterTense, cost: 1.5),
        Suffix(id: 53, name: "-AcAk/fut", pieces: [.archiA, .literal("c"), .archiA, .literal("k")],
               from: .verbRoot, to: .afterTense, cost: 1.5, finalAlternation: .kToĞ),

        // Olumsuzluk + şimdiki zaman **kaynaşır**: `-mA` + `-Iyor` → `-mIyor`
        // (`gelme+yor` ❌ `gelmeyor`; doğrusu `gelmiyor`). Ayrı bir ek olarak
        // modellenir çünkü -mA'nın ünlüsü düşüp I'ya dönüşür.
        Suffix(id: 62, name: "-mIyor/neg·pres", pieces: [.literal("m"), .archiI, .literal("y"), .literal("o"), .literal("r")],
               from: .verbRoot, to: .afterTense, cost: 1.6),
        Suffix(id: 61, name: "-DI/neg", pieces: [.archiD, .archiI],
               from: .afterNegation, to: .afterPastTense, cost: 1.2),
        Suffix(id: 63, name: "-AcAk/neg", pieces: [.archiA, .literal("c"), .archiA, .literal("k")],
               from: .afterNegation, to: .afterTense, cost: 1.5, finalAlternation: .kToĞ),

        // Paradigma 1 — ek-fiil (şimdiki/gelecek/duyulan geçmiş sonrası)
        Suffix(id: 70, name: "-Im/1sg", pieces: [.archiI, .literal("m")],
               from: .afterTense, to: .afterPerson, cost: 1.3),
        Suffix(id: 71, name: "-sIn/2sg", pieces: [.literal("s"), .archiI, .literal("n")],
               from: .afterTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 72, name: "-Iz/1pl", pieces: [.archiI, .literal("z")],
               from: .afterTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 73, name: "-lAr/3pl", pieces: [.literal("l"), .archiA, .literal("r")],
               from: .afterTense, to: .afterPerson, cost: 1.4),

        // Paradigma 2 — görülen geçmiş sonrası (iyelik kökenli, bağlantı ünlüsü YOK)
        Suffix(id: 80, name: "-m/1sg·past", pieces: [.literal("m")],
               from: .afterPastTense, to: .afterPerson, cost: 1.3),
        Suffix(id: 81, name: "-n/2sg·past", pieces: [.literal("n")],
               from: .afterPastTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 82, name: "-k/1pl·past", pieces: [.literal("k")],
               from: .afterPastTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 83, name: "-nIz/2pl·past", pieces: [.literal("n"), .archiI, .literal("z")],
               from: .afterPastTense, to: .afterPerson, cost: 1.7),
        Suffix(id: 84, name: "-lAr/3pl·past", pieces: [.literal("l"), .archiA, .literal("r")],
               from: .afterPastTense, to: .afterPerson, cost: 1.4),
    ]

    /// Hangi devam sınıfında kelime bitebilir.
    public static func isAccepting(_ c: Continuation) -> Bool {
        switch c {
        case .nounRoot, .afterPlural, .afterPossessive, .afterPossessive3, .afterCase,
             .afterTense, .afterPastTense, .afterPerson, .terminal:
            return true
        // Fiil kökü ve olumsuzluk tek başına kelime değildir (`gel`, `gelme`
        // emir kipi olarak geçerli olsa da spike kapsamı dışı).
        case .verbRoot, .afterNegation:
            return false
        }
    }

    /// Devam sınıfından çıkan ekler — indeks, açılışta bir kez kurulur.
    public static func suffixes(from c: Continuation) -> [Suffix] {
        suffixes.filter { $0.from == c }
    }
}
