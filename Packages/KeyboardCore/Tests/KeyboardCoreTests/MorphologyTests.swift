import Testing
import Foundation
import KBMorphology

/// `-1A₂` spike'ının kök kümesi. Amaç sözlük değil, yüzey kurallarını ve
/// state şemasını gerçek kısıtlarla sınamak.
enum SpikeRoots {
    static let all: [Root] = [
        // softensFinal: son ünsüz ünlü önünde yumuşar
        Root("kitap", pos: .noun, lexCost: 4.0, softensFinal: true),
        Root("kalem", pos: .noun, lexCost: 4.2),
        Root("ağaç",  pos: .noun, lexCost: 5.0, softensFinal: true),
        Root("renk",  pos: .noun, lexCost: 5.2, softensFinal: true),
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

    /// Bir kökün ürettiği tüm yüzeyler.
    static func forms(_ root: String, maxSuffixes: Int = 3) -> Set<String> {
        let a = automaton()
        guard let i = all.firstIndex(where: { String($0.surface) == root }) else { return [] }
        return Set(a.generate(rootIndex: i, maxSuffixes: maxSuffixes).map(\.surface))
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
    func suffixHarmony() {
        let f = SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(f.contains("kitaplar"))      // kalın → -lar
        #expect(!f.contains("kitapler"))

        let g = SpikeRoots.forms("ev", maxSuffixes: 1)
        #expect(g.contains("evler"))         // ince → -ler
        #expect(!g.contains("evlar"))

        let h = SpikeRoots.forms("göz", maxSuffixes: 1)
        #expect(h.contains("gözü"))          // ince+yuvarlak → -ü
        #expect(h.contains("gözler"))
    }

    @Test("Ünsüz yumuşaması: kitap+ı → kitabı, ama at+ı → atı")
    func softening() {
        let k = SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(k.contains("kitabı"), "yumuşamalı: \(k.sorted().prefix(20))")
        #expect(!k.contains("kitapı"), "yumuşamamış hâl üretilmemeli")

        // Sözlüksel istisna: aynı son ünsüz, yumuşamıyor.
        let a = SpikeRoots.forms("at", maxSuffixes: 1)
        #expect(a.contains("atı"), "üretilenler: \(a.sorted().prefix(20))")
        #expect(!a.contains("adı"))
    }

    @Test("Kaynaştırma ünsüzü: ünlüyle biten kök")
    func buffer() {
        let f = SpikeRoots.forms("kapı", maxSuffixes: 1)
        #expect(f.contains("kapıya"))   // (y) kaynaştırma
        #expect(f.contains("kapısı"))   // (s) iyelik
        #expect(!f.contains("kapıa"))
        #expect(!f.contains("kapıı"))
    }

    @Test("D benzeşmesi: sert sesten sonra -ta/-te")
    func dAssimilation() {
        let k = SpikeRoots.forms("kitap", maxSuffixes: 1)
        #expect(k.contains("kitapta"))
        #expect(!k.contains("kitapda"))

        let e = SpikeRoots.forms("ev", maxSuffixes: 1)
        #expect(e.contains("evde"))
        #expect(!e.contains("evte"))
    }

    @Test("Çok ekli form: kalemlerimizden sözlükte olmadan türetilir")
    func multiSuffix() {
        let f = SpikeRoots.forms("kalem", maxSuffixes: 3)
        #expect(f.contains("kalemler"))
        #expect(f.contains("kalemlerimiz"))
        #expect(f.contains("kalemlerimizden"),
                "üretilenler: \(f.sorted().filter { $0.hasPrefix("kalemler") }.prefix(20))")
    }

    @Test("Fiil çekimi: ünlü uyumu ve şahıs ekleri")
    func verbs() {
        let g = SpikeRoots.forms("gel", maxSuffixes: 2)
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

        let y = SpikeRoots.forms("yap", maxSuffixes: 2)
        #expect(y.contains("yaptı"), "sert sesten sonra -tı: \(y.sorted().prefix(20))")
        #expect(!y.contains("yapdı"))
    }

    @Test("Fiil kökü tek başına kelime değildir")
    func verbRootNotAccepting() {
        let g = SpikeRoots.forms("gel", maxSuffixes: 2)
        #expect(!g.contains("gel"))
        #expect(!g.contains("gelme"))
    }
}

@Suite("Morfoloji — state şeması ölçümü")
struct MorphologyStateTests {

    /// `-1A₂`'nin asıl çıktısı: bit genişlikleri **ölçülür**, varsayılmaz.
    @Test("Spike ölçeği UInt32'ye sığar")
    func spikeFits() {
        let l = SpikeRoots.automaton().measuredLayout
        let detail: Comment = "spike layout: \(l.total) bit — kök \(l.rootBits), offset \(l.offsetBits), ek \(l.suffixBits), devam \(l.continuationBits), fonoloji \(l.phonologyBits)"
        #expect(l.total <= 32, detail)
        #expect(l.fitsInUInt32, detail)
    }

    /// **Kritik bulgu.** Sözleşme §4 `node: UInt32` diyor; gerçek ölçekte yetmiyor.
    /// Bu test, bulgunun sessizce kaybolmaması için var: gerçek ölçek UInt32'ye
    /// sığmaya başlarsa test kırılır ve karar yeniden gözden geçirilir.
    @Test("ÜRETİM ölçeği UInt32'ye SIĞMAZ — escape/yan tablo gerekiyor")
    func productionOverflows() {
        let p = MorphologyAutomaton.Bits.production
        let detail: Comment = "üretim layout: \(p.total) bit — kök \(p.rootBits), offset \(p.offsetBits), ek \(p.suffixBits), devam \(p.continuationBits), fonoloji \(p.phonologyBits)"
        #expect(!p.fitsInUInt32, detail)
        #expect(p.total > 32, detail)
        #expect(p.total <= 64, "64 bite sığmalı ki iki kelimelik anahtar yeterli olsun")
    }
}

@Suite("Morfoloji — aşırı üretim denetimi")
struct MorphologyOvergenerationTests {

    /// 3. şahıs iyelikten sonra **zamir n'si** zorunlu; 1./2. şahıstan sonra yasak.
    /// Bu ayrım olmadan `kalemide` ve `kalemimne` üretiliyordu.
    @Test("İyelik + hâl: zamir n'si doğru yerde")
    func pronominalN() {
        let f = SpikeRoots.forms("kalem", maxSuffixes: 3)
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
    func ambiguousAnalysesHaveDifferentFutures() {
        let a = SpikeRoots.automaton()
        let i = SpikeRoots.all.firstIndex { String($0.surface) == "kalem" }!
        let forms = a.generate(rootIndex: i, maxSuffixes: 3)

        // `kalemi` birden çok analizden üretilir.
        let kalemi = forms.filter { $0.surface == "kalemi" }
        #expect(kalemi.count >= 2, "aynı yüzey en az iki analizden gelmeli: \(kalemi)")

        // Analizlerden yalnız biri devam edebiliyor.
        #expect(forms.contains { $0.surface == "kaleminde" })
    }
}
