import Testing
import Foundation
import KBMorphology

/// `-1A₂` spike'ının kök kümesi. Amaç sözlük değil, yüzey kurallarını ve
/// state şemasını gerçek kısıtlarla sınamak.
enum SpikeRoots {
    static let all: [Root] = [
        // softensFinal: son ünsüz ünlü önünde yumuşar
        Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
        Root("kalem", pos: .noun, lexCost: 4.2),
        Root("ağaç",  pos: .noun, lexCost: 5.0, finalAlternation: .çToC),
        // Aynı son harf `k`, FARKLI hedef — tek tablo `renği` üretirdi.
        Root("renk",  pos: .noun, lexCost: 5.2, finalAlternation: .kToG),
        Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
        // yumuşamayan istisna — aynı son ünsüz, farklı davranış
        Root("at",    pos: .noun, lexCost: 5.5),
        Root("saat",  pos: .noun, lexCost: 4.8),
        // dropsVowel: son hecedeki ünlü düşer
        Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
        Root("ağız",  pos: .noun, lexCost: 5.4, dropsVowel: true),
        // ünlüyle biten kökler — kaynaştırma tetikler
        Root("kapı",  pos: .noun, lexCost: 4.5),
        Root("araba", pos: .noun, lexCost: 4.6),
        Root("masa",  pos: .noun, lexCost: 4.7),
        // ince/kalın ve yuvarlak/düz uyum örnekleri
        Root("göz",   pos: .noun, lexCost: 4.3),
        Root("kuş",   pos: .noun, lexCost: 5.1),
        Root("ev",    pos: .noun, lexCost: 4.1),
        Root("okul",  pos: .noun, lexCost: 4.4),
        // fiiller
        Root("gel",   pos: .verb, lexCost: 4.0),
        Root("git",   pos: .verb, lexCost: 4.1),
        Root("yap",   pos: .verb, lexCost: 4.0),
        Root("gör",   pos: .verb, lexCost: 4.3),
        Root("bul",   pos: .verb, lexCost: 4.5),
    ]

    static func automaton() -> MorphologyAutomaton { MorphologyAutomaton(roots: all) }

    /// Bir kökün ürettiği tüm yüzeyler. Sınır aşımı hata fırlatır (sessiz kesme yok).
    static func forms(_ root: String, maxSuffixes: Int = 3) throws -> Set<String> {
        let a = automaton()
        guard let i = all.firstIndex(where: { String($0.surface) == root }) else { return [] }
        return Set(try a.generate(rootIndex: i, maxSuffixes: maxSuffixes).map(\.surface))
    }
}

@Suite("Fonoloji")
struct PhonologyTests {
    @Test("Ünlü uyumu tabloları — A ve I arşifonemleri")
    func harmony() {
        func A(_ back: Bool, _ round: Bool) -> Character {
            Phonology.realizeA(.init(isBack: back, isRounded: round))
        }
        func I(_ back: Bool, _ round: Bool) -> Character {
            Phonology.realizeI(.init(isBack: back, isRounded: round))
        }
        // A: yalnız kalınlığa bakar
        #expect(A(true, false) == "a");  #expect(A(true, true) == "a")
        #expect(A(false, false) == "e"); #expect(A(false, true) == "e")
        // I: kalınlık × yuvarlaklık
        #expect(I(true, false) == "ı");  #expect(I(false, false) == "i")
        #expect(I(true, true) == "u");   #expect(I(false, true) == "ü")
    }

    @Test("Ünsüz benzeşmesi: D sert sesten sonra t")
    func assimilation() {
        #expect(Phonology.realizeD(precedingIsVoiceless: true) == "t")
        #expect(Phonology.realizeD(precedingIsVoiceless: false) == "d")
    }

    @Test("Son ünlüden uyum bağlamı")
    func context() {
        #expect(Phonology.vowelContext(of: Array("kitap"))
                == .init(isBack: true, isRounded: false))
        #expect(Phonology.vowelContext(of: Array("göz"))
                == .init(isBack: false, isRounded: true))
        #expect(Phonology.vowelContext(of: Array("kuş"))
                == .init(isBack: true, isRounded: true))
        // Ünlüsüz dizide bağlam tanımsız (yabancı kök/kısaltma).
        #expect(Phonology.vowelContext(of: Array("krş")) == nil)
    }
}

@Suite("Morfoloji — yüzey kuralları")
struct MorphologySurfaceTests {

    @Test("Ünlü uyumu ekte doğru gerçekleşir")
    func suffixHarmony() throws {
        let f = try SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(f.contains("kitaplar"))      // kalın → -lar
        #expect(!f.contains("kitapler"))

        let g = try SpikeRoots.forms("ev", maxSuffixes: 1)
        #expect(g.contains("evler"))         // ince → -ler
        #expect(!g.contains("evlar"))

        let h = try SpikeRoots.forms("göz", maxSuffixes: 1)
        #expect(h.contains("gözü"))          // ince+yuvarlak → -ü
        #expect(h.contains("gözler"))
    }

    @Test("Ünsüz yumuşaması: kitap+ı → kitabı, ama at+ı → atı")
    func softening() throws {
        let k = try SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(k.contains("kitabı"), "yumuşamalı: \(k.sorted().prefix(20))")
        #expect(!k.contains("kitapı"), "yumuşamamış hâl üretilmemeli")

        // Sözlüksel istisna: aynı son ünsüz, yumuşamıyor.
        let a = try SpikeRoots.forms("at", maxSuffixes: 1)
        #expect(a.contains("atı"), "üretilenler: \(a.sorted().prefix(20))")
        #expect(!a.contains("adı"))
    }

    @Test("Kaynaştırma ünsüzü: ünlüyle biten kök")
    func buffer() throws {
        let f = try SpikeRoots.forms("kapı", maxSuffixes: 1)
        #expect(f.contains("kapıya"))   // (y) kaynaştırma
        #expect(f.contains("kapısı"))   // (s) iyelik
        #expect(!f.contains("kapıa"))
        #expect(!f.contains("kapıı"))
    }

    @Test("D benzeşmesi: sert sesten sonra -ta/-te")
    func dAssimilation() throws {
        let k = try SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(k.contains("kitapta"))
        #expect(!k.contains("kitapda"))

        let e = try SpikeRoots.forms("ev", maxSuffixes: 1)
        #expect(e.contains("evde"))
        #expect(!e.contains("evte"))
    }

    @Test("Çok ekli form: kalemlerimizden sözlükte olmadan türetilir")
    func multiSuffix() throws {
        let f = try SpikeRoots.forms("kalem", maxSuffixes: 3)
        #expect(f.contains("kalemler"))
        #expect(f.contains("kalemlerimiz"))
        #expect(f.contains("kalemlerimizden"),
                "üretilenler: \(f.sorted().filter { $0.hasPrefix("kalemler") }.prefix(20))")
    }

    @Test("Fiil çekimi: ünlü uyumu ve şahıs ekleri")
    func verbs() throws {
        let g = try SpikeRoots.forms("gel", maxSuffixes: 2)
        #expect(g.contains("geldi"))
        // Görülen geçmiş şahsı bağlantı ünlüsü ALMAZ: geldi+m (❌ geldiim)
        #expect(g.contains("geldim"), "üretilenler: \(g.sorted().filter { $0.hasPrefix("geld") })")
        #expect(!g.contains("geldiim"))
        #expect(g.contains("gelmedi"))
        // Olumsuzluk + şimdiki zaman kaynaşır: gelmiyor (❌ gelmeyor)
        #expect(g.contains("gelmiyor"), "üretilenler: \(g.sorted().filter { $0.hasPrefix("gelm") })")
        #expect(!g.contains("gelmeyor"))
        // Ek sonu yumuşaması: -AcAk + -Im → geleceğim (❌ gelecekim)
        #expect(g.contains("geleceğim"), "üretilenler: \(g.sorted().filter { $0.hasPrefix("gelec") || $0.hasPrefix("geleğ") || $0.hasPrefix("gelece") })")
        #expect(!g.contains("gelecekim"))
        #expect(g.contains("gelecek"))

        let y = try SpikeRoots.forms("yap", maxSuffixes: 2)
        #expect(y.contains("yaptı"), "sert sesten sonra -tı: \(y.sorted().prefix(20))")
        #expect(!y.contains("yapdı"))
    }

    @Test("Fiil kökü tek başına kelime değildir")
    func verbRootNotAccepting() throws {
        let g = try SpikeRoots.forms("gel", maxSuffixes: 2)
        #expect(!g.contains("gel"))
        #expect(!g.contains("gelme"))
    }
}

@Suite("Morfoloji — state şeması ölçümü")
struct MorphologyStateTests {

    /// `-1A₂`'nin asıl çıktısı: bit genişlikleri **ölçülür**, varsayılmaz.
    @Test("Spike ölçeği UInt32'ye sığar")
    func spikeFits() throws {
        let l = SpikeRoots.automaton().nodeLayout
        let detail: Comment = "spike: \(l.breakdown)"
        #expect(l.total <= 32, detail)
        #expect(l.fitsInUInt32, detail)
    }

    /// **Bulgu güncellendi.** Önceki ölçüm üretim ölçeğinin 44 bit tuttuğunu
    /// ve `UInt32`'ye sığmadığını söylüyordu. Kökler ortak önekli trie'ye
    /// taşınınca (`RootTrie`) bu değişti: kök indeksi (17 bit) + karakter
    /// offseti (5 bit) yerine tek bir trie düğümü (19 bit) tutuluyor.
    ///
    /// Sonuç **tam 32 bit** — sığıyor ama **marj sıfır**. Devam sınıfı sayısı,
    /// fonolojik bayraklar veya kök envanteri büyürse taşar. Bu yüzden
    /// `DecoderStateKey.node` `UInt64` bırakıldı: sıfır marjlı bir tasarım
    /// noktasına yaslanmak güvenli değil.
    @Test("ÜRETİM ölçeği tam 32 bit — sığıyor ama marj YOK")
    func productionFitsWithNoMargin() throws {
        let p = MorphologyNodeLayout.productionEstimate
        let detail: Comment = "üretim: \(p.breakdown)"
        #expect(p.total <= 32, detail)
        #expect(p.total >= 30, "marj beklenenden büyük — ölçüm gözden geçirilmeli: \(p.breakdown)")
        // Küçük bir büyüme bile taşırır: bunu gösteren negatif kontrol.
        let grown = MorphologyNodeLayout(
            rootTrieNodeCount: p.rootTrieNodeCount * 4, suffixCount: p.suffixCount,
            continuationCount: p.continuationCount, maxSuffixPieces: p.maxSuffixPieces)
        #expect(!grown.fitsInUInt32,
                "4× kök envanteri taşırmalı: \(grown.breakdown)")
    }
}

@Suite("Morfoloji — aşırı üretim denetimi")
struct MorphologyOvergenerationTests {

    /// 3. şahıs iyelikten sonra **zamir n'si** zorunlu; 1./2. şahıstan sonra yasak.
    /// Bu ayrım olmadan `kalemide` ve `kalemimne` üretiliyordu.
    @Test("İyelik + hâl: zamir n'si doğru yerde")
    func pronominalN() throws {
        let f = try SpikeRoots.forms("kalem", maxSuffixes: 3)
        // 3. şahıs: kalemi → kaleminde
        #expect(f.contains("kaleminde"), "üretilenler: \(f.sorted().filter { $0.hasPrefix("kalemi") })")
        #expect(!f.contains("kalemide"))
        // 1. şahıs: kalemim → kalemime
        #expect(f.contains("kalemime"), "üretilenler: \(f.sorted().filter { $0.hasPrefix("kalemim") })")
        #expect(!f.contains("kalemimne"))
        #expect(!f.contains("kalemimni"))
    }

    /// Aynı yüzey, farklı analiz — **gelecekleri farklı** olduğu için
    /// birleştirilemezler (§4 future-equivalence koşulu).
    ///
    /// `kalemi` iki şekilde çözümlenir:
    ///   (a) kalem + -(s)I  → 3. şahıs iyelik → devam edebilir: `kaleminde`
    ///   (b) kalem + -(y)I  → belirtme hâli   → devam edemez (terminal)
    /// Bu yüzden dedup anahtarı yalnız yüzeye bakamaz.
    @Test("Belirsiz analizler yalnız gelecekleri eşitse birleşebilir")
    func ambiguousAnalysesHaveDifferentFutures() throws {
        let a = SpikeRoots.automaton()
        let i = SpikeRoots.all.firstIndex { String($0.surface) == "kalem" }!
        let forms = try a.generate(rootIndex: i, maxSuffixes: 3)

        // `kalemi` birden çok analizden üretilir.
        let kalemi = forms.filter { $0.surface == "kalemi" }
        #expect(kalemi.count >= 2, "aynı yüzey en az iki analizden gelmeli: \(kalemi)")

        // Analizlerden yalnız biri devam edebiliyor.
        #expect(forms.contains { $0.surface == "kaleminde" })
    }
}

@Suite("Morfoloji — ünlü düşmesi")
struct VowelDropTests {
    /// `dropsVowel` bayrağı önceki sürümde **hiçbir yerde ünlü düşürmüyordu**;
    /// bayrak vardı ama ölüydü, `burnu`/`ağzı` üretilemiyordu.
    @Test("burun → burnu, ağız → ağzı")
    func drop() throws {
        let b = try SpikeRoots.forms("burun", maxSuffixes: 1)
        #expect(b.contains("burnu"), "üretilenler: \(b.sorted())")
        #expect(b.contains("burun"))          // yalın hâl korunur
        #expect(!b.contains("burunu"))        // düşmeden ünlü ek alamaz

        let a = try SpikeRoots.forms("ağız", maxSuffixes: 1)
        #expect(a.contains("ağzı"), "üretilenler: \(a.sorted())")
        #expect(!a.contains("ağızı"))
    }

    @Test("Ünlü düşen kök ünsüz ek alırken düşmez: burunda")
    func noDropBeforeConsonant() throws {
        let b = try SpikeRoots.forms("burun", maxSuffixes: 1)
        #expect(b.contains("burunda"))
        #expect(!b.contains("burnda"))
    }
}

@Suite("Morfoloji — alternasyon sınıfları")
struct AlternationTests {
    /// Aynı son harf `k`, **farklı** hedef. Tek bir `k→ğ` tablosu `renği` üretirdi.
    @Test("k→ğ ve k→g ayrı sınıflar: çocuğu ama rengi")
    func kClasses() throws {
        let c = try SpikeRoots.forms("çocuk", maxSuffixes: 1)
        #expect(c.contains("çocuğu"), "üretilenler: \(c.sorted())")
        #expect(!c.contains("çocugu"))

        let r = try SpikeRoots.forms("renk", maxSuffixes: 1)
        #expect(r.contains("rengi"), "üretilenler: \(r.sorted())")
        #expect(!r.contains("renği"))
    }

    @Test("ç→c: ağaç → ağacı")
    func cClass() throws {
        let a = try SpikeRoots.forms("ağaç", maxSuffixes: 1)
        #expect(a.contains("ağacı"), "üretilenler: \(a.sorted())")
        #expect(!a.contains("ağaçı"))
        // Ünsüz ek önünde yumuşamaz.
        #expect(a.contains("ağaçta"))
        #expect(!a.contains("ağacta"))
    }

    @Test("Yumuşamış biçim tek başına kelime değildir")
    func softenedNotAccepting() throws {
        let k = try SpikeRoots.forms("kitap", maxSuffixes: 2)
        #expect(!k.contains("kitab"))
        let g = try SpikeRoots.forms("gel", maxSuffixes: 3)
        #expect(!g.contains("geleceğ"))
        // Ünsüz ek yumuşamamış biçimle gelir.
        #expect(g.contains("gelecekler"))
        #expect(!g.contains("geleceğler"))
    }
}

@Suite("Morfoloji — state paketleme KANITI")
struct StatePackingTests {
    /// "Toplam < 32" aritmetiği, gerçek durumların çakışmadan kodlanabildiğini
    /// **kanıtlamaz**. Bu test onu kanıtlıyor.
    @Test("Erişilebilir tüm durumlar round-trip ediyor ve çakışmıyor")
    func packRoundTrip() {
        let a = SpikeRoots.automaton()
        let layout = a.nodeLayout
        let states = a.reachableStates(maxSurfaceLen: 10)
        #expect(states.count > 100, "anlamlı örneklem gerekli: \(states.count) durum")

        var packedSeen = [UInt64: MorphologyAutomaton.State]()
        for s in states {
            guard let p = s.packed(layout) else {
                Issue.record("paketlenemedi: \(s)")
                continue
            }
            // Benzersizlik: iki farklı durum aynı anahtara düşemez.
            if let other = packedSeen[p], other != s {
                Issue.record("ÇAKIŞMA: \(s) ile \(other) aynı anahtara düştü (\(p))")
            }
            packedSeen[p] = s
            // Round-trip.
            #expect(MorphologyAutomaton.State.unpacked(p, layout) == s, "round-trip bozuk: \(s)")
        }
    }

    @Test("Spike düğümü UInt32'ye sığar")
    func spikeNodeFits() {
        let l = SpikeRoots.automaton().nodeLayout
        #expect(l.fitsInUInt32, "spike: \(l.breakdown)")
    }

    /// Kök trie'sinden sonra üretim düğümü 32 bite **sığıyor** — ama sıfır marjla.
    @Test("ÜRETİM düğümü 32 bite sığıyor, marj yok")
    func productionNodeFitsTightly() {
        let p = MorphologyNodeLayout.productionEstimate
        #expect(p.fitsInUInt32, "üretim: \(p.breakdown)")
        #expect(p.total >= 30, "marj beklenenden büyük: \(p.breakdown)")
    }

    /// Ölçüm yalnız `node` alanını kapsar — decoder'ın TAM anahtarı çok daha geniş.
    @Test("Tam dedup anahtarı iki kelimelik: 64 biti aşıyor")
    func fullKeyWidth() {
        let node = MorphologyNodeLayout.productionEstimate.total
        let full = DecoderKeyLayout.total(nodeBits: node)
        let detail: Comment = "tam anahtar \(full) bit (node \(node) + surfaceId 32 + touchIndex 6 + …) → tek UInt64 yetmez, struct anahtar gerekiyor"
        #expect(full > 64, detail)
    }
}
