import Foundation
import CryptoKit
import KBGeometry
import KBSpatial
import KBLexicon
import KBMorphology
import KBDecoder
import KBRuntime

/// Dil paketlerini yükler ve decoder'ı kurar.
///
/// ## Neden çekirdekte
///
/// Bu tip `Apps/BestKeyboardExtension/` altındaydı ve paket içindeki replay
/// factory ona erişemiyordu — yani replay motoru **ikinci bir kez** kurulmak
/// zorunda kalacaktı. Motoru iki yerde kurmanın bedeli zaten bir kez ödendi:
/// kayıt ekranı kanal yapılandırmasını atlayınca "davranış kaydı", OOV
/// düzeltmesi büyük ölçüde **kapalı** bir klavyeyi ölçüyordu. Kurulum tek
/// yerde olmazsa aynı hata başka bir biçimde geri gelir.
///
/// Uzantı, uygulama içi tezgah, kayıt ekranı ve replay factory: dördü de
/// buradan geçer.
///
/// Diller **aynı beam'de** yaşar, layout değişmez (§5b): Türkçe Q,
/// İngilizce QWERTY'nin harf kümesini zaten kapsıyor.
///
/// Paketler:
///   `tr-TR.bkt` — form listesi (70k yüzey formu)
///   `tr-TR.bkr` — kök sözlüğü (morfoloji); **opsiyonel**, yoksa yalnız
///                 form listesiyle çalışılır
///   `tr-TR.bkc` — literal kanalının karakter n-gram modeli; **opsiyonel**,
///                 yoksa `cost(literal)` sabit bir yedeğe düşer ve
///                 `literalChannel.isCalibrated` bunu bildirir
///   `en-US.bkt` — ikinci dil; **opsiyonel**
///
/// Morfoloji, form listesinin prensip olarak kapatamayacağı kuyruğu kapatır:
/// `kalemlerimizden` hiçbir korpusta geçmiyor ama kökten türetilebiliyor.

/// Dil kimlikleri. `UInt8` çünkü decoder durumunda tek bayt yer kaplıyor;
/// aynı anda en fazla 2 dil aktif olacağı için (plan kararı) fazlası gereksiz.
public enum Language {
    public static let turkish: UInt8 = 0
    public static let english: UInt8 = 1
}

/// Paketlerin nereden okunacağı.
///
/// Uygulama bundle'dan okuyor, replay factory ise diskteki bir dizinden. İkisi
/// aynı yükleme kodunu paylaşmazsa "replay üretimle aynı motoru kuruyor"
/// iddiası doğrulanamaz hâle gelir.
public protocol PackSource {
    /// mmap'lenmiş veri ve geldiği konum; paket yoksa `nil`.
    func read(_ name: String, _ ext: String) -> (url: URL, data: Data)?
}

/// Uygulama/uzantı yolu: paketler bundle kaynağı olarak gömülü.
public struct BundlePackSource: PackSource {
    private let bundle: Bundle
    public init(bundle: Bundle) { self.bundle = bundle }

    public func read(_ name: String, _ ext: String) -> (url: URL, data: Data)? {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              // mmap — paket ayrıştırılmaz, eşlenir ve sahiplenilir (§11.A/D).
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return (url, data)
    }
}

/// Replay yolu: `LanguagePacks/` ağacı ya da düz bir dizin.
public struct DirectoryPackSource: PackSource {
    private let root: URL
    public init(root: URL) { self.root = root }

    public func read(_ name: String, _ ext: String) -> (url: URL, data: Data)? {
        // İki düzen de destekleniyor: `root/tr-TR.bkt` ve
        // `root/tr-TR/tr-TR.bkt` (depodaki `LanguagePacks/` böyle).
        for url in [root.appendingPathComponent("\(name).\(ext)"),
                    root.appendingPathComponent(name)
                        .appendingPathComponent("\(name).\(ext)")] {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                return (url, data)
            }
        }
        return nil
    }
}

public enum PackLoader {

    public struct Loaded {
        public let decoder: Decoder
        public let trie: FormTrie
        public let literalChannel: LiteralChannel
        public let expansions: ExpansionMap?
        public let report: String
        /// **Fiilen yüklenen** paketlerin kimliği — sözleşme §12.7.
        ///
        /// Kayıt/replay için zorunlu: `appVersion` yetmez, aynı binary farklı
        /// paketle koşabilir. Bu liste olmadan replay farkının "değişiklik mi,
        /// ortam mı" olduğu ayırt edilemez.
        ///
        /// Yüklenmeye **çalışılan** değil, yüklenen kaydediliyor: opsiyonel
        /// paketler (ikinci dil, argo, genişletme) bulunamazsa listede olmaz.
        public let packs: [PackRef]
    }

    public struct PackRef {
        public let name: String
        /// **Yalnız istenirse** hesaplanır.
        ///
        /// 3+ MB üzerinde SHA hesaplamak klavye açılışına bedelsiz olmayan bir
        /// iş ekliyor ve üretim yolunun buna ihtiyacı yok. `nil` = "kayıt
        /// kapalıydı, hesaplanmadı".
        public let sha256: String?
        public let bytes: Int
        public let role: PackRole
        public let language: UInt8
        /// `LexiconSet.sources` içindeki sıra. Sözlük kaynağı **olmayan**
        /// paketlerde (karakter modeli, genişletme) `nil`.
        public let sourceOrder: Int?
        /// Kaynak maliyet ofseti; yalnız sözlük kaynaklarında anlamlı.
        public let offset: Double?
    }

    /// Bir paketin kimliğini **zaten okunmuş** veriden çıkarır.
    ///
    /// Dosyayı ikinci kez okumuyor: ilk sürüm `Data(contentsOf:)`'ı tekrar
    /// çağırıyordu ve bu, kayıt kapalıyken bile klavye açılışına fazladan I/O
    /// ekliyordu — kayıt özelliği için üretim yolunu yavaşlatmak kabul edilemez.
    private static func packRef(_ url: URL, _ data: Data, hash: Bool,
                                role: PackRole, language: UInt8,
                                sourceOrder: Int? = nil,
                                offset: Double? = nil) -> PackRef {
        PackRef(name: url.lastPathComponent,
                sha256: hash
                    ? SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }.joined()
                    : nil,
                bytes: data.count, role: role, language: language,
                sourceOrder: sourceOrder, offset: offset)
    }

    /// - Parameter computeHashes: paket SHA-256'larını üret.
    ///   **Varsayılan kapalı**: üretim yolunun bunlara ihtiyacı yok ve 3+ MB
    ///   üzerinde SHA hesaplamak klavye açılışına bedelsiz olmayan bir iş ekler.
    ///   Yalnız yazım kaydı (§12) açar — orada replay'in birebirliği buna bağlı.
    ///
    ///   Paket **listesi** her hâlde üretilir; ücretli olan yalnız özet.
    /// - Parameter weights: skor modeli. Üretim varsayılanı kullanıyor;
    ///   **replay** kayıttaki değerleri geçiyor. Motoru replay için ikinci kez
    ///   kurmak yerine aynı kurulumu parametreleştirmek, "replay üretimle aynı
    ///   motoru kuruyor" iddiasını doğrulanabilir tutuyor.
    /// - Parameter sigmaMin: uzamsal modelin alt sınırı; aynı gerekçe.
    public static func load(layout: KeyLayout, source: PackSource,
                            beamWidth: Int = 128,
                            weights: ScoreWeights = ScoreWeights(),
                            sigmaMin: Double = 0.012,
                            computeHashes: Bool = false) throws -> Loaded {
        let t0 = CFAbsoluteTimeGetCurrent()
        let h = computeHashes

        guard let (trieURL, trieData) = source.read("tr-TR", "bkt") else {
            throw NSError(domain: "pack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "tr-TR.bkt bulunamadı"])
        }
        let trie = try FormTrie(data: trieData)
        var loadedPacks: [PackRef] = []

        // Sözlük kaynakları **yüklenirken** kuruluyor ki `sourceOrder` gerçekten
        // decoder'ın gördüğü sıra olsun; sırayı ayrı bir yerde yeniden saymak,
        // aynı bilginin ikinci bir yerde de doğru tutulmasına bel bağlamaktı.
        var sources: [LexiconSet.Source] = [.forms(trie, language: Language.turkish)]
        loadedPacks.append(packRef(trieURL, trieData, hash: h, role: .forms,
                                   language: Language.turkish,
                                   sourceOrder: sources.count - 1, offset: 0))

        var rootCount = 0
        if let (rootURL, rootData) = source.read("tr-TR", "bkr"),
           let pack = try? RootPack(data: rootData) {
            sources.append(.morphology(MorphologyAutomaton(roots: pack.roots),
                                       language: Language.turkish))
            rootCount = pack.roots.count
            loadedPacks.append(packRef(rootURL, rootData, hash: h, role: .roots,
                                       language: Language.turkish,
                                       sourceOrder: sources.count - 1, offset: 0))
        }

        // İkinci dil — opsiyonel. Yoksa tek dille çalışılır ve kod yolu aynıdır
        // (§5b: "Faz 1'den itibaren aynı kod yolu, tek dilde bile").
        var hasEnglish = false
        if let (enURL, enData) = source.read("en-US", "bkt"),
           let en = try? FormTrie(data: enData) {
            // `offset` ölçümle geldi (`kbdiag --scale`): iki listede ortak 12 108
            // yüzeyde maliyet farkının medyanı +0.20 nat, çeyrekler arası
            // genişlik 1.39 nat. Yani paketler zaten uyumlu ölçekte —
            // sıfır bırakmak yerine ölçülen değeri koyuyoruz, ama büyüklüğü
            // gürültü mertebesinde olduğu için tek başına bir şeyi çevirmez.
            let offset = -0.20
            sources.append(.forms(en, language: Language.english, offset: offset))
            hasEnglish = true
            loadedPacks.append(packRef(enURL, enData, hash: h, role: .forms,
                                       language: Language.english,
                                       sourceOrder: sources.count - 1,
                                       offset: offset))
        }

        // Karakter modeli **dil başına**. İkincisini üretip yüklememek,
        // İngilizce sözlük dışı kelimelerin Türkçe modelle puanlanması
        // demekti — Türkçeye göre implausible görünüp düzeltilirlerdi.
        var charModels: [CharNGram] = []
        for (name, lang) in [("tr-TR", Language.turkish),
                             ("en-US", Language.english)] {
            guard let (u, d) = source.read(name, "bkc"),
                  let m = try? CharNGram(packData: d) else { continue }
            charModels.append(m)
            loadedPacks.append(packRef(u, d, hash: h, role: .charModel,
                                       language: lang))
        }

        // Gayrıresmî katman (§4.B) **ayrı bir kaynak değil**: `packbuild
        // --informal` onu form listesiyle birleştirip tek trie üretiyor.
        //
        // Ayrı kaynak olarak yüklemek §7'yi ihlal ediyordu: aynı yüzey iki
        // trie'de bulunduğunda decoder ucuz olanı seçiyor, oysa listeler farklı
        // toplamlara göre normalize edilmiş ve maliyetleri karşılaştırılamaz.
        // Ayrı DOSYA olarak durması yazım kolaylığı ve lisans ayrımı içindir.

        // Kelime bigramı (§2 öznitelik 13) — **opsiyonel**.
        //
        // Paket yoksa `F_ctx ≡ 0` ve motor paketsiz davranışını birebir
        // koruyor: görülmemiş çift de zaten 0 aldığı için "paket yok" ile
        // "hiçbir çift bilinmiyor" aynı motor. Yani özellik kendi verisi
        // gelene kadar sessizce kapalı, ayrı bir bayrağa gerek yok.
        var bigrams: BigramPack?
        if let (u, d) = source.read("tr-TR", "bkg"),
           let pack = try? BigramPack(packData: d) {
            bigrams = pack
            loadedPacks.append(packRef(u, d, hash: h, role: .bigrams,
                                       language: Language.turkish))
        }

        var expansions: ExpansionMap?
        if let (u, d) = source.read("tr-TR", "bkx"),
           let m = try? ExpansionMap(packData: d) {
            expansions = m
            loadedPacks.append(packRef(u, d, hash: h, role: .expansions,
                                       language: Language.turkish))
        }

        // **Genişletmeler kısaltmaların bilinmesine bağlıdır.**
        //
        // `slm`'nin otomatik açılmamasının tek güvencesi onun sözlükte olması
        // (`θ = ∞`). Kısaltmalar form paketinde birleşik geliyor; bir anahtar
        // sözlükte değilse ona açılım önermek tutarsız olurdu — üstelik o
        // token korumasız demektir ve decoder onu başka bir yüzeye çevirebilir.
        //
        // O yüzden açılımlar **doğrulanır**: anahtarı sözlükte olmayan girdiler
        // atılır. Böylece iki paket birbirinden bağımsız yüklense de tutarsız
        // bir durum oluşamaz.
        var informalKnown = 0
        if let m = expansions {
            let verified = m.entries.filter { trie.lookup($0.0) != nil }
            informalKnown = verified.count
            expansions = verified.isEmpty ? nil : ExpansionMap(entries: verified)
        }

        let lexicon = LexiconSet(sources: sources)
        var decoder = Decoder(layout: layout,
                              spatial: SpatialModel(layout: layout,
                                                    sigmaMin: sigmaMin),
                              lexicon: lexicon,
                              weights: weights,
                              beamWidth: beamWidth)
        decoder.bigrams = bigrams
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let roots = rootCount > 0 ? "\(rootCount) kök" : "morfoloji yok"
        let langs = hasEnglish ? " · tr+en" : " · tr"
        // Literal kanalının kalibre olup olmadığı raporda: commit kararının
        // ne kadar güvenilir olduğunu belirleyen tek şey bu.
        let lit = charModels.isEmpty ? " · literal yedek" : ""
        let inf = informalKnown > 0 ? " · argo \(informalKnown)" : ""
        let report = String(format: "%d düğüm · %@%@%@%@ · %.0f ms",
                            trie.nodeCount, roots, langs, lit, inf, ms)
        // Kanal yapılandırması **burada**, çağıranda değil.
        //
        // Eskiden `KeyboardViewController` yükledikten sonra `weights` ve
        // `autoCorrectsOutOfVocabulary`'yi kendisi ayarlıyordu; kayıt ekranı
        // bunu yapmayı atlayınca "davranış kaydı" üretim davranışını değil,
        // OOV düzeltmesi büyük ölçüde KAPALI bir klavyeyi ölçüyordu. İki
        // çağıranın aynı motoru kurması ancak kurulum tek yerdeyse garanti.
        var channel = LiteralChannel(vocabulary: lexicon, charModels: charModels)
        channel.weights = decoder.weights
        // Bigram **kanala da** veriliyor: `Δ = cost(literal) − cost(best)` iki
        // tarafı da `F_ctx` taşımalı, yoksa eşik sessizce kayar.
        channel.bigrams = bigrams
        // §8.1 kapısı AÇIK: ölçüm yenilendi (§8.1.1).
        channel.autoCorrectsOutOfVocabulary = true

        return Loaded(decoder: decoder, trie: trie,
                      literalChannel: channel,
                      expansions: expansions,
                      report: report,
                      packs: loadedPacks)
    }

    /// Bundle'dan yükleyen kısayol — uygulama ve uzantının kullandığı yol.
    public static func load(layout: KeyLayout, bundle: Bundle,
                            beamWidth: Int = 128,
                            computeHashes: Bool = false) throws -> Loaded {
        try load(layout: layout, source: BundlePackSource(bundle: bundle),
                 beamWidth: beamWidth, computeHashes: computeHashes)
    }
}
