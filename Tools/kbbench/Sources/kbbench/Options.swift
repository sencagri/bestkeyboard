import Foundation
import KBAssembly
import KBDecoder
import KBToolSupport

/// Komut satırı seçenekleri.
///
/// Ölçüm **kipleri** (`Mode`) ile ortak parametreler ayrı: eskiden her kip bir
/// `Bool` bayraktı ve akış sabit bir sırayla ilerliyordu — kod çözme ölçümü her
/// kipten önce koşuyor, kiplerin çoğu `exit` ile bittiği için ikinci bir kip
/// hiç çalışmıyordu (`--personal --lookup x` lookup'ı sessizce atlıyordu).
/// Şimdi istenen kipler **komut satırındaki sırayla** koşuyor; hiçbiri
/// istenmediyse varsayılan kip kod çözme ölçümü.
struct Options {

    /// Bağımsız bir ölçüm. Her biri yalnız kendi ihtiyacını yüklüyor.
    enum Mode: String, CaseIterable {
        /// Kod çözme doğruluğu ve gecikmesi — varsayılan.
        case decode
        /// Aday budamasının yaklaşım payı (§5.4/4).
        case pruningGap
        /// Beam genişliği taraması — beam **bağlıyor mu** (§9, `surfaceId`).
        ///
        /// `surfaceId` ölçümü tutulan morfoloji yuvalarının %37'sinin yalnız
        /// yüzey ayrımı için durduğunu gösterdi. O sayı tek başına bir zarar
        /// iddiası değil: yuvalar başka adayların yerini alıyor **olabilir**.
        /// Cevabı veren soru şu — beam genişletilince doğruluk artıyor mu?
        /// Artmıyorsa beam bağlamıyor ve fragmentasyonun ölçülebilir bir bedeli
        /// yok.
        case beamSweep
        /// Kalibrasyon deneyi: sapmalı kullanıcıda öğrenmenin faydası ve zararı.
        case calibration
        /// Bigram paketinin **gecikme** maliyeti (§2 öznitelik 13).
        case bigramLatency
        /// Kişisel sözlük kolu (§8.7): kabul edilen kelime tanınıyor mu, ve
        /// paketteki kelimeleri çalıyor mu.
        case personal
        /// Sözlükte var mı, ne kadar pahalı, hangi kaynaktan — **veri
        /// toplamadan** "klavye bu kelimeyi neden tanımıyor" sorusunun cevabı.
        case lookup
        /// Cihazdan çekilmiş yazım kayıtları (§12).
        case sessions
        /// **v2** fixture üretimi — migrasyon yolunu sınamak için.
        case writeLegacyFixture

        /// Kip kelime listesine ihtiyaç duyuyor mu. Duymayan kip (`--lookup`,
        /// `--sessions`, fixture) liste olmadan da koşabilmeli.
        var needsWords: Bool {
            switch self {
            case .decode, .pruningGap, .beamSweep, .calibration,
                 .bigramLatency, .personal:
                return true
            case .lookup, .sessions, .writeLegacyFixture:
                return false
            }
        }
    }

    /// İstenen kipler, komut satırındaki sırayla (tekrarsız).
    var modes: [Mode] = []

    var packPath = PackPaths.file(.turkish, .forms)
    var wordsPath: String?
    var limit = 2000
    var beamWidth = Decoder.defaultBeamWidth
    var seed: UInt64 = 42
    var morphology = false
    var biasX = 0.0
    var biasY = 0.0
    var sigma = 0.35
    var warmup = 50
    var json = false
    /// Sentetik kök sayısı — başlangıç frontier'ının O(kök) olmasının
    /// gerçekten sorun olup olmadığını ölçmek için.
    var syntheticRoots = 0
    /// Gerçek kök paketi (`.bkr`).
    ///
    /// Sentetik kökler kelime listesinin en sık formlarından üretiliyor; önek
    /// dağılımı, uzunluk dağılımı ve terminal çokluğu gerçek sözlüğü temsil
    /// etmiyor. Ölçek ölçümü sevk edilen veriyle yapılmalı.
    var rootPackPath: String?
    /// İkinci dil paketi — çoklu dilin gecikme ve doğruluk maliyetini ölçmek için.
    var secondLangPath: String?
    var maxOmissions = 4
    /// Taranacak genişlikler. Üretim değeri (`--beam`) her hâlde ekleniyor.
    var beamSweepWidths: [Int] = [32, 64, 128, 256, 512, 1024]
    /// Cihazdan çekilmiş yazım kayıtlarının klasörü (§12).
    var sessionsPath: String?
    var lookup: [String] = []
    /// Kişisel sözlüğe kaç yabancı yüzey konsun — mıknatıs ölçümünün yükü.
    var personalCount = 200
    /// Sentetik bigram paketindeki çift sayısı.
    var bigramPairs = 500_000
    /// Replay'in paketleri **buradan** çözüyor.
    ///
    /// `--pack` ile aynı değil ve olmamalı: bench kendi ölçümü için tek bir
    /// trie yüklüyor, replay ise kayıttaki paket listesini (ikinci dil, kökler,
    /// karakter modeli, genişletmeler) birebir kurmak zorunda. İkisini
    /// karıştırmak replay motorunu kayıttakinden yoksun bırakıp farkı "kod
    /// değişti" diye gösterirdi.
    var packsDir = PackPaths.root
    /// Kalibrasyon kollarını **held-out** ile karşılaştır (§12.8).
    ///
    /// Ayrı bayrak: deney kayıtları okumaktan farklı bir soru soruyor ve
    /// varsayılan raporu şişirmesinin sebebi yok.
    var calibrationArms = false
    /// Dil öncelinin düzeltme kararını ne kadar çevirdiğini ölç.
    var languagePrior = false
    /// Yarım kalmış kayıtları `interrupted` olarak kapat (§12.6).
    ///
    /// Çekilmiş bir kopya da sonsuza dek `recording` kalıyor: ne tamamlanmış ne
    /// vazgeçilmiş sayılabiliyor. **Varsayılan kapalı**: analiz aracının okuduğu
    /// dosyayı yan etki olarak değiştirmesi kabul edilemez, karar açık olmalı.
    var recoverStale = false
    /// Bugünkü kodun revision'ı — yalnız **raporlamak** için.
    ///
    /// Kayıtla farklı olması regression replay'in amacı; ortam uyuşmazlığı
    /// değil (`ReplayEngineFactory.Environment`).
    var currentRevision: String?

    /// **v2** fixture çıktı klasörü.
    ///
    /// Adı önce `--write-fixture`'dı ve golden fixture'ı ürettiği sanılıyordu.
    /// Üretmiyor: v3 fixture'ı üretim yazıcısından geliyor
    /// (`BK_REGENERATE_FIXTURE=1 swift test --filter Fixture`). Bu bayrak eski
    /// `TypingSession` (şema 2) JSON'u yazıyor ve değeri tek bir yerde:
    /// `SessionMigration`'ın diskteki gerçek bir v2 dosyasını okuyabildiğini
    /// sınamak.
    var legacyFixtureDir: String?
    /// Kalibrasyon deneyinde profil başına bağımsız çekiliş sayısı.
    var calibrationRepeats = 4

    /// Kipleri çalıştırma listesi: istenenler, yoksa kod çözme.
    var resolvedModes: [Mode] { modes.isEmpty ? [.decode] : modes }

    private mutating func add(_ m: Mode) {
        if !modes.contains(m) { modes.append(m) }
    }

    static func parse(_ arguments: [String]) -> Options {
        var o = Options()
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--pack":      o.packPath = it.next() ?? o.packPath
            case "--words":     o.wordsPath = it.next()
            case "--limit":     o.limit = Int(it.next() ?? "") ?? o.limit
            case "--beam":      o.beamWidth = Int(it.next() ?? "") ?? o.beamWidth
            case "--seed":      o.seed = UInt64(it.next() ?? "") ?? o.seed
            case "--morphology": o.morphology = true
            case "--bias":
                let parts = (it.next() ?? "").split(separator: ",")
                if parts.count == 2 { o.biasX = Double(parts[0]) ?? 0; o.biasY = Double(parts[1]) ?? 0 }
            case "--sigma":     o.sigma = Double(it.next() ?? "") ?? o.sigma
            case "--warmup":    o.warmup = Int(it.next() ?? "") ?? o.warmup
            case "--json":      o.json = true
            case "--roots":     o.syntheticRoots = Int(it.next() ?? "") ?? 0
            case "--root-pack": o.rootPackPath = it.next(); o.morphology = true
            case "--second-lang": o.secondLangPath = it.next()
            case "--max-om":    o.maxOmissions = Int(it.next() ?? "") ?? 4
            case "--decode":      o.add(.decode)
            case "--pruning-gap": o.add(.pruningGap)
            case "--beam-sweep":  o.add(.beamSweep)
            case "--beam-widths":
                o.beamSweepWidths = (it.next() ?? "").split(separator: ",")
                    .compactMap { Int($0) }.filter { $0 > 0 }
            case "--sessions":
                o.sessionsPath = it.next()
                o.add(.sessions)
            case "--lookup":
                if let w = it.next() { o.lookup.append(w) }
                o.add(.lookup)
            case "--personal":    o.add(.personal)
            case "--personal-count": o.personalCount = Int(it.next() ?? "") ?? o.personalCount
            case "--bigram-latency": o.add(.bigramLatency)
            case "--bigram-pairs": o.bigramPairs = Int(it.next() ?? "") ?? o.bigramPairs
            case "--packs-dir":   o.packsDir = it.next() ?? o.packsDir
            case "--recover-stale": o.recoverStale = true
            case "--calibration-arms": o.calibrationArms = true
            case "--language-prior": o.languagePrior = true
            case "--revision":    o.currentRevision = it.next()
            case "--write-legacy-fixture":
                o.legacyFixtureDir = it.next()
                o.add(.writeLegacyFixture)
            case "--calibration": o.add(.calibration)
            case "--calibration-repeats":
                o.calibrationRepeats = max(1, Int(it.next() ?? "") ?? o.calibrationRepeats)
            case "-h", "--help":
                print(help)
                exit(0)
            default:
                // Tanınmayan bayrak **sessizce yutulmuyor**: yanlış yazılmış bir
                // kip bayrağı varsayılan ölçümü koşturup "istediğin ölçüldü"
                // izlenimi verirdi.
                fail("tanınmayan argüman: \(a) — kbbench --help")
            }
        }
        // `--sessions` olmadan kayıt alt kolları anlamsız: sessizce yok saymak
        // istenen ölçümün yapıldığı izlenimini verirdi.
        if (o.calibrationArms || o.languagePrior || o.recoverStale),
           !o.modes.contains(.sessions) {
            fail("--calibration-arms/--language-prior/--recover-stale --sessions ister")
        }
        return o
    }

    static let help = """
    kbbench — decoder değerlendirme ve gecikme ölçümü

    KİPLER (birden çok verilebilir; verilen sırayla koşar, hiçbiri yoksa --decode):
      --decode            kod çözme doğruluğu ve gecikmesi (varsayılan)
      --pruning-gap       aday budamasının yaklaşım payını ölç
      --beam-sweep        beam genişliği taraması: beam bağlıyor mu (§9)
      --calibration       kalibrasyon deneyi (fayda + ZARAR metrikleri)
      --bigram-latency    F_ctx'in gecikme maliyeti (sentetik paket)
      --personal          kişisel sözlük kolu (§8.7): tanınma + mıknatıs
      --lookup <kelime>   sözlükte var mı, maliyeti ne (tekrarlanabilir)
      --sessions <dir>    cihaz yazım kayıtlarını oku ve yeniden oynat (§12)
      --write-legacy-fixture <dir>
                          v2 (şema 2) fixture'ı yaz — migrasyon testi için;
                          v3 golden fixture'ı swift test üretir

    ORTAK:
      --pack <yol>        dil paketi (varsayılan: \(PackPaths.file(.turkish, .forms)))
      --words <yol>       test kelimeleri (varsayılan: paketin kaynağı)
      --limit <n>         kaç kelime denensin (varsayılan 2000)
      --beam <n>          beam genişliği (varsayılan \(Decoder.defaultBeamWidth))
      --seed <n>          PRNG tohumu — tekrarlanabilirlik için
      --sigma <f>         dokunma gürültüsü ölçeği (varsayılan 0.35)
      --bias <x,y>        sistematik parmak sapması, tuş oranında
      --warmup <n>        ısınma kelimesi sayısı (varsayılan 50)
      --max-om <n>        ardışık omission üst sınırı (varsayılan 4)
      --morphology        morfoloji kaynağını da yükle
      --roots <n>         morfolojiye n sentetik kök ekle (ölçek testi)
      --root-pack <yol>   GERÇEK kök paketi (.bkr) yükle; --morphology'yi açar
      --second-lang <yol> ikinci dil form paketi (.bkt) — çoklu dil maliyeti
      --json              makine okunur çıktı (--decode; CI kapısı için)

    KİP AYARLARI:
      --beam-widths a,b,c taranacak genişlikler (varsayılan 32…1024)
      --calibration-repeats <n>  profil başına çekiliş (varsayılan 4)
      --bigram-pairs <n>  sentetik paketteki çift sayısı (500k)
      --personal-count <n>  sözlüğe konacak yabancı yüzey sayısı (200)
      --packs-dir <dir>   replay'in paket kökü (varsayılan \(PackPaths.root))
      --revision <rev>    bugünkü kodun revision'ı (yalnız rapor)
      --recover-stale     yarım kayıtları interrupted olarak kapat (dosyayı değiştirir)
      --calibration-arms  kalibrasyon kollarını held-out karşılaştır (--sessions ile)
      --language-prior    dil öncelinin düzeltme kararına etkisi (--sessions ile)

    UYARI: doğruluk sayıları SİMÜLE edilmiş dokunmalardan gelir.
    Gaussian decoder'ı Gaussian gürültüyle test etmek model doğrulaması
    değildir (§9). Bu araç regresyon tespiti içindir.
    """
}
