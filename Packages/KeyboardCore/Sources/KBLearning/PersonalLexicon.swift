import Foundation
import KBGeometry

/// Kullanıcının kendi kelimeleri — skor sözleşmesi §8.7.
///
/// ## Neyi çözüyor
///
/// §8.1.1'de OOV otomatik düzeltme kapısı açıldı: sözlük dışı bir token
/// `Δ > θ` ise düzeltiliyor. Ölçüm bunun typo'ların %82'sini düzelttiğini ve
/// doğru yazılmış OOV'lerin %0'ını bozmadığını gösterdi — ama o örneklemde
/// **tekrar eden** bir OOV yoktu. Kendi adını günde otuz kez yazan kullanıcı
/// için "%0" doğru olsa bile yanlış soruya cevap: klavye o kelimeyi her
/// seferinde yeniden yargılıyor ve bir kez yanılması yetiyor.
///
/// Kişisel sözlük o kelimeyi `V`'ye sokar. Sonucu iki katlı:
/// - `LiteralChannel.Score.isInVocabulary` → `θ = ∞`, kelime artık **bozulamaz**;
/// - decoder kaynağı olur, yani yanlış dokunmalardan da geri kurtarılabilir.
///
/// ## Ne kaydedilmez
///
/// Yalnız **yüzey** ve kaç kez doğrulandığı. Dokunma koordinatı, zaman damgası,
/// hangi uygulamada yazıldığı: hiçbiri. Parola alanında hiç çalışmaz
/// (`InputCoordinator.fieldIsSecure`).
///
/// ## Puan, sayım değildir
///
/// `points` bir frekans tahmini **değil**, kabul için biriken kanıttır. Kabul
/// edilen kelimenin maliyeti puanına bağlı değil (bkz. `lexCost`) — üç kez
/// yazılmış bir kelimenin ne kadar sık olduğunu bilmiyoruz ve bilmediğimizi
/// model gibi göstermek §8.6'da bir kez çürütülen hatanın aynısı olurdu.
public struct PersonalLexicon: Equatable, Sendable {

    /// Kanıtın gücü — `CalibrationLearner` ile aynı ayrım, aynı gerekçe.
    public enum Confidence: Sendable, Equatable {
        /// Kullanıcı yazdı, klavye dokunmadı, kullanıcı da düzeltmedi.
        ///
        /// **Zayıf**: düzeltmemek onaylamak değildir (plan §3). Kullanıcı
        /// üşenmiş, fark etmemiş ya da acele etmiş olabilir.
        case weak
        /// Kullanıcı **kendi yazdığı yüzeyi** öneri çubuğundan seçti.
        ///
        /// Güçlü: klavye ona bir alternatif göstermişken kendi yazdığında ısrar
        /// etti. Bu bir niyet beyanıdır.
        case strong
    }

    public struct Entry: Equatable, Sendable {
        public var points: Int
        /// Kayıt sırası — kapasite dolduğunda yaş ölçütü.
        ///
        /// **Saat değil.** Zaman damgası hem kişisel veri olurdu hem de
        /// cihaz saatinin geri alınmasına bağımlı; sıra numarası ikisini de
        /// taşımıyor.
        public var seq: UInt32

        public init(points: Int, seq: UInt32) {
            self.points = points
            self.seq = seq
        }
    }

    // MARK: - Politika sabitleri

    public static let weakPoints = 1
    public static let strongPoints = 3
    /// Kabul eşiği. **Asimetriden** seçildi (§5c'nin aynı muhakemesi): yanlış
    /// kabul aktif zarardır — typo `V`'ye girer, `θ = ∞` olur ve bir daha
    /// düzeltilmez; geç kabul yalnız faydayı erteler. O yüzden eşik korumadan
    /// yana: ya bir kez **açık** seçim, ya üç ayrı literal commit.
    public static let admissionPoints = 3
    /// Puan tavanı — dosya alanı `UInt16` ve sıralama zaten doyuyor.
    public static let maxPoints = 1000
    /// Saklanan yüzey sayısı sınırı. Aşılınca en az kanıtlı, eşitlikte en eski
    /// girdi düşer.
    public static let capacity = 512
    /// Tek harfli yüzeyler kabul edilmez: her yanlış dokunma bir aday üretirdi.
    public static let minLength = 2
    /// (I1) yüzey uzunluk sınırı.
    public static let maxLength = LexiconLimits.maxSurfaceLength

    /// Kabul edilmiş bir kişisel kelimenin **ham** `F_lex`'i (§7).
    ///
    /// ## Neden tek sabit, neden puandan bağımsız
    ///
    /// Kişisel sayımları kendi toplamlarına normalize etmek (`−log(n/Σn)`)
    /// paket ölçeğiyle **karşılaştırılamaz** bir maliyet üretirdi — argo
    /// katmanını ayrı kaynak olarak yüklerken bir kez yapılan hatanın aynısı
    /// (bkz. `PackLoader`: *"farklı toplamlara göre normalize edilmiş ve
    /// maliyetleri karşılaştırılamaz"*). Elimizde 3 gözlem var; ondan frekans
    /// çıkarmak, veriden gelmeyen bir modeli veri gibi göstermek olurdu.
    ///
    /// ## Değer taramayla seçildi, çıkarımla değil
    ///
    /// İlk hâli paketin en pahalı ucuna çıpalanmıştı: `wordlist.tsv` üzerinde
    /// `−log(freq/total)` dağılımı `tr-TR` için min 3.66 · medyan 12.91 ·
    /// p95 13.80 · **maks 14.57**, ve *"korpusun hiç görmediği kelime, listeye
    /// giren en nadirden nadirdir"* gerekçesiyle 14.6 seçilmişti. Gerekçe
    /// tutarlıydı ama **ölçüm onu çürüttü**: o değerde kullanıcı kendi
    /// kelimesini dikkatle yazdığında bile yalnız %56'sı geri geliyordu.
    ///
    /// `kbbench --personal` çıpayı taradı (aynı dokunmalar, tek değişken):
    ///
    /// ```
    /// F_lex   tanınma-dikkatli  tanınma-günlük   paket top1     çalınan
    ///  14.6      56.2%             24.8%         87.83% (+0.00)     0
    ///  12.9      91.0%             69.0%         87.83% (+0.00)     0
    ///  11.5      95.7%             81.4%         87.83% (+0.00)     0
    ///  10.0      98.6%             87.6%         87.83% (+0.00)     0
    ///   9.0     100.0%             91.9%         87.70% (−0.13)     2
    ///   6.0     100.0%             94.8%         87.50% (−0.33)     5
    /// ```
    ///
    /// Zarar **tam olarak sıfır** — 14.6'dan 10.0'a kadar tek bir paket
    /// kelimesi bile bozulmuyor; ilk zarar 9.0'da görülüyor. Aynı eğri sözlük
    /// 4 katına (810 yüzey) çıkarıldığında da aynı yerde kırılıyor, yani
    /// plato sözlük boyutuna duyarlı değil.
    ///
    /// Sıfır-zarar platosunun içinde seçim artık tanınmaya bakar: **11.5**,
    /// gözlenen ilk zarardan 2.5 nat, platonun kenarından 1.5 nat uzakta.
    /// §5c asimetrisi bu payı istiyor — ölçüm 1496 kelimelik bir örneklemde
    /// yapıldı ve "sıfır" bir üst sınır değil, o örneklemdeki gözlem.
    ///
    /// Değerin paket medyanının (12.91) **altında** olması bilinçli: kelime
    /// korpusta nadir olabilir ama onu üç kez yazmış olan kullanıcı için nadir
    /// değildir. Çıpa paketin dağılımını değil, o kullanıcının dağılımını
    /// temsil ediyor.
    ///
    /// **Popülasyon vekil.** Ölçümün kişisel yüzeyleri İngilizce listeden
    /// alındı (tr paketinde ve morfolojisinde bulunmayanlar) + elle yazılmış
    /// on gerçek vaka. Gerçek kullanıcının kelimeleri değil; mekanizmanın
    /// çalıştığını gösterir, kullanıcı popülasyonunda kazanç iddiası değildir.
    public static let lexCost = 11.5

    // MARK: - Durum

    public private(set) var entries: [String: Entry]
    private var nextSeq: UInt32

    public init() {
        self.entries = [:]
        self.nextSeq = 0
    }

    /// Depodan yükleme yolu.
    public init(entries: [String: Entry]) {
        self.entries = entries
        self.nextSeq = (entries.values.map(\.seq).max().map { $0 &+ 1 }) ?? 0
    }

    // MARK: - Kanonik yüzey

    /// Leksikal anahtar — §7 kanonik yüzey kimliğiyle **aynı** kural.
    ///
    /// Uygun olmayan yüzeyde `nil`: rakam, noktalama, çok skalerli grapheme,
    /// sınır dışı uzunluk. Küçük harfe çevirme Türkçeye duyarlı (`I → ı`,
    /// `İ → i`); locale'siz çevirmek `İ`'yi iki skalere (`i` + birleşen nokta)
    /// açar ve trie sembol birimi tek skaler olduğu için kelime sessizce
    /// reddedilirdi.
    public static func canonical(_ surface: String) -> String? {
        let lowered = TurkishText.key(surface)
        guard lowered.count >= minLength, lowered.count <= maxLength else { return nil }
        for g in lowered {
            guard g.unicodeScalars.count == 1, g.isLetter else { return nil }
        }
        return lowered
    }

    // MARK: - Gözlem

    /// Bir commit'i kanıt olarak işler.
    ///
    /// - Returns: **kabul edilmiş küme** değiştiyse `true`. Yalnız o durumda
    ///   motorun yeniden kurulması gerekir; puan biriktiren ama henüz eşiği
    ///   geçmemiş bir gözlem decoder'ı ilgilendirmez.
    @discardableResult
    public mutating func observe(_ surface: String,
                                 confidence: Confidence) -> Bool {
        guard let key = Self.canonical(surface) else { return false }
        let wasAdmitted = isAdmitted(key)

        var entry = entries[key] ?? Entry(points: 0, seq: nextSeq)
        if entries[key] == nil { nextSeq &+= 1 }
        entry.points = min(entry.points + (confidence == .strong ? Self.strongPoints
                                                                : Self.weakPoints),
                           Self.maxPoints)
        entries[key] = entry

        let admittedNow = !wasAdmitted && isAdmitted(key)
        // `||` sırası önemli: yeni kelime kabul edilip hemen ardından
        // kapasiteye kurban gitse bile küme değişmiş sayılır — gereksiz bir
        // yeniden kurulum zararsız, atlanan bir kurulum decoder'ı yalanlar.
        return evictIfNeeded() || admittedNow
    }

    /// Kapasite taşmasını karşılar.
    ///
    /// Ölçüt (puan, yaş): en az kanıtlı, eşitlikte en eski düşer. Yeni gelen
    /// girdi de bu sıralamaya dahil — dolayısıyla **tamamı kabul edilmiş** dolu
    /// bir sözlükte tek bir zayıf gözlem hiçbir şeyi değiştirmez, kendisi
    /// düşer. Bilinçli: alternatif, kanıtı çok daha güçlü bir yüzeyi tek bir
    /// gözlem uğruna atmaktı. Kullanıcı yer açmak isterse `forget` var.
    ///
    /// - Returns: düşenlerden en az biri **kabul edilmiş** miydi.
    private mutating func evictIfNeeded() -> Bool {
        guard entries.count > Self.capacity else { return false }
        let excess = entries.count - Self.capacity
        let victims = entries.sorted {
            $0.value.points != $1.value.points
                ? $0.value.points < $1.value.points
                : $0.value.seq < $1.value.seq
        }.prefix(excess)

        var droppedAdmitted = false
        for (key, entry) in victims {
            if entry.points >= Self.admissionPoints { droppedAdmitted = true }
            entries.removeValue(forKey: key)
        }
        return droppedAdmitted
    }

    // MARK: - Sorgu

    public func isAdmitted(_ surface: String) -> Bool {
        guard let key = Self.canonical(surface) else { return false }
        return (entries[key]?.points ?? 0) >= Self.admissionPoints
    }

    /// Decoder'a verilecek yüzeyler. Sıralı — aynı durumdan aynı trie üretilsin.
    public var admitted: [String] {
        entries.filter { $0.value.points >= Self.admissionPoints }
            .keys.sorted()
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Korpus içe aktarımı

    public struct IngestReport: Equatable, Sendable {
        /// Verilen token sayısı.
        public let tokens: Int
        /// Kanonikleşen ve `V` dışında olan **tekil** yüzey sayısı.
        public let candidates: Int
        /// Bu içe aktarımla **yeni** kabul edilenler.
        public let admitted: [String]
        /// Kabul edilmiş küme değişti mi — çağıran motoru kurmalı.
        public var changed: Bool { !admitted.isEmpty }

        public init(tokens: Int, candidates: Int, admitted: [String]) {
            self.tokens = tokens
            self.candidates = candidates
            self.admitted = admitted
        }
    }

    /// Kullanıcının kendi metninden kelime öğrenir (§8.7 korpus içe aktarımı).
    ///
    /// ## Neden metin değil **token** alıyor
    ///
    /// Tokenizer tek (§2.3): `PromptTokenizer` — maksimal layout-harf dizileri,
    /// NFC, Türkçeye duyarlı küçültme. Burada ikinci bir bölücü yazmak, `Wi-Fi`
    /// ve `Caddesi'ne` gibi vakalarda kayıtla içe aktarımın farklı token
    /// üretmesi demekti. Bölme çağıranda, çünkü tokenizer `KeyLayout` istiyor ve
    /// bu modül geometriye bakmıyor.
    ///
    /// ## Tekrar sayısı = puan, ama **doyurulmuş**
    ///
    /// Metinde üç kez geçen yüzey kabul edilir; bir kez geçen yalnız puan
    /// biriktirir. Yazarak öğrenmeyle **aynı eşik**, ayrı bir sabit yok.
    ///
    /// Katkı `admissionPoints` ile sınırlı ve puan **düşürülmüyor**: aynı metni
    /// iki kez aktarmak sonucu değiştirmiyor (idempotent) ve bin kez geçen bir
    /// kelime, eviction sıralamasında diğerlerini ezecek kadar puan biriktirmiyor.
    /// Sınır olmasaydı tek bir içe aktarım, yazarak öğrenilmiş kelimeleri
    /// kapasite baskısı altında kurban ederdi.
    ///
    /// - Parameter isKnown: yüzey `V`'de mi (form listesi ∪ morfoloji). Bilinen
    ///   yüzeyler hiç girmiyor: §7 süzgeci kaynağı kurarken zaten eler, ama
    ///   depoyu paket kelimeleriyle doldurmanın anlamı yok — kapasiteyi
    ///   kullanıcının gerçek kelimeleri hak ediyor.
    @discardableResult
    public mutating func ingest(tokens: [String],
                                isKnown: (String) -> Bool) -> IngestReport {
        var counts: [String: Int] = [:]
        for t in tokens {
            guard let key = Self.canonical(t) else { continue }
            counts[key, default: 0] += 1
        }

        var admittedNow: [String] = []
        var candidates = 0
        for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
            guard !isKnown(key) else { continue }
            candidates += 1
            let wasAdmitted = (entries[key]?.points ?? 0) >= Self.admissionPoints
            var entry = entries[key] ?? Entry(points: 0, seq: nextSeq)
            if entries[key] == nil { nextSeq &+= 1 }
            entry.points = max(entry.points, min(count, Self.admissionPoints))
            entries[key] = entry
            if !wasAdmitted, entry.points >= Self.admissionPoints {
                admittedNow.append(key)
            }
        }
        // Taşma **kabulden sonra**: yeni gelenler de sıralamaya girsin.
        _ = evictIfNeeded()
        // Kurban edilmiş olabilirler; rapor fiilen duran kümeyi anlatmalı.
        admittedNow.removeAll { entries[$0] == nil }
        return IngestReport(tokens: tokens.count, candidates: candidates,
                            admitted: admittedNow)
    }

    // MARK: - Kullanıcı müdahalesi

    /// Bir yüzeyi tamamen unutur. Kullanıcı yanlışlıkla öğretilmiş bir typo'yu
    /// silebilmeli — aksi halde `θ = ∞` koruması onu kalıcı kılardı.
    /// - Returns: kabul edilmiş küme değişti mi.
    @discardableResult
    public mutating func forget(_ surface: String) -> Bool {
        guard let key = Self.canonical(surface), let e = entries[key] else { return false }
        entries.removeValue(forKey: key)
        return e.points >= Self.admissionPoints
    }

    public mutating func removeAll() {
        entries.removeAll()
        nextSeq = 0
    }
}
