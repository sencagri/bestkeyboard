import Foundation
import KBGeometry

/// Kök sözlüğü girdisi.
///
/// Fonolojik bayraklar **sözlükseldir**, yüzeyden türetilemez:
/// `kitap → kitabı` yumuşar ama `at → atı` yumuşamaz; `burun → burnu` ünlü
/// düşürür ama `burun` biçimindeki her kök düşürmez.
public struct Root: Sendable {
    public enum POS: UInt8, Sendable, CaseIterable {
        case noun, verb, adjective, adverb, proper
    }

    /// Geniş zaman ekinin **sözlüksel** sınıfı.
    ///
    /// `gel-ir` ama `yaz-ar`; hece sayısından ya da son sesten güvenilir
    /// türetilemiyor. Alan olmadan iki yüzeyi birden üretmek gerekiyordu ve
    /// ölçümde top-1'i **1.5 puan** düşürüyordu (`geler` gibi çöp adaylar
    /// top-k'yı dolduruyor).
    public enum AoristClass: UInt8, Sendable, CaseIterable {
        /// Sınıf bilinmiyor — geniş zaman **üretilmiyor**.
        ///
        /// Varsayılan bilerek "üretme": bilinmeyen bir kökte tahmin etmek,
        /// yanlış yüzeyi beam'e sokmak demek. Eksik aday kullanıcıya bir
        /// kayıp, yanlış aday herkese maliyet (§5c).
        case unknown = 0
        /// `-Ar` — `yaz-ar`, `bak-ar`.
        case ar = 1
        /// `-(I)r` — `gel-ir`, `bil-ir`, `oku-r`.
        case ir = 2
    }

    /// Ettirgen ekinin **sözlüksel** sınıfı — `-DIr` / `-t` / `-Ir`.
    public enum CausativeClass: UInt8, Sendable, CaseIterable {
        case unknown = 0
        /// `-DIr` — `yap-tır`, `gül-dür`.
        case dir = 1
        /// `-t` — ünlüyle ya da `r`/`l` ile biten çok heceliler: `başla-t`.
        case t = 2
        /// `-Ir` — küçük kapalı sınıf: `iç-ir`, `geç-ir`, `düş-ür`.
        case ir = 3
    }

    public let surface: [Character]
    public let pos: POS
    /// Ham `F_lex` katkısı — `−log(freq/total)`.
    public let lexCost: Double
    public let aoristClass: AoristClass
    public let causativeClass: CausativeClass
    /// Ekin uyumunu belirleyen **okunuş** — yazılıştan farklıysa.
    ///
    /// Türkçe eki sesin ardından seçiyor, harfin değil: `sql` "sikuel" diye
    /// okunuyor ve `sql'leri` alıyor (ince), `sqlları` değil. Yazılışta hiç
    /// ünlü olmadığı için otomat uyumu kuramıyordu — kök yürüyüşü yalnız
    /// harflerden `isBack`/`isRounded` biriktiriyor.
    ///
    /// `nil` ise yazılış okunuş sayılıyor; Türkçe kelimelerin tamamı böyle.
    /// Alan yalnız kısaltmalar ve yabancı markalar için var.
    public let pronunciation: String?
    /// Son ünsüzün **alternasyon sınıfı** — `nil` ise yumuşamaz.
    /// Sınıf sözlükseldir: `çocuk→çocuğ` ama `renk→reng`; tek bir `k→ğ`
    /// tablosu `renği` üretirdi.
    public let finalAlternation: Phonology.Alternation?
    /// Son hecedeki ünlü, ünlüyle başlayan ek önünde düşer mi (`burun → burn-`)?
    public let dropsVowel: Bool

    public init(_ surface: String, pos: POS, lexCost: Double,
                finalAlternation: Phonology.Alternation? = nil, dropsVowel: Bool = false,
                aoristClass: AoristClass = .unknown,
                causativeClass: CausativeClass = .unknown,
                pronunciation: String? = nil) {
        self.surface = Array(surface.precomposedStringWithCanonicalMapping)
        self.pos = pos
        self.lexCost = lexCost
        self.finalAlternation = finalAlternation
        self.dropsVowel = dropsVowel
        self.aoristClass = aoristClass
        self.causativeClass = causativeClass
        self.pronunciation = pronunciation
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
    /// Lokatiften sonra — **yalnız burada** ilgi eki `-ki` gelebilir.
    ///
    /// Hâller tek bir `afterCase` durumunda toplanıyordu ve `-ki` eklenince o
    /// yetmedi: `evdeki` doğru ama `eveki`, `evdenki`, `evi ki` değil. `-ki`
    /// yalnız lokatif ve genitiften türer, dolayısıyla o ikisi kendi durumunu
    /// almak zorunda. Ayrım `-ki` olmadan gereksizdi; şimdi zorunlu.
    case afterLocative
    /// Genitiften sonra — ilgi `-ki`si (`Ahmet'inki` → `ahmetinki`).
    case afterGenitive
    /// Belirtme/yönelme/ayrılma sonrası — devam yok, kelime biter.
    case afterNominalCase
    case verbRoot        // fiil kökü: olumsuzluk / kip
    /// Edilgen/dönüşlü çatıdan sonra.
    ///
    /// **Neden `verbRoot`'a dönmüyor:** ilk denemede `-Il` `verbRoot`'a
    /// dönüyordu ve kendisiyle yığılıp `gelilmek`, `gelililmen`, `gelilişten`
    /// gibi yüzlerce çöp üretiyordu; ölçümde top-1'i 1.5 puan düşürdü.
    /// Türkçe'de edilgen **bir kez** geliyor: `yazıl` var, `yazılıl` yok.
    ///
    /// Bu durumdan normal çekimin tamamı geliyor (olumsuzluk, zaman, kip,
    /// sıfat-fiil, zarf-fiil) ama **çatı gelmiyor**. Ekler elle
    /// kopyalanmıyor — `passiveSuffixes` onları `verbRoot` tablosundan
    /// türetiyor, yani iki tablo ayrışamıyor.
    case afterPassive
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
                finalAlternation: Phonology.Alternation? = nil,
                startsWithVowelSound: Bool? = nil,
                requiresAorist: Root.AoristClass? = nil,
                requiresCausative: Root.CausativeClass? = nil,
                isProgressive: Bool = false) {
        self.id = id
        self.name = name
        self.pieces = pieces
        self.from = from
        self.to = to
        self.cost = cost
        self.finalAlternation = finalAlternation
        self.startsWithVowelSoundOverride = startsWithVowelSound
        self.requiresAorist = requiresAorist
        self.requiresCausative = requiresCausative
        self.isProgressive = isProgressive
    }

    /// `bufferIfVowel` ile başlayan ek, ünsüzden sonra **ünlüyle** başlamıyor.
    ///
    /// Varsayılan çıkarım `-(y)I` gibi ekler için doğru: ünlüden sonra `yı`,
    /// ünsüzden sonra `ı` — her iki hâlde de kökte yumuşama tetikleniyor
    /// (`kitap + ı → kitabı`).
    ///
    /// Ek-fiilde yanlış: `-(y)mIş` ünlüden sonra `ymış`, ünsüzden sonra
    /// **`mış`** veriyor — ünsüz. Varsayılan çıkarım `kitapmış` yerine
    /// **`kitabmış`** üretiyordu. Ölçümle çıktı; `-1A₂` çöp listesinde
    /// `kitabmıştın`, `kitabsak` diye görünüyordu.
    ///
    /// Alan bu yüzden **açıkça geçersiz kılınabiliyor**: yeni bir `Piece`
    /// durumu eklemek aynı ayrımı bütün ek tablosuna dayatırdı, oysa fark
    /// yalnız tampondan **sonra** ne geldiğine bağlı.
    public let startsWithVowelSoundOverride: Bool?

    /// Ek yalnız bu geniş zaman sınıfındaki köke gelebilir.
    ///
    /// Kılavuz **kök sınırında** uygulanıyor, çünkü sınıf yalnız orada
    /// biliniyor: ek fazına geçince hangi kökten gelindiği durumda taşınmıyor.
    /// Sonucu bir eksik: ettirgenle türetilmiş gövdeye (`çalıştır`) geniş
    /// zaman gelmiyor. Kabul edilen boşluk — alternatifi durum uzayına sınıf
    /// bitleri eklemek ve bütün beam'i büyütmek.
    public let requiresAorist: Root.AoristClass?
    /// Ek yalnız bu ettirgen sınıfındaki köke gelebilir.
    public let requiresCausative: Root.CausativeClass?

    /// Şimdiki zaman `-Iyor` mu — daralmış gövdenin alabildiği **tek** ek.
    public let isProgressive: Bool

    /// Ek ünlüyle başlıyor mu? (Kökte yumuşama/ünlü düşmesi bunu gerektirir.)
    public var startsWithVowelSound: Bool {
        if let o = startsWithVowelSoundOverride { return o }
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

    /// `pieces` için **tipli** kurucu — derleme süresi için.
    ///
    /// Her ek `[Piece]` iç literali taşıyordu ve Swift tip denetleyicisi
    /// bunları çevreleyen dizi literaliyle birlikte tek ifade olarak çözmeye
    /// çalışıp üstel davranıyordu: `swift build` 10 dakikada bitmiyordu.
    /// Diziyi ailelere bölmek **yetmedi**; çıkarımı asıl bitiren şey eleman
    /// tipinin burada sabitlenmesi.
    private static func p(_ items: Suffix.Piece...) -> [Suffix.Piece] { items }

    public static let maxSurfaceLen = LexiconLimits.maxSurfaceLength

    /// **Kapsam matrisi (spike).** Aşağıdakiler bilinçli olarak KAPSAM DIŞI ve
    /// Faz 4'e aittir; bit tahmini bu dar graftan "tam Türkçe ölçümü" diye
    /// sunulmamalıdır:
    ///   isim  : -(I)nIz (2çoğul iyelik), çoğul+2. şahıs iyelik, iyelik sonrası
    ///           genitif, -lArI (3çoğul iyelik), ilgi/aitlik ekleri
    ///   fiil  : -sInIz (2çoğul), emir, geniş zaman, gereklilik, şart, istek,
    ///           ettirgen/edilgen çatı, birleşik zamanlar
    ///   ünlüyle biten fiillerde daralma (`başla→başlıyor`, `ye→yiyor`)
    ///   özel ad kesme işareti (`Ankara'ya`)

    /// Ek tablosu **aileler hâlinde** bölündü — derleme süresi için.
    ///
    /// Tek bir 88 elemanlı dizi literali Swift tip denetleyicisini üstel
    /// davranışa sokuyordu: `swift build` 10 dakikayı aşıp bitmiyordu. Her
    /// eleman `[Piece]` iç literali taşıyor ve denetleyici tümünü tek bir
    /// ifade olarak çözmeye çalışıyor. Aileye bölmek hem derlemeyi saniyelere
    /// indiriyor hem de tabloyu okunur yapıyor.
    static let nominalSuffixes: [Suffix] = [
        // --- İsim ---
        Suffix(id: 1, name: "-lAr", pieces: p(.literal("l"), .archiA, .literal("r")),
               from: .nounRoot, to: .afterPlural, cost: 1.2),

        Suffix(id: 2, name: "-(I)m", pieces: p(.optionalIVowel, .literal("m")),
               from: .nounRoot, to: .afterPossessive, cost: 1.6),
        Suffix(id: 3, name: "-(I)n", pieces: p(.optionalIVowel, .literal("n")),
               from: .nounRoot, to: .afterPossessive, cost: 1.8),
        Suffix(id: 4, name: "-(s)I", pieces: p(.bufferIfVowel("s"), .archiI),
               from: .nounRoot, to: .afterPossessive3, cost: 1.4),
        Suffix(id: 5, name: "-(I)mIz", pieces: p(.optionalIVowel, .literal("m"), .archiI, .literal("z")),
               from: .nounRoot, to: .afterPossessive, cost: 2.2),
        // 2. çoğul iyelik — `kaleminiz`. Kapsam matrisinde eksik yazılıydı.
        Suffix(id: 9, name: "-(I)nIz", pieces: p(.optionalIVowel, .literal("n"), .archiI, .literal("z")),
               from: .nounRoot, to: .afterPossessive, cost: 2.2),

        Suffix(id: 6, name: "-(I)m/plural", pieces: p(.optionalIVowel, .literal("m")),
               from: .afterPlural, to: .afterPossessive, cost: 1.6),
        Suffix(id: 7, name: "-(I)mIz/plural", pieces: p(.optionalIVowel, .literal("m"), .archiI, .literal("z")),
               from: .afterPlural, to: .afterPossessive, cost: 2.2),
        Suffix(id: 8, name: "-(s)I/plural", pieces: p(.bufferIfVowel("s"), .archiI),
               from: .afterPlural, to: .afterPossessive3, cost: 1.4),
        Suffix(id: 24, name: "-(I)nIz/plural", pieces: p(.optionalIVowel, .literal("n"), .archiI, .literal("z")),
               from: .afterPlural, to: .afterPossessive, cost: 2.2),

        // **3. çoğul iyelik `-lArI` bilerek EKLENMEDİ.**
        //
        // Kapsam matrisi onu eksik sayıyor ama yüzeyi zaten üretiliyor:
        // `-lAr` + `-(s)I` (id 1 → id 8) tam olarak `kalemleri` veriyor.
        // Ayrı bir ek olarak eklemek **aynı yüzeye ikinci bir yol** açardı ve
        // §9'da ölçülen `surfaceId` parçalanmasını doğrudan büyütürdü: aynı
        // düğüme farklı yolla varan iki durum birleşmiyor. Ayrım anlamsal
        // ("onların kalemi" / "onun kalemleri"), yüzeysel değil — decoder
        // yüzey üretiyor, anlam ayırmıyor.

        // Hâl ekleri — hem kökten, hem çoğuldan, hem iyelikten gelebilir.
        Suffix(id: 10, name: "-(y)I/acc", pieces: p(.bufferIfVowel("y"), .archiI),
               from: .nounRoot, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 11, name: "-(y)A/dat", pieces: p(.bufferIfVowel("y"), .archiA),
               from: .nounRoot, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 12, name: "-DA/loc", pieces: p(.archiD, .archiA),
               from: .nounRoot, to: .afterLocative, cost: 1.5),
        Suffix(id: 13, name: "-DAn/abl", pieces: p(.archiD, .archiA, .literal("n")),
               from: .nounRoot, to: .afterNominalCase, cost: 1.6),
        Suffix(id: 14, name: "-(n)In/gen", pieces: p(.bufferIfVowel("n"), .archiI, .literal("n")),
               from: .nounRoot, to: .afterGenitive, cost: 1.7),

        Suffix(id: 20, name: "-(y)I/acc·pl", pieces: p(.bufferIfVowel("y"), .archiI),
               from: .afterPlural, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 21, name: "-(y)A/dat·pl", pieces: p(.bufferIfVowel("y"), .archiA),
               from: .afterPlural, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 22, name: "-DA/loc·pl", pieces: p(.archiD, .archiA),
               from: .afterPlural, to: .afterLocative, cost: 1.5),
        Suffix(id: 23, name: "-DAn/abl·pl", pieces: p(.archiD, .archiA, .literal("n")),
               from: .afterPlural, to: .afterNominalCase, cost: 1.6),
        // Çoğuldan genitif — `evlerin`, ve `-ki` ile `evdekilerin`.
        //
        // Eksikliği `-ki` eklendikten sonra ölçümle çıktı: `evdekiler` türüyor
        // ama `evdekilerin` türemiyordu. Genitif hâl ekleri arasında tek
        // çoğuldan gelemeyen ekti.
        //
        // 2. tekil iyelik `-(I)n` çoğuldan **eklenmedi**: yüzeyi birebir aynı
        // (`kalemlerin`) ve ikinci bir yol açmak §9'daki `surfaceId`
        // parçalanmasını büyütürdü. Ayrım anlamsal, decoder yüzey üretiyor.
        Suffix(id: 25, name: "-(n)In/gen·pl", pieces: p(.bufferIfVowel("n"), .archiI, .literal("n")),
               from: .afterPlural, to: .afterGenitive, cost: 1.7),

        // 1./2. şahıs iyelikten sonra: hâl eki doğrudan (`kalemim + e → kalemime`).
        Suffix(id: 30, name: "-(y)I/acc·poss12", pieces: p(.bufferIfVowel("y"), .archiI),
               from: .afterPossessive, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 31, name: "-(y)A/dat·poss12", pieces: p(.bufferIfVowel("y"), .archiA),
               from: .afterPossessive, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 32, name: "-DA/loc·poss12", pieces: p(.archiD, .archiA),
               from: .afterPossessive, to: .afterLocative, cost: 1.5),
        Suffix(id: 33, name: "-DAn/abl·poss12", pieces: p(.archiD, .archiA, .literal("n")),
               from: .afterPossessive, to: .afterNominalCase, cost: 1.6),
        // **İyelik sonrası genitif** — `kalemim + in → kalemimin`.
        //
        // Kapsam matrisinin en pahalı eksiğiydi: `panelinin`, `kalemimin`,
        // `evimizin` gibi günlük formlar üretilemiyordu ve yalnız 70k düz
        // listede yazılı olanlar çalışıyordu.
        //
        // Kaynaştırma **yok**: 1./2. şahıs iyelik daima ünsüzle bitiyor
        // (`-m`, `-n`, `-mIz`, `-nIz`), dolayısıyla `(I)` ünlüsü zaten
        // `optionalIVowel` gibi davranmıyor — düz `archiI + n` doğru yüzeyi
        // veriyor. `bufferIfVowel("n")` koymak `kalemimnin` üretirdi.
        Suffix(id: 38, name: "-In/gen·poss12", pieces: p(.archiI, .literal("n")),
               from: .afterPossessive, to: .afterGenitive, cost: 1.7),

        // 3. şahıs iyelikten sonra: **zamir n'si** zorunlu
        // (`kalemi + n + de → kaleminde`).
        Suffix(id: 34, name: "-nI/acc·poss3", pieces: p(.literal("n"), .archiI),
               from: .afterPossessive3, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 35, name: "-nA/dat·poss3", pieces: p(.literal("n"), .archiA),
               from: .afterPossessive3, to: .afterNominalCase, cost: 1.5),
        Suffix(id: 36, name: "-nDA/loc·poss3", pieces: p(.literal("n"), .archiD, .archiA),
               from: .afterPossessive3, to: .afterLocative, cost: 1.5),
        Suffix(id: 37, name: "-nDAn/abl·poss3", pieces: p(.literal("n"), .archiD, .archiA, .literal("n")),
               from: .afterPossessive3, to: .afterNominalCase, cost: 1.6),
        // 3. şahıs iyelikten genitif: zamir n'si burada da zorunlu.
        // `kalemi + n + in → kaleminin`
        Suffix(id: 39, name: "-nIn/gen·poss3", pieces: p(.literal("n"), .archiI, .literal("n")),
               from: .afterPossessive3, to: .afterGenitive, cost: 1.7),

        // --- İlgi eki `-ki` — grafın **ilk çevrimi** ---
        //
        // `evde + ki → evdeki`, `ahmetin + ki → ahmetinki`.
        //
        // ## Hedef neden `nounRoot`
        //
        // `-ki` sonrası kelime bütün isim çekimini alabiliyor: `evdekiler`,
        // `evdekinin`, `evdekinden`. Ayrı bir `adjectivalStem` durumu açıp
        // oraya 14 isim ekinin kopyasını koymak mümkündü — yapılmadı, çünkü
        // kopya graf iki yerde bakım demek ve ayrışması an meselesi. Bedeli
        // hafif aşırı üretim (`evdekim` gibi tuhaf ama zararsız formlar);
        // §5c'nin ucuz tarafı.
        //
        // ## Bu bir ÇEVRİM ve bilinçli
        //
        // `nounRoot → -DA → afterLocative → -ki → nounRoot` kapalı bir döngü:
        // `evdekindeki`, `evdekilerinkiler`… ilkece sınırsız. Türkçe gerçekten
        // böyle; sınırı dilbilgisi değil `maxSurfaceLen` bütçesi koyuyor
        // (§9 — `SurfaceLengthBoundTests` bu yüzden yeniden yazıldı).
        //
        // ## Ünlü uyumu: `-ki` **değişmez**
        //
        // `.archiI` kullanmak `kitaptakı` üretirdi (a→ı), oysa doğrusu
        // `kitaptaki`. `-ki` Türkçe'nin uyuma girmeyen birkaç ekinden biri.
        // Bilinen istisna `-kü` (`bugünkü`, `dünkü`) — kapalı ve çok küçük bir
        // sınıf, ayrı ek olarak eklemek bütün lokatiflere yanlış bir ikinci
        // yüzey açardı. Kayıtlı eksik.
        Suffix(id: 15, name: "-ki/rel·loc", pieces: p(.literal("k"), .literal("i")),
               from: .afterLocative, to: .nounRoot, cost: 2.0),
        Suffix(id: 16, name: "-ki/rel·gen", pieces: p(.literal("k"), .literal("i")),
               from: .afterGenitive, to: .nounRoot, cost: 2.0),

        // --- Fiil ---
        Suffix(id: 40, name: "-mA/neg", pieces: p(.literal("m"), .archiA),
               from: .verbRoot, to: .afterNegation, cost: 1.4),

        Suffix(id: 50, name: "-Iyor", pieces: p(.optionalIVowel, .literal("y"), .literal("o"), .literal("r")),
               from: .verbRoot, to: .afterTense, cost: 1.3, isProgressive: true),
        Suffix(id: 51, name: "-DI/past", pieces: p(.archiD, .archiI),
               from: .verbRoot, to: .afterPastTense, cost: 1.2),
        Suffix(id: 52, name: "-mIş/evid", pieces: p(.literal("m"), .archiI, .literal("ş")),
               from: .verbRoot, to: .afterTense, cost: 1.5),
        Suffix(id: 53, name: "-AcAk/fut", pieces: p(.archiA, .literal("c"), .archiA, .literal("k")),
               from: .verbRoot, to: .afterTense, cost: 1.5, finalAlternation: .kToĞ),

        // Olumsuzluk + şimdiki zaman **kaynaşır**: `-mA` + `-Iyor` → `-mIyor`
        // (`gelme+yor` ❌ `gelmeyor`; doğrusu `gelmiyor`). Ayrı bir ek olarak
        // modellenir çünkü -mA'nın ünlüsü düşüp I'ya dönüşür.
        Suffix(id: 62, name: "-mIyor/neg·pres", pieces: p(.literal("m"), .archiI, .literal("y"), .literal("o"), .literal("r")),
               from: .verbRoot, to: .afterTense, cost: 1.6),
        Suffix(id: 61, name: "-DI/neg", pieces: p(.archiD, .archiI),
               from: .afterNegation, to: .afterPastTense, cost: 1.2),
        Suffix(id: 63, name: "-AcAk/neg", pieces: p(.archiA, .literal("c"), .archiA, .literal("k")),
               from: .afterNegation, to: .afterTense, cost: 1.5, finalAlternation: .kToĞ),

        // Paradigma 1 — ek-fiil (şimdiki/gelecek/duyulan geçmiş sonrası)
        Suffix(id: 70, name: "-Im/1sg", pieces: p(.archiI, .literal("m")),
               from: .afterTense, to: .afterPerson, cost: 1.3),
        Suffix(id: 71, name: "-sIn/2sg", pieces: p(.literal("s"), .archiI, .literal("n")),
               from: .afterTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 72, name: "-Iz/1pl", pieces: p(.archiI, .literal("z")),
               from: .afterTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 73, name: "-lAr/3pl", pieces: p(.literal("l"), .archiA, .literal("r")),
               from: .afterTense, to: .afterPerson, cost: 1.4),

        // Paradigma 2 — görülen geçmiş sonrası (iyelik kökenli, bağlantı ünlüsü YOK)
        Suffix(id: 80, name: "-m/1sg·past", pieces: p(.literal("m")),
               from: .afterPastTense, to: .afterPerson, cost: 1.3),
        Suffix(id: 81, name: "-n/2sg·past", pieces: p(.literal("n")),
               from: .afterPastTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 82, name: "-k/1pl·past", pieces: p(.literal("k")),
               from: .afterPastTense, to: .afterPerson, cost: 1.5),
        Suffix(id: 83, name: "-nIz/2pl·past", pieces: p(.literal("n"), .archiI, .literal("z")),
               from: .afterPastTense, to: .afterPerson, cost: 1.7),
        Suffix(id: 84, name: "-lAr/3pl·past", pieces: p(.literal("l"), .archiA, .literal("r")),
               from: .afterPastTense, to: .afterPerson, cost: 1.4),
    ]
    static let verbalSuffixes: [Suffix] = [
        // ================= Faz 4 · fiil tarafı =================

        // --- Geniş zaman ---
        //
        // **İki yüzey de ekleniyor ve bu geçici.** `-(I)r` ile `-Ar` seçimi
        // sözlükseldir (`gel-ir` ama `yaz-ar`), hece sayısından güvenilir
        // türetilemiyor. Doğru çözüm `Root.aoristClass`; o alan kök paketi
        // formatını değiştirmeyi gerektiriyor ve telaffuz alanıyla (§C) aynı
        // turda gelecek.
        //
        // O zamana kadar ikisi de duruyor: `geler` gibi yanlış bir yüzey aday
        // olarak üretiliyor ama kullanıcı `gelir` yazdığında uzamsal kanıt
        // doğru olanı seçiyor. §5c'nin ucuz tarafı — fazladan aday beam'e
        // maliyet, eksik aday kullanıcıya kayıp.
        Suffix(id: 92, name: "-mAz/aor·neg", pieces: p(.literal("m"), .archiA, .literal("z")),
               from: .verbRoot, to: .afterTense, cost: 1.7),


        // **Sözlüksel sınıf isteyen ekler burada YOK.**
        //
        // Geniş zaman (`-(I)r` / `-Ar`) ve ettirgen (`-DIr` / `-t` / `-Ir`)
        // seçimi köke bağlı ve yüzeyden türetilemiyor: `gel-ir` ama `yaz-ar`.
        // İkisini birden eklemek her fiil için iki yüzey üretiyor
        // (`geler` + `gelir`) ve ölçümde top-1'i **1.5 puan** düşürüyordu —
        // çöp adaylar top-k'yı dolduruyor.
        //
        // Doğru sıra: önce `Root.aoristClass` / `Root.causativeClass` alanları
        // (kök paketi formatı, telaffuz alanıyla aynı tur), sonra bu ekler
        // kılavuzlu olarak geri gelir. Envanterin kendi uyarısı da bu.
        // --- Geniş zaman ve ettirgen: **sözlüksel sınıf kılavuzlu** ---
        //
        // `requiresAorist`/`requiresCausative` olmadan iki yüzey birden
        // üretiliyordu (`geler` + `gelir`) ve top-1 1.5 puan düşüyordu.
        // Sınıfı olmayan kökte ek **hiç üretilmiyor** — tahmin etmektense
        // eksik bırakmak doğru (§5c).
        Suffix(id: 90, name: "-(I)r/aor", pieces: p(.optionalIVowel, .literal("r")),
               from: .verbRoot, to: .afterTense, cost: 1.6, requiresAorist: .ir),
        Suffix(id: 91, name: "-Ar/aor", pieces: p(.archiA, .literal("r")),
               from: .verbRoot, to: .afterTense, cost: 1.6, requiresAorist: .ar),
        Suffix(id: 112, name: "-DIr/caus", pieces: p(.archiD, .archiI, .literal("r")),
               from: .verbRoot, to: .verbRoot, cost: 1.8, requiresCausative: .dir),
        Suffix(id: 116, name: "-Ir/caus", pieces: p(.optionalIVowel, .literal("r")),
               from: .verbRoot, to: .verbRoot, cost: 1.8, requiresCausative: .ir),

        // --- Gereklilik, sürerlik, şart ---
        Suffix(id: 93, name: "-mAlI/nec", pieces: p(.literal("m"), .archiA, .literal("l"), .archiI),
               from: .verbRoot, to: .afterTense, cost: 1.7),
        Suffix(id: 94, name: "-mAlI/nec·neg", pieces: p(.literal("m"), .archiA, .literal("l"), .archiI),
               from: .afterNegation, to: .afterTense, cost: 1.7),
        Suffix(id: 95, name: "-mAktA/prog", pieces: p(.literal("m"), .archiA, .literal("k"),
                                                     .literal("t"), .archiA),
               from: .verbRoot, to: .afterTense, cost: 1.9),
        // Şart `-DI` ile aynı **kısa** şahıs paradigmasını alıyor
        // (`gelse+m → gelsem`, ❌ `gelseyim`).
        Suffix(id: 96, name: "-sA/cond", pieces: p(.literal("s"), .archiA),
               from: .verbRoot, to: .afterPastTense, cost: 1.7),
        Suffix(id: 97, name: "-sA/cond·neg", pieces: p(.literal("s"), .archiA),
               from: .afterNegation, to: .afterPastTense, cost: 1.7),

        // --- Eksik şahıs ekleri ---
        Suffix(id: 98, name: "-sInIz/2pl", pieces: p(.literal("s"), .archiI, .literal("n"),
                                                    .archiI, .literal("z")),
               from: .afterTense, to: .afterPerson, cost: 1.7),

        // --- Emir / istek — hepsi terminal ---
        //
        // Emir kipi kelimeyi **bitiriyor**: `gelsin` üstüne çekim almıyor.
        // `terminal`e bağlamak, `isAccepting` üzerinden kabul edilmelerini
        // sağlıyor ve yanlışlıkla şahıs eki almalarını engelliyor.
        Suffix(id: 100, name: "-sIn/imp3sg", pieces: p(.literal("s"), .archiI, .literal("n")),
               from: .verbRoot, to: .terminal, cost: 1.7),
        Suffix(id: 101, name: "-(y)In/imp2pl", pieces: p(.bufferIfVowel("y"), .archiI, .literal("n")),
               from: .verbRoot, to: .terminal, cost: 1.8),
        Suffix(id: 102, name: "-(y)InIz/imp2pl·formal",
               pieces: p(.bufferIfVowel("y"), .archiI, .literal("n"), .archiI, .literal("z")),
               from: .verbRoot, to: .terminal, cost: 2.0),
        Suffix(id: 103, name: "-(y)AlIm/opt1pl",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("l"), .archiI, .literal("m")),
               from: .verbRoot, to: .terminal, cost: 1.9),
        Suffix(id: 104, name: "-sInlAr/imp3pl",
               pieces: p(.literal("s"), .archiI, .literal("n"), .literal("l"), .archiA, .literal("r")),
               from: .verbRoot, to: .terminal, cost: 2.0),

        // --- Yeterlilik: `edebildik`, `yapabilir` ---
        //
        // Hedef `verbRoot`: yeterlilik yeni bir **fiil gövdesi** üretiyor ve
        // üstüne bütün çekim geliyor. Bu fiil tarafındaki ilk çevrim.
        Suffix(id: 110, name: "-(y)Abil/abil",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("b"), .literal("i"), .literal("l")),
               from: .verbRoot, to: .verbRoot, cost: 1.9),
        // Yetersizlik `-(y)AmA` — `gelemedi`, `yapamıyorum`. `-mA`'dan ayrı bir
        // ek: `-(y)A + mA` diye iki adımda modellemek `geleme` yolunu serbest
        // isim tarafına da açardı.
        Suffix(id: 111, name: "-(y)AmA/inabil",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("m"), .archiA),
               from: .verbRoot, to: .afterNegation, cost: 1.9),

        // --- Çatı: ettirgen ve edilgen ---
        //
        // `çalıştırmış` = çalış + tır + mış. Ettirgen seçimi (`-DIr`/`-t`/`-Ir`)
        // sözlüksel ve hece yapısına bağlı; geniş zamandaki gibi burada da iki
        // yaygın yüzey duruyor ve doğrusunu uzamsal kanıt seçiyor.
        // `-t` ettirgeni **ünlüyle biten** gövdelerde: `başla → başlat`.
        // Kılavuz alanı (`Root.causativeClass`) henüz yok; `bufferIfVowel`
        // sayesinde ünsüzden sonra hiç üretmiyor, yani `gelt` çöpü çıkmıyor.
        Suffix(id: 113, name: "-t/caus", pieces: p(.bufferIfVowel("t")),
               from: .verbRoot, to: .verbRoot, cost: 1.8),
        // **Edilgen `-Il` şimdilik YOK.**
        //
        // `verbRoot`'a dönünce kendisiyle ve bütün yapım ekleriyle yığılıyor:
        // ölçümde `gelilmek`, `gelililmen`, `gelilişten` gibi yüzlerce çöp form
        // üretip top-k'yı dolduruyordu ve doğruluk 1.6 puan düşüyordu.
        //
        // Doğru çözüm envanterde yazılı: edilgen kendi `afterPassive`
        // durumuna gitmeli ve oradan **yalnız çekim** alabilmeli, yeniden çatı
        // alamamalı. O durum, TAM eklerinin ikinci bir kopyasını gerektiriyor;
        // ettirgen/edilgen envanterde de en son aile (9/15).
    ]
    static let converbSuffixes: [Suffix] = [
        // --- Zarf-fiiller — kelimeyi bitiriyorlar ---
        Suffix(id: 120, name: "-(y)Ip/conv", pieces: p(.bufferIfVowel("y"), .archiI, .literal("p")),
               from: .verbRoot, to: .terminal, cost: 1.7),
        Suffix(id: 121, name: "-(y)ArAk/conv",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("r"), .archiA, .literal("k")),
               from: .verbRoot, to: .terminal, cost: 1.8),
        Suffix(id: 122, name: "-(y)IncA/conv",
               pieces: p(.bufferIfVowel("y"), .archiI, .literal("n"), .archiC, .archiA),
               from: .verbRoot, to: .terminal, cost: 1.8),
        Suffix(id: 123, name: "-mAdAn/conv·neg",
               pieces: p(.literal("m"), .archiA, .archiD, .archiA, .literal("n")),
               from: .verbRoot, to: .terminal, cost: 1.8),
        Suffix(id: 124, name: "-(y)Ip/conv·neg", pieces: p(.bufferIfVowel("y"), .archiI, .literal("p")),
               from: .afterNegation, to: .terminal, cost: 1.7),
    ]
    /// **Yapım ekleri KAPSAM DIŞI — ölçümle geri alındı.**
    ///
    /// `-lI`, `-sIz`, `-CI`, `-lIk`, `-lA`, `-lAş`, `-lAn` eklendi ve iki
    /// ölçüm birden onları geri aldırdı:
    ///
    /// 1. **Kombinatoryal patlama.** `-lA` isim tarafından fiil tarafına,
    ///    `-mA` geri getiriyor; ikisi birlikte kapalı bir çevrim kuruyor ve
    ///    beam `renklelmemi`, `gelenlenmez`, `renkçileşme` gibi yüzlerce
    ///    formla doluyor. Maliyeti 4.4'e çıkarmak yetmedi — beam yine de
    ///    keşfediyor, çünkü sınır **derinlik** olmalı, fiyat değil.
    /// 2. **Durum 32 biti aştı** (33). Ek sayısının büyümesi `suffixPayload`
    ///    genişliğini artırdı ve `MorphologyNodeLayout` üretim hedefi
    ///    `UInt32`'ye sığmaz oldu.
    ///
    /// Envanterin önerisi zaten buydu: `maxDerivationalSuffixes = 3` gibi bir
    /// **derinlik sayacı**. O sayaç durum uzayına bit ekliyor, yani 32 bit
    /// sorununu da birlikte çözmek gerekiyor. İkisi tek bir turda yapılmalı;
    /// yarısını bırakmak, ölçülmüş bir gerilemeyi kodda tutmak olurdu.
    ///
    /// Çekim tarafı bundan **etkilenmiyor**: `gözlükçülük` gibi türemiş
    /// kelimeler 70k form listesinde zaten var ve oradan çözülüyor.

    /// Edilgen/dönüşlü — `verbRoot` → `afterPassive`.
    ///
    /// `-Il` ünsüzden, `-In` `l` ile bitenlerden sonra geliyor; ikisi de
    /// yaygın ve seçim kısmen sözlüksel. Yığılma `afterPassive` durumuyla
    /// yapısal olarak engellendiği için ikisini birden tutmak güvenli.
    static let voiceSuffixes: [Suffix] = [
        Suffix(id: 114, name: "-Il/pass", pieces: p(.optionalIVowel, .literal("l")),
               from: .verbRoot, to: .afterPassive, cost: 1.8),
        Suffix(id: 115, name: "-In/pass·refl", pieces: p(.optionalIVowel, .literal("n")),
               from: .verbRoot, to: .afterPassive, cost: 1.9),
    ]

    /// `verbRoot`'tan çıkan **çekim** eklerinin `afterPassive` kopyası.
    ///
    /// Elle yazılmıyor: `verbRoot` tablosu büyüdükçe kopyanın ayrışması an
    /// meselesiydi. Çatı ekleri (`to == .verbRoot`) ve sözlüksel sınıf isteyen
    /// ekler **dışarıda** — birincisi yığılmayı geri getirirdi, ikincisi kök
    /// sınırında olmadığımız için zaten üretilemez.
    ///
    /// Kimlikler `passiveIDOffset` kadar kaydırılıyor; `UInt8` sınırı 255 ve
    /// kayma sonrası en büyük kimlik onun altında kalıyor.
    static let passiveIDOffset: UInt8 = 90

    static let passiveInflection: [Suffix] = {
        let source = verbalSuffixes + converbSuffixes + participleSuffixes
        return source.compactMap { s -> Suffix? in
            guard s.from == .verbRoot, s.to != .verbRoot,
                  s.requiresAorist == nil, s.requiresCausative == nil,
                  s.id <= 255 - passiveIDOffset else { return nil }
            return Suffix(id: s.id + passiveIDOffset, name: s.name + "·pass",
                          pieces: s.pieces, from: .afterPassive, to: s.to,
                          cost: s.cost, finalAlternation: s.finalAlternation,
                          startsWithVowelSound: s.startsWithVowelSoundOverride)
        }
    }()

    static let participleSuffixes: [Suffix] = [
        // --- Sıfat-fiiller: fiilden isim tarafına geçiş ---
        //
        // Hedef `nounRoot` ve bu tasarımın can alıcı yeri: `-DIk` sonrası
        // **iyelik zorunlu** (`bilmediğimiz` = bil+me+dik+imiz) ve hâl de
        // gelebiliyor (`yapacağımızdan`). İsim tarafının tamamını yeniden
        // yazmak yerine oraya bağlamak, `-ki`'de olduğu gibi tek bakım noktası
        // bırakıyor.
        //
        // `k→ğ` yumuşaması **ekin kendisinde**: `bildik + im → bildiğim`.
        Suffix(id: 130, name: "-DIk/part", pieces: p(.archiD, .archiI, .literal("k")),
               from: .verbRoot, to: .nounRoot, cost: 1.7, finalAlternation: .kToĞ),
        Suffix(id: 131, name: "-DIk/part·neg", pieces: p(.archiD, .archiI, .literal("k")),
               from: .afterNegation, to: .nounRoot, cost: 1.7, finalAlternation: .kToĞ),
        Suffix(id: 132, name: "-(y)AcAk/part",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("c"), .archiA, .literal("k")),
               from: .verbRoot, to: .nounRoot, cost: 1.8, finalAlternation: .kToĞ),
        Suffix(id: 133, name: "-(y)An/part",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("n")),
               from: .verbRoot, to: .nounRoot, cost: 1.7),
        Suffix(id: 134, name: "-(y)An/part·neg",
               pieces: p(.bufferIfVowel("y"), .archiA, .literal("n")),
               from: .afterNegation, to: .nounRoot, cost: 1.7),
        // Mastar — `gelmek`, `gelme`, `geliş`. İsim tarafına geçiyor.
        Suffix(id: 135, name: "-mAk/inf", pieces: p(.literal("m"), .archiA, .literal("k")),
               from: .verbRoot, to: .nounRoot, cost: 1.6, finalAlternation: .kToĞ),
        Suffix(id: 136, name: "-mA/vn", pieces: p(.literal("m"), .archiA),
               from: .verbRoot, to: .nounRoot, cost: 1.6),
        Suffix(id: 137, name: "-(y)Iş/vn", pieces: p(.bufferIfVowel("y"), .archiI, .literal("ş")),
               from: .verbRoot, to: .nounRoot, cost: 1.8),
    ]
    static let copulaSuffixes: [Suffix] = [
        // --- Ek-fiil: isim ve zaman üstüne ---
        //
        // `öğrenciydi`, `geliyormuş`, `gelecekse`. Ek-fiil hem isim hem de TAM
        // üstüne geliyor; ikisi de aynı ek, farklı `from`.
        Suffix(id: 140, name: "-(y)DI/cop·noun", pieces: p(.bufferIfVowel("y"), .archiD, .archiI),
               from: .nounRoot, to: .afterPastTense, cost: 1.6, startsWithVowelSound: false),
        Suffix(id: 141, name: "-(y)mIş/cop·noun",
               pieces: p(.bufferIfVowel("y"), .literal("m"), .archiI, .literal("ş")),
               from: .nounRoot, to: .afterTense, cost: 1.7, startsWithVowelSound: false),
        Suffix(id: 142, name: "-(y)sA/cop·noun", pieces: p(.bufferIfVowel("y"), .literal("s"), .archiA),
               from: .nounRoot, to: .afterPastTense, cost: 1.7, startsWithVowelSound: false),
        Suffix(id: 143, name: "-(y)DI/cop·tam", pieces: p(.bufferIfVowel("y"), .archiD, .archiI),
               from: .afterTense, to: .afterPastTense, cost: 1.6, startsWithVowelSound: false),
        Suffix(id: 144, name: "-(y)mIş/cop·tam",
               pieces: p(.bufferIfVowel("y"), .literal("m"), .archiI, .literal("ş")),
               from: .afterTense, to: .afterTense, cost: 1.7, startsWithVowelSound: false),
        Suffix(id: 145, name: "-(y)sA/cop·tam", pieces: p(.bufferIfVowel("y"), .literal("s"), .archiA),
               from: .afterTense, to: .afterPastTense, cost: 1.7, startsWithVowelSound: false),
        // Şahıs ekinden sonra da ek-fiil: `durdurulmuşlardı`, `gelmişlerdi`.
        //
        // Ölçümle çıktı — `-mIş + -lAr` sonrası `-DI` gelemiyordu ve
        // `durdurulmuşlardı` kapsam dışında kalıyordu. 3. çoğul, ek-fiili
        // şahıstan **sonra** alan tek şahıs; sıralama Türkçe'de burada
        // gerçekten ters.
        Suffix(id: 146, name: "-(y)DI/cop·person", pieces: p(.bufferIfVowel("y"), .archiD, .archiI),
               from: .afterPerson, to: .afterPastTense, cost: 1.6, startsWithVowelSound: false),
        Suffix(id: 147, name: "-(y)mIş/cop·person",
               pieces: p(.bufferIfVowel("y"), .literal("m"), .archiI, .literal("ş")),
               from: .afterPerson, to: .afterTense, cost: 1.7, startsWithVowelSound: false),
    ]
    public static let suffixes: [Suffix] =
        nominalSuffixes + verbalSuffixes + converbSuffixes + participleSuffixes
            + copulaSuffixes
            + voiceSuffixes + passiveInflection

    /// Hangi devam sınıfında kelime bitebilir.
    public static func isAccepting(_ c: Continuation) -> Bool {
        switch c {
        case .nounRoot, .afterPlural, .afterPossessive, .afterPossessive3,
             .afterLocative, .afterGenitive, .afterNominalCase,
             .afterTense, .afterPastTense, .afterPerson, .terminal:
            return true
        // Fiil kökü ve olumsuzluk tek başına kelime değildir (`gel`, `gelme`
        // emir kipi olarak geçerli olsa da spike kapsamı dışı).
        case .verbRoot, .afterNegation, .afterPassive:
            return false
        }
    }

    /// Devam sınıfından çıkan ekler — indeks, açılışta bir kez kurulur.
    public static func suffixes(from c: Continuation) -> [Suffix] {
        suffixes.filter { $0.from == c }
    }
}
