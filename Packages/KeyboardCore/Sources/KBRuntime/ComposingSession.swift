import KBGeometry
import KBSpatial

/// Yazılmakta olan token'ın durumu + commit edilmiş kelimelerin geri dönüş yığını.
///
/// ## Üç paralel dizi, üç ayrı iş
///
/// | Alan | Ne | Kim tüketir |
/// |---|---|---|
/// | `touches` | uzamsal kanıt | decoder |
/// | `literal` | kullanıcının gerçekte bastığı harfler | `cost(literal)`, `θ` (§8) |
/// | `display` | belgede **şu an duran** karakterler | belge düzenlemeleri |
///
/// Taze yazımda `display == literal`. Otomatik düzeltmeden sonra ayrışırlar:
/// `lslem` yazıldı, belgede `kalem` duruyor. Silme sayısını `literal`'den
/// hesaplamak bu yüzden hataydı — belgeden yanlış sayıda karakter silinirdi.
///
/// ## Değişmez: `touches.count == literal.count`
///
/// Dokunma `i` her zaman literal karakter `i`'nin kanıtıdır. `display` bu
/// eşlemenin dışındadır ve **uzunluğu farklı olabilir**.
///
/// Ayrışmış bir yüzeyin **içinden** silmek bu eşlemeyi kurtarılamaz biçimde
/// bozar: belgede `kalem` dururken hangi dokunmanın `m`'yi ürettiği bilinmez.
/// O anda kanıt **kopar** (`isDetached`) — token'ın kalanı düz klavye gibi
/// çalışır, öneri ve otomatik düzeltme kapanır. Üç diziden körlemesine birer
/// öğe eksiltmek alternatifiydi; o yol decoder'ı başka bir metnin kanıtıyla
/// çalıştırıp yanlış yüzeyi commit ediyordu.
///
/// ## Neden `KBRuntime`'da
///
/// Bu bir kullanıcı arayüzü davranışı değil, **host senkronizasyon durumu**.
/// Uzantı hedefinde dursaydı hiç test edilemezdi; buradaki hâliyle
/// `swift test` altında koşuyor.
public struct ComposingSession: Sendable {

    /// Bir işlemden sonra decoder'ın ne yapması gerektiği.
    ///
    /// Artımlı kod çözme (§11.C.1) yalnız `.appended` durumunda korunur; geri
    /// kalanında beam yeniden kurulur. Bu ayrım tutulmazsa ya her tuşta karesel
    /// maliyet ödenir ya da beam bayat kalır.
    public enum Outcome: Equatable, Sendable {
        /// Hiçbir şey değişmedi.
        case unchanged
        /// Tek dokunma eklendi — beam bir adım uzatılabilir.
        case appended
        /// Dokunma dizisi değişti — beam sıfırdan kurulmalı.
        case rebuilt
        /// Token kapandı — beam sıfırlanmalı.
        case cleared
    }

    /// Yıkıcı bir işlemin sonucu: beam'e ne yapılacağı **ve** olgunun kendisi.
    ///
    /// İkisi ayrı dönmeli. `Outcome` motorun ne yapacağını söylüyor; olgu ise
    /// kayda giriyor ve reducer onu katlıyor. Olguyu bir yan kanalda
    /// (`lastEffect` gibi) saklamak, aynı bilginin iki yerde tutulması ve
    /// çağrılar arasında bayatlaması demekti.
    public struct Deletion: Sendable {
        public var outcome: Outcome
        /// Olgu **bilinmeyebilir**.
        ///
        /// `contextBeforeInput` `nil` dönen bir host'ta (güvenli alan, bağlamı
        /// gizleyen uygulama) `deleteBackward` yine çalışıyor ama neyi sildiğini
        /// göremiyoruz. Bunu "belge boş, hiçbir şey silinmedi" diye kaydetmek
        /// sahte olgu üretiyordu — gerçek bir karakter gidiyor ve kayıt
        /// gitmediğini söylüyordu.
        public var effect: Epistemic<DestructiveEffect>

        public init(_ outcome: Outcome, _ effect: DestructiveEffect) {
            self.outcome = outcome; self.effect = .known(effect)
        }

        public init(_ outcome: Outcome, unobservable: Void) {
            self.outcome = outcome; self.effect = .unknown
        }
    }

    /// Boşlukla kapatılmış, geri dönülebilir bir kelime.
    struct Committed: Sendable {
        /// Bu token'ın kararlı kimliği — yıkıcı etkilerin hedefi.
        ///
        /// Kimlik olmadan "son token" ifadesi art arda silmede belirsiz:
        /// iki `deleteWord` üst üste geldiğinde ikisi de "sonuncu"yu
        /// işaretliyordu ve kayıt yanlış token'ı silinmiş gösteriyordu.
        var tokenID: TokenID
        var touches: [TouchSample]
        var literal: String
        var display: String
        /// Kanıt **türetilmiş** miydi. Geri açılan token lekeyi de geri
        /// yüklemeli: yoksa `⌫` ile geri dönüp boşluğa basmak, sentetik yazılmış
        /// bir kelimeyi gerçek gözlem sanan bir kalibrasyon örneği üretirdi.
        var evidenceIsSynthetic: Bool
        /// Bu kelimeden **sonra** belgeye yazdığımız ayırıcı.
        ///
        /// Konum doğrulaması beklenen metni bundan üretiyor; sabit `" "`
        /// varsaymak satır sonuyla kapatılmış kelimeleri yanlışlıkla
        /// reddederdi (`finishToken` `"\n"` ile de çağrılıyor).
        var separator: String
    }

    public private(set) var touches: [TouchSample] = []
    public private(set) var literal: String = ""
    public private(set) var display: String = ""

    /// Kanıt koptu: bu token'ın belgedeki yüzeyi ile dokunma dizisi arasında
    /// konumsal eşleme kalmadı. Token kapanana kadar öneri ve otomatik düzeltme
    /// **yapılmaz** — kanıtı olmayan bir düzeltme kullanıcının yazdığını bozardı.
    public private(set) var isDetached = false

    /// Bir sonraki token'a verilecek kimlik.
    ///
    /// Monoton ve **asla yeniden kullanılmıyor**: geri açılıp yeniden commit
    /// edilen token **yeni** kimlik alıyor. Eskisini geri vermek, kaydı okuyan
    /// tarafta iki farklı yazım denemesini tek token sanmaya yol açardı.
    private var nextTokenID = 0

    /// Şu an açık olan token kapandığında alacağı kimlik.
    ///
    /// Commit raporu bunu okuyor: kimliği commit anında üretip rapora ayrıca
    /// koymak, aynı sayının iki yerde tutulması olurdu.
    public var pendingTokenID: TokenID { TokenID(raw: nextTokenID) }

    /// Belgede **seçili** bir kelimeyi düzenliyoruz.
    ///
    /// Yazma yolu farklı: seçim varken `insertText` seçimi *değiştirir*,
    /// dolayısıyla önce `display.count` kez silmek yanlış olur — seçimin
    /// öncesindeki metni yerdi.
    public private(set) var isEditingSelection = false

    /// Seçim kipindeki kanıt **gerçek** mi (kullanıcının kendi dokunmaları) yoksa
    /// yüzeyden **türetilmiş** mi (tuş merkezleri) — plan §0 ayrımı.
    ///
    /// Türetilmiş kanıt uzamsal bir gözlem değildir: kullanıcının parmağının
    /// nereye düştüğünü değil, harflerin hangi tuşta olduğunu söyler. Öneri
    /// üretmek için yeterli (komşu tuş ve eşdeğerlik sınıfı adayları çıkar),
    /// ama **otomatik uygulama** için değil — o karar gerçek kanıt ister.
    public private(set) var selectionHasRealEvidence = false

    /// Yazılmakta olan token'ın uzamsal kanıtı **türetilmiş** mi.
    ///
    /// `selectionHasRealEvidence` ile aynı ayrım, yazma yolunda: erişilebilirlik
    /// etkinleştirmesi (VoiceOver çift dokunuşu) bir parmak koordinatı taşımıyor.
    /// Elimizde olan tek şey **hangi tuşun seçildiği**; koordinat olarak o tuşun
    /// merkezi konuyor. Bu bir gözlem değil, kullanıcının söylediği şeyin
    /// koordinat cinsinden yazılışı.
    ///
    /// Leke **token başına**, dokunma başına değil: karışık bir token'da
    /// (kullanıcı VoiceOver'ı kelime ortasında açtı) hangi karakterin hangi
    /// kanıttan geldiğini saklamak, o bilgiyi yalnız kalibrasyonun kullanacağı
    /// bir alan eklemek olurdu. §5c asimetrisi tarafı belirliyor: gereksiz
    /// koruma bir örnek kaybettirir, gereksiz öğrenme sapmayı sistematik olarak
    /// sıfıra çeker.
    public private(set) var evidenceIsSynthetic = false

    private var history: [Committed] = []

    /// Commit edilmiş token'ların **belgedeki** karşılığı — silme atfının
    /// kaynağı. Gerekçe ve kurallar `DeletionLedger`'da.
    private var ledger = DeletionLedger()

    /// Defteri belgeye karşı doğrular — `DeletionLedger.verify`.
    private mutating func verifyLedger(_ editor: DocumentEditor) {
        ledger.verify(contextBefore: editor.contextBeforeInput, pending: display)
    }

    /// İmleç oynamış **olabilir** — konumsal atıf bırakılıyor.
    ///
    /// Defter "belgenin sonunda şunlar duruyor" diyor; imleç başka bir yere
    /// gittiyse bu cümle artık yanlış bir yer hakkında. Kimlik uydurmaktansa
    /// bilmediğimizi söylemek: sonraki silmeler `.unattributed` olur, yeni
    /// yazılan token'lar yeniden atfedilebilir hâle gelir.
    ///
    /// Geri dönüş yığını **korunuyor**: dokunma kanıtı imleçten bağımsız ve
    /// §8.4 onu saklamayı şart koşuyor (çift dokunuşun ilk dokunuşu geçmişi
    /// siliyordu).
    public mutating func invalidatePositionalAttribution() {
        ledger.removeAll()
    }

    /// Geri dönüş yığınının derinliği. Sınırsız olamaz: her giriş kendi dokunma
    /// dizisini tutuyor ve uzantı bellek bütçesi dar (§11.D).
    public static let maxHistoryDepth = 8

    public init() {}

    public var isComposing: Bool { !display.isEmpty }

    /// Geri dönülebilir kelime sayısı — teşhis için.
    public var historyDepth: Int { history.count }

    // MARK: - Yazma

    /// Harf ekler. Literal **anında** yazılır — yazma hissi decoder'ı beklemez.
    ///
    /// Ekleme, ayrışmış bir yüzeyde bile güvenlidir: eşleme yalnız **sondan**
    /// büyür, mevcut karakterlerin kanıtı yerinde kalır. Bozan işlem silmedir.
    /// - Parameter synthetic: dokunma bir gözlem değil, seçilen tuşun
    ///   merkezinden **türetilmiş** mi (erişilebilirlik etkinleştirmesi).
    public mutating func insertLetter(_ ch: Character,
                                      touch: TouchSample,
                                      synthetic: Bool = false,
                                      into editor: DocumentEditor) -> Outcome {
        insert(evidence: ch, display: String(ch), touch: touch,
               synthetic: synthetic, into: editor)
    }

    /// Büyük harf girişi: kanıt **küçük** harfe ait, belgeye **büyüğü** yazılır.
    ///
    /// Kullanıcı `A` yazarken `a` tuşuna basıyor; uzamsal kanıt o tuşundur.
    /// `literal` küçük kalır (decoder onun üzerinden çalışır), `display` büyük
    /// olur. Bu, otomatik düzeltmeden sonraki ayrışmanın aynısı ve aynı
    /// değişmezi korur: `touches.count == literal.count`.
    public mutating func insertShiftedLetter(_ lower: Character,
                                             display shown: String,
                                             touch: TouchSample,
                                             synthetic: Bool = false,
                                             into editor: DocumentEditor) -> Outcome {
        insert(evidence: lower, display: shown, touch: touch,
               synthetic: synthetic, into: editor)
    }

    /// İki harf girişinin ortak yolu: `evidence` kanıta, `shown` belgeye.
    private mutating func insert(evidence ch: Character, display shown: String,
                                 touch: TouchSample, synthetic: Bool,
                                 into editor: DocumentEditor) -> Outcome {
        // Seçim kipinde host `insertText`'i seçimin YERİNE koyar; belgede geriye
        // yalnız bu harf kalır. Oturum eski `display` üzerine eklemeye devam
        // etseydi belge `x` iken oturum `kalemx` sanırdı.
        if isEditingSelection { clearComposing() }
        editor.insertText(shown)
        display += shown
        guard !isDetached else { return .rebuilt }   // kanıtsız token: beam boş kalır
        literal.append(ch)
        touches.append(touch)
        // Leke **kanıt fiilen eklendikten sonra** konuyor: kopuk token yukarıda
        // çıkıyor ve orada saklanan bir dokunma yok.
        if synthetic { evidenceIsSynthetic = true }
        return .appended
    }

    /// Belgede duran token'ı `surface` ile değiştirir (otomatik düzeltme ya da
    /// öneri çubuğundan seçim). `touches`/`literal` **korunur** — kanıt hâlâ
    /// kullanıcının bastığı yerdir, gösterilen yüzey değişse bile.
    ///
    /// Kopuk token'da **hiçbir şey yapmaz** ve `false` döner. "Kopuk token'a
    /// dokunulmaz" kuralı çağıranın nezaketine bırakılamaz: gecikmiş bir öneri
    /// geri çağrısı ya da yeni bir çağrı yolu kuralı sessizce çiğneyebilir.
    @discardableResult
    public mutating func replaceDisplay(with surface: String,
                                        into editor: DocumentEditor) -> Bool {
        guard !isDetached else { return false }
        guard surface != display else { return false }
        if isEditingSelection {
            // Seçim varken tek `insertText` seçimi değiştirir. Silmeye
            // kalkışmak seçimin ÖNCESİNDEKİ metni yerdi.
            editor.insertText(surface)
            isEditingSelection = false      // seçim tüketildi, imleç metnin sonunda
        } else {
            for _ in 0..<display.count { editor.deleteBackward() }
            editor.insertText(surface)
        }
        display = surface
        return true
    }

    /// Token'ı kapatır: geçmişe yazar, ayırıcıyı ekler, composing durumunu boşaltır.
    public mutating func finishToken(separator: String,
                                     into editor: DocumentEditor) -> Outcome {
        // Kanıtı kopmuş token geçmişe **yazılmaz**: geri dönüldüğünde yükleyecek
        // bir kanıt yok, ama boş `touches` üzerine yazılan yeni harfler yüzeyin
        // tamamını temsil ediyormuş gibi görünüp yanlış düzeltme üretirdi.
        if !display.isEmpty {
            // Kimlik **kanıtı kopmuş** token'a da veriliyor: o da belgede duran
            // gerçek bir token. Geçmişe girmiyor (geri açılamaz) ama kaydın
            // ondan söz edebilmesi gerek.
            if !isDetached {
                history.append(Committed(tokenID: pendingTokenID,
                                         touches: touches, literal: literal,
                                         display: display,
                                         evidenceIsSynthetic: evidenceIsSynthetic,
                                         separator: separator))
                if history.count > Self.maxHistoryDepth { history.removeFirst() }
            }
            // Defter **kanıt durumundan bağımsız**: kanıtı kopmuş token da
            // belgede yer kaplıyor ve silindiğinde adıyla anılabilmeli.
            // `history` sekizle sınırlı, defter değil — atıf o sınırla
            // kısıtlanamaz.
            ledger.append(token: pendingTokenID, display)
            nextTokenID += 1
        }
        if !separator.isEmpty {
            editor.insertText(separator)
            ledger.append(separator: separator)
        }
        clearComposing()
        return .cleared
    }

    /// Belgede duran yarım bir token'ı **kanıtsız** devralır.
    ///
    /// ## Neden gerekiyor
    ///
    /// Klavyenin iki koordinatörü var: kaydedicininki ve yedek. Kaydedici
    /// kelime ortasında bırakılırsa (yazma hatası, VoiceOver — §8.9) yedek
    /// koordinatör **boş** başlıyor, ama belgede yarım bir token duruyor.
    /// O andan sonra yedek yol yüzeyin yalnız yeni kısmını kendi token'ı
    /// sanıyordu ve iki somut zarar üretiyordu:
    ///
    /// 1. `kal` yazılmışken gelen `em` tek başına yargılanıyor ve **parçaya**
    ///    otomatik düzeltme uygulanabiliyordu.
    /// 2. Öneri seçimi `display.count` kadar siliyor: `kalem` seçmek belgeyi
    ///    `kalkalem` yapardı.
    ///
    /// ## Neden **kopuk**
    ///
    /// Yüzey biliniyor, kanıt bilinmiyor — `isDetached`'in tanımı tam olarak bu.
    /// Devralmayı normal bir token gibi kurmak, elimizde olmayan dokunmalara
    /// dayanan bir düzeltmeye kapı açardı. Kopuk kurmak mevcut kapıların
    /// hepsini kendiliğinden kapatıyor: `correctionDecision`, `replaceDisplay`
    /// ve `pickSuggestion` zaten kopuk token'a dokunmuyor, `finishToken` de onu
    /// geçmişe yazmıyor (geri açılacak kanıt yok).
    ///
    /// Yüzeyin bize ait olmayan bir kısmı da devralınmış olabilir (host'un
    /// metni). §5c asimetrisi bunu kabul edilebilir kılıyor: fazladan
    /// devralmanın bedeli düzeltilebilir bir kelimeyi düzeltmemek, tersinin
    /// bedeli kullanıcının metnini bozmak.
    ///
    /// Geçmiş ve defter **atılıyor**: bu noktadan öncesini yazan biz değiliz,
    /// dolayısıyla geri açma ve silme atfı için elimizde bir kayıt yok.
    @discardableResult
    public mutating func adoptDetachedSurface(_ surface: String) -> Outcome {
        guard !surface.isEmpty else { return .unchanged }
        clearComposing()
        history.removeAll()
        ledger.removeAll()
        display = surface
        isDetached = true
        return .cleared
    }

    /// Token'a **ait olmayan** metin yazar ve deftere işler.
    ///
    /// `insertSymbol` sembolü doğrudan editöre yazıyordu; o metin deftere
    /// girmeyince defter belgeyle ayrışıyor ve `verifyLedger` her sembolde
    /// defteri atıyordu — atıf da sonsuza dek `.unattributed`'a düşüyordu.
    public mutating func insertSeparator(_ text: String,
                                         into editor: DocumentEditor) {
        guard !text.isEmpty else { return }
        editor.insertText(text)
        ledger.append(separator: text)
    }

    // MARK: - Silme

    /// Tek dokunuşla geri silme.
    ///
    /// Token'ın başındayken **bir önceki kelimeye geri döner**: yalnız boşluk
    /// silinir, kelime yerinde kalır ve o kelimenin dokunma kanıtı geri yüklenir.
    /// Böylece kullanıcı geri gelip harf eklediğinde öneriler kaldığı yerden
    /// devam eder — kelimeyi düzeltmek yeniden yazmayı gerektirmez.
    public mutating func backspaceTap(into editor: DocumentEditor) -> Deletion {
        backspace(restoringPreviousWord: true, into: editor)
    }

    /// Basılı tutma tekrarındaki silme.
    ///
    /// Geri yükleme **bilinçli olarak yok**: kullanıcı toplu siliyor, düzenlemiyor.
    /// Tekrar sırasında her kelime sınırında öneri çubuğunun canlanması hem
    /// gereksiz iş hem görsel gürültü olurdu.
    public mutating func backspaceRepeat(into editor: DocumentEditor) -> Deletion {
        backspace(restoringPreviousWord: false, into: editor)
    }

    /// Tek karakterlik silmenin ortak yolu — iki tuş yalnız geri açmada ayrışıyor.
    private mutating func backspace(restoringPreviousWord restores: Bool,
                                    into editor: DocumentEditor) -> Deletion {
        if isEditingSelection { return deleteSelection(into: editor) }
        if !display.isEmpty { return deleteOneComposingCharacter(into: editor) }
        verifyLedger(editor)
        // Bağlam gözlenemiyorsa neyin silindiğini **bilmiyoruz**.
        guard let context = editor.contextBeforeInput else {
            editor.deleteBackward()
            ledger.removeAll()
            history.removeAll()
            return Deletion(.unchanged, unobservable: ())
        }
        if restores, let restored = restorePreviousWord(into: editor) {
            // `deleted` **boş**: geri açma yıkıcı bir silme değil, token'ın
            // yeniden açılması. Silinen ayırıcı belgeye ait bir olgu ve
            // `DocumentMutation` olarak zaten kayıtta — burada da yazmak aynı
            // olguyu iki yerde tutmak ve ikisinin ayrışmasına açık kapı olurdu.
            return Deletion(.rebuilt, .init(pending: .restoreToken,
                                            deleted: [],
                                            evidenceStateAfter: .attached,
                                            restoredToken: restored))
        }
        // Silinecek bir şey **var mı**: boş belgede `deleteBackward` no-op ve
        // olmamış bir silmeyi kaydetmek sahte olgudur.
        editor.deleteBackward()
        let deleted = context.isEmpty ? [] : ledger.attributeDeletion(of: 1)
        // Geri dönüş yığını atılıyor: tepesindeki kelime artık belgede
        // olduğundan farklı. Defter ise silmeyi **izledi**, atılmıyor.
        history.removeAll()
        return Deletion(.unchanged, .init(pending: .none, deleted: deleted,
                                          evidenceStateAfter: .cleared))
    }

    /// Kelime kelime silme — uzun basma ikinci kademesi.
    ///
    /// Sondaki boşlukları, sonra bir kelimeyi siler. Satır sonunu **geçmez**:
    /// `\n` silme sınırıdır, yoksa tek uzun basma birkaç satırı yutar.
    public mutating func deleteWordBackward(into editor: DocumentEditor) -> Deletion {
        if isEditingSelection { return deleteSelection(into: editor) }
        if !display.isEmpty {
            for _ in 0..<display.count { editor.deleteBackward() }
            clearComposing()
            // Silinen karakterler **açık** token'a aitti; commit edilmiş bir
            // token'a dokunulmadı. `deleted` yalnız commit edilmişleri anlatıyor,
            // bekleyen kanıtın akıbeti `pending`'de — aynı olguyu iki alanda
            // tutmak, ikisinin ayrışmasına davetiye olurdu.
            return Deletion(.cleared, .init(pending: .dropAll, deleted: [],
                                            evidenceStateAfter: .cleared))
        }

        verifyLedger(editor)
        guard let before = editor.contextBeforeInput else {
            // Bağlam gözlenemiyor: `deleteWordBackward` zaten hiçbir şey
            // yapamıyor ama "yapamadı" ile "bilmiyoruz" ayrı şeyler.
            return Deletion(.unchanged, unobservable: ())
        }
        guard !before.isEmpty else {
            return Deletion(.unchanged, .init(pending: .none, deleted: [],
                                              evidenceStateAfter: .cleared))
        }

        var chars = Array(before)

        // Satır sonu bir sınırdır: bu çağrı ya sınıra kadar siler ya **yalnız**
        // sınırı siler. İkisini birden yapmak, 0.22 sn'lik tekrar temposunda tek
        // basılı tutuşla önceki satırın sonunu da yutmak demekti — ve eski
        // koddaki `deleted == 0 → 1` düşüşü tam olarak bunu yapıyordu.
        //
        // `isNewline`, `== "\n"` karşılaştırmasının yerini alıyor: Swift'te
        // `"\r\n"` **tek** bir `Character`, dolayısıyla eşitlik kontrolü CRLF'de
        // sessizce ıskalıyordu. `isNewline` CRLF'yi de, U+2028/U+2029 gibi
        // ayırıcıları da tek silme birimi olarak kapsıyor.
        if chars.last?.isNewline == true {
            editor.deleteBackward()
            let deleted = ledger.attributeDeletion(of: 1)
            history.removeAll()
            return Deletion(.unchanged, .init(pending: .none, deleted: deleted,
                                              evidenceStateAfter: .cleared))
        }

        var deleted = 0
        while let last = chars.last, last == " " || last == "\t" {
            chars.removeLast(); deleted += 1
        }
        while let last = chars.last, !last.isWhitespace {
            chars.removeLast(); deleted += 1
        }
        // Sıra dışı bir boşluk karakteri (satır ayırıcı, bölünemez boşluk) iki
        // döngüyü de durdurabilir; tuş ölü hissettirmesin diye bir karakter.
        if deleted == 0 { deleted = 1 }

        for _ in 0..<deleted { editor.deleteBackward() }

        // Atıf **defterden** geliyor: silinen karakter sayısı sondan geriye
        // yürütülüp hangi token'ın hangi kısmının gittiği sayılıyor.
        //
        // Eski hâli geçmişin tepesindeki kelimeyle **yüzey eşitliği**
        // arıyordu; belgede aynı metnin başka bir örneği varsa eski kimliği
        // yeni konuma bağlıyordu. Üstelik tek çağrıda birden çok token silen
        // `wi-fi ` gibi durumlarda yalnız bir tanesini atfedebiliyordu.
        let spans = ledger.attributeDeletion(of: deleted)
        history.removeAll()
        return Deletion(.unchanged, .init(pending: .none, deleted: spans,
                                          evidenceStateAfter: .cleared))
    }

    /// Seçim kipinde silme: host **seçimin tamamını** siler, tek karakter değil.
    private mutating func deleteSelection(into editor: DocumentEditor) -> Deletion {
        editor.deleteBackward()
        clearComposing()
        history.removeAll()
        // Host **seçimin tamamını** siliyor ve seçimin kaç token kapsadığını
        // biz bilmiyoruz — kapsamı tahmin etmek yerine atfedilemez diyoruz.
        return Deletion(.cleared, .init(pending: .dropAll,
                                        deleted: [.unattributed],
                                        evidenceStateAfter: .cleared))
    }

    private mutating func deleteOneComposingCharacter(into editor: DocumentEditor) -> Deletion {
        let wasAligned = !isDetached && display.count == literal.count
        // Zaten kopuk bir yüzeyde bekleyen kanıt **yok**; ikinci silme hiçbir
        // şey düşürmüyor. `.dropAll` yazmak, olmamış bir kaybı olmuş gibi
        // kaydetmek olurdu ve reducer'da var olmayan dokunmaları arardı.
        let hadPending = !touches.isEmpty
        editor.deleteBackward()
        display.removeLast()

        if wasAligned {
            literal.removeLast()
            touches.removeLast()
        } else {
            detachEvidence()
        }
        if display.isEmpty { isDetached = false }   // token bitti, temiz sayfa
        // Kanıt durumu **sonrası** bildiriliyor, olay değil: canlı oturum
        // `isDetached`'i üç ayrı yerde temizliyor ve yalnız "koptu" demek,
        // reducer'ın kopukluktan **çıkışı** hiç görmemesine yol açardı.
        let after: DestructiveEffect.EvidenceState =
            display.isEmpty ? .cleared : (isDetached ? .detached : .attached)
        let pending: DestructiveEffect.PendingMutation =
            wasAligned ? .dropLast : (hadPending ? .dropAll : .none)
        return Deletion(.rebuilt, .init(pending: pending, deleted: [],
                                        evidenceStateAfter: after))
    }

    /// Kanıtı düşürür. Yüzey belgede duruyor; hangi dokunmanın hangi karakteri
    /// ürettiği artık bilinmediği için kanıt saklanmaz.
    private mutating func detachEvidence() {
        isDetached = true
        literal = ""
        touches.removeAll(keepingCapacity: true)
        // Kanıt kalmadıysa lekesi de kalmıyor. Kopuk token'a yeni dokunma
        // eklenmiyor, dolayısıyla bu alan bir daha okunmadan token bitecek —
        // ama "kanıt yok" ile "kanıt sentetik" iki ayrı olgu ve ikincisini
        // hiçbir kanıt yokken taşımak yanlış olurdu.
        evidenceIsSynthetic = false
    }

    /// - Returns: geri açılan token'ın kimliği; geri açma olmadıysa `nil`.
    ///
    /// ## Neden defter **ve** geçmiş
    ///
    /// Dokunma kanıtı `history`'de, belgedeki konum defterde. Yalnız yüzey
    /// eşitliğine bakmak, belgede aynı metnin başka bir örneği varsa eski
    /// kimliği yeni konuma bağlıyordu. Defter `verifyLedger` ile belgeye karşı
    /// doğrulandığı için, iki kaydın **aynı kimliği** göstermesi konumun da
    /// doğrulandığı anlamına geliyor.
    private mutating func restorePreviousWord(into editor: DocumentEditor) -> TokenID? {
        guard let last = history.last, !last.display.isEmpty,
              let (id, text, sep) = ledger.restorableTail, sep == " ",
              id == last.tokenID, text == last.display,
              let before = editor.contextBeforeInput,
              before.hasSuffix(text + sep),
              // **Tam token eşitliği** — sonek kontrolü yetmez. Defter kimliği
              // "aynı yüzey belgenin başka bir yerinde" deliğini kapatıyor ama
              // "yüzey daha uzun bir kelimenin soneki" deliğini kapatmıyor:
              // geçmişte `iki` varken host `biriki ` yazdıysa sonek tutar ve
              // `biriki`nin son üç harfine başka bir kelimenin dokunmaları
              // bağlanırdı. İki kontrol iki ayrı hatayı kapatıyor.
              String(before.dropLast(sep.count)).lastToken() == text
        else { return nil }

        editor.deleteBackward()          // yalnız boşluk; kelime yerinde kalıyor
        history.removeLast()
        // Token artık **açık**: defterden çıkıyor, metni `display`'e geçiyor.
        ledger.popRestorable()
        touches = last.touches
        literal = last.literal
        display = last.display
        evidenceIsSynthetic = last.evidenceIsSynthetic
        isDetached = false
        return last.tokenID
    }

    // MARK: - Seçilen kelimeyi düzenleme

    /// Seçim denemesinin **neden** başarısız olduğu — teşhis için.
    ///
    /// Bu özellik sessizce çalışmadığında sebebini bilmek gerekiyor: kapıların
    /// hepsi meşru ama hangisinin kapandığı cihazda görülmeden anlaşılmıyor.
    public enum SelectionRejection: String, Sendable {
        case none
        case notAWord           = "tek kelime değil"
        case notInHistory       = "geçmişte yok"
        case ambiguousInHistory = "geçmişte birden çok"
        case noContext          = "bağlam okunamadı"
        case leftMismatch       = "sol bağlam uyuşmuyor"
        case rightMismatch      = "sağ bağlam uyuşmuyor"
        case ambiguousInDocument = "belgede birden çok"
        case weakContext        = "bağlam doğrulaması zayıf"
    }

    /// Son `beginEditingSelection` denemesinin sonucu.
    public private(set) var lastSelectionRejection: SelectionRejection = .none

    /// Kullanıcı belgede bir kelime seçti. O kelimeyi **biz yazdıysak** ve
    /// konumu doğrulanabiliyorsa dokunma kanıtı geri yüklenir.
    ///
    /// ## Neden konum doğrulaması şart
    ///
    /// iOS seçimin **metnini** veriyor, konumunu değil. Yalnız metne bakmak
    /// yetmez: kullanıcı `kalem` kelimesini iki kez yazdıysa ya da belgede
    /// bizim yazmadığımız üçüncü bir `kalem` varsa, hangi geçtiği yerin
    /// seçildiğini bilemeyiz ve **yanlış dokunma kanıtını** bağlarız.
    ///
    /// Doğrulama şu: geçmiş bizim yazdıklarımızın **sıralı** kaydı ve
    /// aralarına hangi ayırıcıyı koyduğumuzu biliyoruz. Dolayısıyla `i`.
    /// girdiden sonra belgede ne durması gerektiğini üretebiliriz; bunu
    /// `contextAfterInput` ile karşılaştırıyoruz.
    ///
    /// Doğrulanamayan seçimde **hiçbir şey uydurulmaz**: durum atılır.
    ///
    /// - Returns: kanıt bulunup doğrulandıysa `.rebuilt`, aksi hâlde `.cleared`.
    public mutating func beginEditingSelection(_ selected: String,
                                               into editor: DocumentEditor) -> Outcome {
        // Aynı seçim için gelen tekrarlı geri çağrılar idempotent olmalı;
        // yoksa ikinci çağrı geçmişi bulamayıp her şeyi temizler.
        if isEditingSelection && selected == display { return .unchanged }

        // Kenarlarda boşluk bırakan seçim reddedilir. Kabul edip kırpmak,
        // değiştirme sırasında o boşlukları yok ederdi.
        guard Self.isSingleWord(selected) else { return reject(.notAWord) }

        // **Tekil** eşleşme şartı: birden çok kez geçiyorsa hangisinin
        // seçildiğini bilemeyiz.
        let matches = history.indices.filter { history[$0].display == selected }
        guard !matches.isEmpty else { return reject(.notInHistory) }
        guard matches.count == 1, let idx = matches.first else {
            return reject(.ambiguousInHistory)
        }

        // Konum doğrulaması **iki taraflı**. Yalnız sağ bağlama bakmak yetmez:
        // host, seçtiğimiz kelimenin solunu değiştirmiş olabilir ve belgedeki
        // o yüzey artık bizim yazdığımız token olmayabilir. O durumda başka bir
        // kelimenin dokunma kanıtını bağlardık.
        // `nil` ile `""` **aynı şey değil**: birincisi "host bağlam vermiyor",
        // ikincisi "gerçekten sonrası yok". `?? ""` ile birleştirmek
        // doğrulanamayan bir durumu doğrulanmış saymaktı.
        guard let before = editor.contextBeforeInput,
              let after = editor.contextAfterInput else { return reject(.noContext) }

        var expectedBefore = ""
        for e in history[..<idx] { expectedBefore += e.display + e.separator }
        var expectedAfter = history[idx].separator
        for e in history[(idx + 1)...] { expectedAfter += e.display + e.separator }

        guard before.hasSuffix(expectedBefore) else { return reject(.leftMismatch) }
        guard after.hasPrefix(expectedAfter) else { return reject(.rightMismatch) }

        // **Boş doğrulama kabul edilmez.** Geçmişin ilk girdisinde
        // `expectedBefore` boştur; geçmişte tek girdi varsa `expectedAfter` de
        // yalnız ayırıcıdan ibarettir. O durumda iki taraflı doğrulama fiilen
        // hiçbir şey kanıtlamaz ve host'un yapıştırdığı aynı görünümlü bir
        // kelime "bizim yazdığımız" sanılabilir — eski dokunmalar **gerçek
        // kanıt** olarak bağlanıp otomatik uygulamaya yetki verirdi.
        //
        // Reddedilen seçim türetilmiş kanıt yoluna düşer: öneri yine görünür,
        // ama otomatik uygulama olmaz. Doğru asimetri bu.
        guard expectedBefore.count + expectedAfter.count >= 2 else {
            return reject(.weakContext)
        }

        // Görünen belge penceresinde de tekil olmalı. Host'un eklediği ikinci
        // bir `iki` varsa hangisinin seçildiği yine belirsizdir.
        let window = before + selected + after
        guard occurrences(of: selected, in: window) == 1 else {
            return reject(.ambiguousInDocument)
        }

        let entry = history[idx]
        // Geçmiş artık belge sırasını temsil edemez: kullanıcı geriye gitti ve
        // bu kelimeyi değiştirecek. Kısmi tutmak, sonraki backspace geri
        // dönüşünün yanlış kelimeyi hedeflemesine yol açardı.
        history.removeAll()

        touches = entry.touches
        literal = entry.literal
        display = entry.display
        isDetached = false
        isEditingSelection = true
        // "Bu kelimeyi biz yazdık" **gerçek gözlem** demek değil: token
        // erişilebilirlikle yazıldıysa saklanan dokunmalar zaten tuş
        // merkezleridir. Burada `true` yazmak, türetilmiş kanıta otomatik
        // uygulama yetkisi verirdi — `beginEditingSelectionSynthetic`'in tam da
        // engellediği şey, yalnız başka bir kapıdan.
        evidenceIsSynthetic = entry.evidenceIsSynthetic
        selectionHasRealEvidence = !entry.evidenceIsSynthetic
        lastSelectionRejection = .none
        return .rebuilt
    }

    /// Seçilen kelimeyi **türetilmiş** kanıtla düzenlemeye açar.
    ///
    /// Gerçek dokunma kanıtı yoksa (kelimeyi biz yazmadık, ya da uygulama
    /// yeniden başladığı için geçmiş boş) yine de yararlı bir şey yapılabilir:
    /// her harfi kendi tuşunun merkezine koyup decoder'ı çalıştırmak. Çıkan
    /// adaylar komşu-tuş düzeltmeleri ve eşdeğerlik sınıflarıdır — `guzel`
    /// seçilince `güzel`, `kalen` seçilince `kalem`.
    ///
    /// Bu **uzamsal bir gözlem değildir** ve öyleymiş gibi kullanılmaz:
    /// `selectionHasRealEvidence == false` olduğu sürece otomatik uygulama
    /// yapılmaz, kullanıcının adaya dokunması gerekir.
    ///
    /// - Parameter touches: yüzeyden türetilmiş dokunmalar; çağıran layout'u
    ///   bildiği için onları o üretir.
    public mutating func beginEditingSelectionSynthetic(
        _ selected: String,
        touches synthetic: [TouchSample]
    ) -> Outcome {
        // Host'taki **gerçek** seçim yüzeyi verilmelidir, kırpılmışı değil.
        // Kırpılmışla açmak, aday uygulanırken `insertText`'in host'un tüm
        // seçimini (çevre boşlukları dahil) değiştirmesine ve o boşlukların
        // silinmesine yol açıyordu.
        guard Self.isSingleWord(selected),
              synthetic.count == selected.count else {
            return invalidateComposing()
        }
        clearComposing()
        touches = synthetic
        literal = selected
        display = selected
        isEditingSelection = true
        selectionHasRealEvidence = false
        // İki alan aynı olguyu iki yerden anlatıyor gibi görünüyor ama
        // kapsamları farklı: `selectionHasRealEvidence` yalnız seçim kipinde
        // tanımlı, `evidenceIsSynthetic` token'ın kendisine ait ve yazma
        // yolunda da okunuyor. Seçim kipinde ikisi aynı yönü göstermeli.
        evidenceIsSynthetic = true
        lastSelectionRejection = .none
        return .rebuilt
    }

    /// Seçim düzenlemeye açılabilecek **tek kelime** mi: boş değil, içinde
    /// (kenarları dahil) boşluk yok.
    ///
    /// İki seçim yolu (gerçek kanıt ve türetilmiş kanıt) aynı kapıyı ayrı ayrı
    /// yazıyordu; biri gevşeseydi türetilmiş yol kırpılmamış bir seçimi açıp
    /// host'un çevre boşluklarını silebilirdi.
    static func isSingleWord(_ s: String) -> Bool {
        !s.isEmpty && !s.contains(where: \.isWhitespace)
    }

    private mutating func reject(_ why: SelectionRejection) -> Outcome {
        let out = invalidate()
        lastSelectionRejection = why
        return out
    }

    /// Bir alt dizenin kaç kez geçtiği (örtüşmesiz).
    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var i = haystack.startIndex
        while let r = haystack.range(of: needle, range: i..<haystack.endIndex) {
            n += 1
            i = r.upperBound
        }
        return n
    }

    /// Seçim düzenlemesini kapatır.
    ///
    /// `finishToken`'dan **ayrı** olmasının sebebi: ayırıcı zaten belgede.
    /// `finishToken` çağırmak seçimin ardındaki mevcut boşluğun yanına ikinci
    /// bir boşluk koyardı; düzeltme uygulanmadıysa daha kötüsü, `insertText(" ")`
    /// seçili kelimenin **tamamını** boşlukla değiştirirdi.
    ///
    /// - Parameter surface: uygulanacak yüzey; `nil` ise seçim olduğu gibi kalır.
    public mutating func commitSelectionEdit(_ surface: String?,
                                             into editor: DocumentEditor) -> Outcome {
        guard isEditingSelection else { return .unchanged }
        if let surface, surface != display {
            replaceDisplay(with: surface, into: editor)
        }
        clearComposing()
        return .cleared
    }

    /// Seçim düzenleme kipinden çıkar (kullanıcı başka yere dokundu vb.).
    public mutating func endEditingSelection() -> Outcome {
        guard isEditingSelection else { return .unchanged }
        return invalidate()
    }

    // MARK: - Host uzlaştırması (§8)

    /// Belgedeki metin bizim tamponumuzla uyuşuyor mu.
    ///
    /// Tampon **spekülatif bir önbellektir**; host imleci taşımış, metni
    /// dönüştürmüş ya da alan değişmiş olabilir. Uyuşmuyorsa durum atılır —
    /// yanlış yere silme yapmaktansa öneriyi kaybetmek yeğdir.
    ///
    /// Composing boşken `true` dönmek **yetmez**: o durumda bile geri dönüş
    /// yığını host metnine dair bir iddia taşıyor. Doğrulanmazsa host metni
    /// değiştikten sonra sonek tesadüfen tutabilir ve eski bir kelimenin
    /// dokunmaları yepyeni bir konuma bağlanır.
    public func agreesWithHost(_ editor: DocumentEditor) -> Bool {
        // Seçim kipinde tampon imlecin ÖNÜNDE değil, seçimin İÇİNDE duruyor;
        // sonek karşılaştırması burada anlamsız. `beginEditingSelection`
        // boşluklu seçimi zaten reddettiği için ham karşılaştırma güvenli.
        if isEditingSelection { return editor.selectedText == display }
        guard let before = editor.contextBeforeInput else {
            return display.isEmpty && history.isEmpty
        }
        if !display.isEmpty { return before.hasSuffix(display) }
        guard let last = history.last else { return true }
        // Beklenen metin **kaydedilen ayırıcıyla**: sabit `" "` varsaymak,
        // başka bir ayırıcıyla kapatılmış kelimede (satır sonu, sembol
        // öncesi boş ayırıcı) uyumlu bir belgeyi uyumsuz sayıp geçmişi
        // atıyordu. `Committed.separator` tam bu soruya cevap olsun diye var.
        return before.hasSuffix(last.display + last.separator)
    }

    /// Composing durumunu **ve** geri dönüş yığınını atar.
    ///
    /// Yalnız gerçekten her şeyin geçersizleştiği durumlar için: alan değişimi,
    /// satır sonu, kullanıcının açık sıfırlaması.
    public mutating func invalidate() -> Outcome {
        clearComposing()
        history.removeAll()
        // Defter de atılıyor: bu noktadan öncesini artık bilmiyoruz ve
        // yürüyüş defteri aşınca dürüstçe `.unattributed` üretiyor.
        ledger.removeAll()
        return .cleared
    }

    /// **Yalnız** yazılmakta olan token'ı atar; geri dönüş yığınını korur.
    ///
    /// İmleç hareketi için doğru olan budur. Cihazda ölçüldü: kullanıcı bir
    /// kelimeye çift dokunduğunda **ilk** dokunuş imleci taşıyor,
    /// `agreesWithHost` düşüyor ve tam `invalidate()` geçmişi siliyordu —
    /// seçim daha oluşmadan kanıt yok oluyordu.
    ///
    /// Geçmişi korumak güvenli: bir imleç hareketi *bizim ne yazdığımızı*
    /// yanlış yapmaz. Kayıt bayatlamışsa `beginEditingSelection`'ın iki taraflı
    /// konum doğrulaması onu zaten reddeder — koruma orada, burada değil.
    public mutating func invalidateComposing() -> Outcome {
        clearComposing()
        // İmleç oynadığı için çağrılıyor; konumsal atıf artık geçersiz.
        invalidatePositionalAttribution()
        return .cleared
    }

    private mutating func clearComposing() {
        literal = ""
        display = ""
        isDetached = false
        isEditingSelection = false
        selectionHasRealEvidence = false
        evidenceIsSynthetic = false
        touches.removeAll(keepingCapacity: true)
    }
}

private extension String {
    /// Sondaki boşluk olmayan karakter dizisi — belgenin son token'ı.
    func lastToken() -> String {
        String(reversed().prefix { !$0.isWhitespace }.reversed())
    }
}
