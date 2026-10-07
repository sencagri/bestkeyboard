import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder
import KBLearning

/// Girdi motorunun cephe tipi — plan §Depo yapısı: *"KBRuntime/ InputEngine
/// facade + host senkronizasyonu"*.
///
/// ## Neden var
///
/// Bütün karar mantığı `UIInputViewController` içindeydi ve **hiç test
/// edilemiyordu**: commit kararı (`Δ > θ`), kalibrasyon öğrenmesinin hangi
/// yollarda çalıştığı, seçim kipinin diğerleriyle etkileşimi. Codex'in
/// istediği uçtan uca testi yazamamamın sebebi buydu.
///
/// Uzantı artık ince bir adaptör: dokunmayı iletiyor, sonucu çiziyor. Karar
/// burada ve `swift test` altında koşuyor.
///
/// ## Neyi kapsamaz
///
/// UIKit'e ait olan hiçbir şey: görünüm, zamanlayıcı, `UIInputViewController`
/// yaşam döngüsü, dosya sistemi. Kalibrasyonun **kalıcılığı** da dışarıda —
/// koordinatör öğrenir, saklamayı çağıran yapar.
///
/// ## Dosya düzeni
///
/// Tip birkaç dosyaya bölünmüş durumda; her biri tek bir sorumluluk:
///
/// | Dosya | Ne |
/// |---|---|
/// | `InputCoordinator.swift` | durum, motor yaşam döngüsü, harf ve silme girdisi, komut dağıtımı |
/// | `InputCoordinator+Boundary.swift` | token sınırları: boşluk, sembol, satır sonu, öneri seçimi |
/// | `InputCoordinator+Selection.swift` | host seçimi |
/// | `InputCoordinator+Context.swift` | dil ve bağlam durumu |
/// | `InputCoordinator+Learning.swift` | kalibrasyon öğrenmesi |
/// | `InputCoordinator+Personal.swift` | kişisel sözlük (§8.7) |
/// | `TokenCommitReport.swift` | sınır olayının raporu |
/// | `CorrectionPolicy.swift` | `Δ > θ` kararının saf hâli |
/// | `SuggestionPresenter.swift` | öneri çubuğunun içeriği |
public struct InputCoordinator {

    /// Kod çözme yeteneği. Protokol olmasının sebebi test değil: paket henüz
    /// yüklenmemişken de klavyenin yazabilmesi gerekiyor (§11.A iki aşamalı
    /// init), yani "decoder yok" meşru bir durum.
    public struct Engine {
        public var decoder: Decoder
        public var literalChannel: LiteralChannel
        /// Genişletme haritası (§4.D) — **opsiyonel**, yoksa ek öneri çıkmaz.
        public var expansions: ExpansionMap?

        public init(decoder: Decoder, literalChannel: LiteralChannel,
                    expansions: ExpansionMap? = nil) {
            self.decoder = decoder
            self.literalChannel = literalChannel
            self.expansions = expansions
        }
    }

    public internal(set) var session = ComposingSession()
    public var calibration = CalibrationLearner()

    /// Kullanıcının kendi kelimeleri (§8.7). Koordinatör **öğrenir**; diske
    /// yazmayı çağıran yapar — kalibrasyonla aynı iş bölümü.
    public internal(set) var personal = PersonalLexicon()

    /// Motora **fiilen** kurulmuş kişisel kaynağın kimliği; yoksa `nil`.
    ///
    /// Kayda giriyor: kaynak `LexiconSet`'in bir üyesi ve onu yazmamak, kaydın
    /// kendi motorunu eksik anlatması olurdu (§12.7).
    ///
    /// `personal`'dan **çıkarılamaz**: kabul edilmiş yüzeylerin bir kısmı §7
    /// süzgecine takılıp trie'ye girmemiş olabilir.
    public internal(set) var personalSourceRef: PersonalSourceRef?

    public struct PersonalSourceRef: Equatable, Sendable {
        /// Trie'ye **fiilen** giren yüzey sayısı.
        public let wordCount: Int
        public let byteCount: Int
        public let sha256: String
        public let sourceOrder: Int
        public let language: UInt8
    }

    /// Leksikon her yeniden kurulduğunda artan sayaç.
    ///
    /// Kaydedici bunu okuyor: kişisel bir kelimenin kabulü **kayıt dışı bir
    /// motor değişikliğidir** ve `engineConfigured` snapshot'ı o andan sonra
    /// motoru anlatmıyor. `applyCalibration` ile aynı durum, aynı çözüm —
    /// deneme işaretlenir ve çağıran yenisine geçer.
    public internal(set) var personalVersion = 0

    /// Aktif alan parola alanı mı.
    ///
    /// Üretimde parola alanında tampon zaten düşürülüyor (uzantı `perform`
    /// içinde). Ama yedek yol (`recorder == nil`) doğrudan bu koordinatörü
    /// kullanıyor ve başka bir katmanın davranışına dayanan koruma, koruma
    /// değildir: kişisel sözlük burada da kanıt toplamıyor.
    public var fieldIsSecure = false

    /// `nil` iken klavye yazar ama öneri üretmez ve düzeltme yapmaz.
    public internal(set) var engine: Engine?
    var incremental: IncrementalDecoder?

    public let layout: KeyLayout

    /// Otomatik düzeltme kararının **eşik politikası** (§8, §8.1.1).
    ///
    /// Kararın saf hâli `CorrectionPolicy`'de; koordinatör yalnız hangi
    /// token'ın yargılanacağına karar veriyor. `kbdiag --theta` aynı
    /// politikayı çağırıyor — eşiği ölçen araç ile uygulayan klavye aynı
    /// kuralı koşmazsa ölçüm başka bir şeyi ölçer.
    public var correction = CorrectionPolicy()

    /// Öneri çubuğunda gösterim penceresi — **UI politikası**, skor
    /// sözleşmesinin parçası değil.
    public var suggestionWindow = 3.0

    /// Kaç örnekte bir kalıcılaştırma istenir.
    public var saveEvery = 60
    public internal(set) var samplesSinceSave = 0
    /// Çağıranın kalibrasyonu diske yazması gerektiğini bildirir.
    public internal(set) var wantsCalibrationSave = false

    /// Çağıranın kişisel sözlüğü diske yazması gerektiğini bildirir.
    ///
    /// Kalibrasyondan farklı olarak **her değişimde** açılıyor, sayaçla değil:
    /// bir kelimenin kabul edilmesi ender bir olay ve kaybedilirse kullanıcı
    /// aynı kelimeyi baştan öğretmek zorunda kalır.
    public internal(set) var wantsPersonalSave = false

    public init(layout: KeyLayout) {
        self.layout = layout
    }

    // MARK: - Motor yaşam döngüsü

    public mutating func setEngine(_ e: Engine?) {
        engine = e
        rebuildIncremental()
    }

    /// Belgede duran yarım bir token'ı **kanıtsız** devralır.
    ///
    /// Klavyenin yedek koordinatörü, kaydedici kelime ortasında bırakıldığında
    /// bunu çağırıyor: yüzey belgede duruyor ve boş başlamak yüzeyin yalnız
    /// yeni kısmını token sanmak olurdu. Gerekçenin tamamı
    /// `ComposingSession.adoptDetachedSurface`'ta.
    public mutating func adoptDetachedSurface(_ surface: String) {
        apply(session.adoptDetachedSurface(surface))
        // Bağlam da düşüyor: devraldığımız yüzeyin önünde hangi kelimenin
        // durduğunu bilmiyoruz ve eski koordinatörün bağlamı bize taşınmadı.
        forgetContext()
    }

    /// Yazılmakta olan token'ı atar; geri dönüş yığınını korur.
    ///
    /// **Geometri değiştiğinde zorunlu.** Tampondaki dokunmalar eski normalize
    /// uzayda kaydedildi; yeni tuş merkezlerine göre skorlamak sistematik bir
    /// sapma uygulamak olurdu. Belgeye yazılmış harfler yerinde kalıyor —
    /// düşen tek şey o token'ın düzeltilebilirliği.
    public mutating func invalidateComposing() {
        apply(session.invalidateComposing())
        // Bağlam da düşüyor: kanıt koptuysa imlecin nerede olduğunu ve önünde
        // hangi kelimenin durduğunu bilmiyoruz. Eski bağlamı taşımak, artık
        // orada olmayan bir kelimeyle puanlamak olurdu.
        forgetContext()
    }

    // MARK: - Komut dağıtımı

    /// Bir `ReplayCommand`'ı koordinatöre uygulamanın **tek** yolu.
    ///
    /// ## Neden tek yer
    ///
    /// Aynı `switch` üç kopyadaydı: kaydedicinin `apply`'ı, golden replay ve
    /// uzantının yedek yolu. Kopyalar ayrışmıştı: golden genişletme seçimini
    /// `.suggestion` diye oynatıyordu (komutun `origin`'ini atlıyordu), kaydedici
    /// ise doğrulanmamış bir `baseKey`'i `Character(_:)`'a verip çok grapheme'li
    /// bir kayıtta klavyeyi **düşürebiliyordu**. Komut şemanın kapalı kümesi;
    /// onu motora çeviren kural da bir tane olmalı.
    ///
    /// ## Doğrulama mutasyondan **önce**
    ///
    /// Bozuk bir komut (tek grapheme olmayan `baseKey` ya da sembol, boş metin,
    /// dokunmasız harf) hata fırlatıyor ve koordinatöre de belgeye de dokunulmuyor.
    /// Çağıran nasıl tepki vereceğini seçiyor: kaydedici denemeyi reddediyor,
    /// golden action'ı doğrulanamaz sayıyor, yedek yol tuşu yutuyor.
    ///
    /// - Parameter touch: harf komutunun uzamsal kanıtı; diğer komutlarda
    ///   okunmuyor.
    /// - Parameter synthetic: dokunma **gözlem değil** (erişilebilirlik —
    ///   §8.9); yalnız harf komutunda anlamlı.
    /// - Parameter fieldProtectsLiteral: alan literal'i koruyor mu; yalnız
    ///   boşlukta anlamlı.
    @discardableResult
    public mutating func perform(_ command: ReplayCommand,
                                 touch: TouchSample?,
                                 synthetic: Bool = false,
                                 fieldProtectsLiteral: Bool = false,
                                 into editor: DocumentEditor)
        throws(CommandError) -> CommandResult {
        switch command {
        case let .letter(baseKey, display, shifted):
            // `baseCharacter` şemanın kendi doğrulayıcısı: çok grapheme'li ya da
            // boş `baseKey`'de `nil`. `Character(baseKey)` aynı durumda çöküyordu.
            guard let ch = command.baseCharacter else {
                throw .baseKeyNotSingleGrapheme(baseKey)
            }
            guard let touch else { throw .letterWithoutTouch }
            if shifted {
                insertUppercaseLetter(ch, uppercase: display, touch: touch,
                                      synthetic: synthetic, into: editor)
            } else {
                insertLetter(ch, touch: touch, synthetic: synthetic, into: editor)
            }
            return .input

        case let .symbol(s):
            // Emoji bu yoldan geçiyor: dizi tek kod noktası olmak zorunda değil
            // (`👨‍👩‍👧` tek grapheme, dört skaler) ama tek grapheme olmak zorunda.
            guard let ch = command.symbolCharacter else {
                throw .symbolNotSingleGrapheme(s)
            }
            return .boundary(insertSymbol(ch, into: editor))

        case let .text(t):
            // Boş metin bir olay değil: yazılacak bir şey yokken token'ı
            // kapatmak, kullanıcının yapmadığı bir sınırı kaydetmek olurdu.
            guard !t.isEmpty else { throw .emptyText }
            return .boundary(insertText(t, into: editor))

        case .space:
            return .boundary(space(into: editor,
                                   fieldProtectsLiteral: fieldProtectsLiteral))

        case .newline:
            return .boundary(newline(into: editor))

        case let .suggestionPick(_, surface, origin):
            // Genişletme mi aday mı — **komuttan** okunuyor. Koordinatörün
            // yeniden sınıflandırması, kullanıcının dokunduğu andaki listeyi
            // değil commit anındakini kullanmak olurdu.
            return .boundary(pickSuggestion(surface,
                                            isExpansion: origin.isExpansion,
                                            into: editor))

        case .backspaceTap:
            return .destructive(backspaceTap(into: editor))
        case .backspaceRepeat:
            return .destructive(backspaceRepeat(into: editor))
        case .deleteWord:
            return .destructive(deleteWord(into: editor))

        case .planeChange, .shift:
            // Düzlem ve shift motorun durumuna dokunmuyor; yüzey farkı zaten
            // harf komutunun `display` alanında.
            return .input
        }
    }

    /// `perform`'un sonucu — komutun **türüne göre** taşıdığı olgu.
    public enum CommandResult: Equatable, Sendable {
        /// Harf, shift, düzlem: kayda geçecek bir sınır ya da etki yok.
        case input
        /// Token sınırı: commit raporu (etkisi `report.effect`'te).
        case boundary(TokenCommitReport)
        /// Yıkıcı işlem: olgu bilinmeyebilir (§6.2).
        case destructive(Epistemic<DestructiveEffect>)
    }

    /// Komut şemanın izin verdiği biçimde değil — **hiçbir şey** uygulanmadı.
    public enum CommandError: Error, Equatable, Sendable,
                              CustomStringConvertible {
        case baseKeyNotSingleGrapheme(String)
        case symbolNotSingleGrapheme(String)
        case letterWithoutTouch
        case emptyText

        public var description: String {
            switch self {
            case .emptyText:
                return "metin komutu boş"
            case let .baseKeyNotSingleGrapheme(k):
                return "baseKey tek grapheme olmalı: '\(k)'"
            case let .symbolNotSingleGrapheme(s):
                return "sembol tek grapheme olmalı: '\(s)'"
            case .letterWithoutTouch:
                return "harf komutunun dokunması yok"
            }
        }
    }

    // MARK: - Girdi

    /// - Parameter synthetic: dokunma **gözlem değil**, seçilen tuşun
    ///   merkezinden türetilmiş (erişilebilirlik etkinleştirmesi — §8.9).
    ///   Token'ı lekeliyor: o token ne otomatik düzeltiliyor ne de kalibrasyon
    ///   örneği üretiyor.
    public mutating func insertLetter(_ ch: Character, touch: TouchSample,
                                      synthetic: Bool = false,
                                      into editor: DocumentEditor) {
        apply(session.insertLetter(ch, touch: touch, synthetic: synthetic,
                                   into: editor))
    }

    /// **Büyük harfli** harf girişi.
    ///
    /// Uzamsal kanıt küçük harf tuşuna aittir — kullanıcı `A` yazarken `a`
    /// tuşuna basar. Bu yüzden `session` küçük harfi kanıt olarak alır, belgeye
    /// büyüğü yazılır ve token **kanıtı kopmuş** sayılmaz: eşleme bozulmuyor,
    /// yalnız görünen yüzey farklı.
    ///
    /// Ama düzeltme yine de yapılmaz: büyük harfle başlayan token'lar §5c
    /// kurallarına ya da özel ad olma ihtimaline giriyor. `display` ile
    /// `literal` ayrıştığı için `warrantedCorrection` zaten devreye girmez.
    public mutating func insertUppercaseLetter(_ lower: Character,
                                               uppercase: String,
                                               touch: TouchSample,
                                               synthetic: Bool = false,
                                               into editor: DocumentEditor) {
        apply(session.insertShiftedLetter(lower, display: uppercase,
                                          touch: touch, synthetic: synthetic,
                                          into: editor))
    }

    /// Yıkıcı işlemler **olgu döndürüyor** — sözleşme §6.2.
    ///
    /// Geri açma ve kanıt kopması kararları `ComposingSession`'ın: belge
    /// bağlamına bakıyorlar (`contextBeforeInput`, `hasSuffix(" ")`, tam token
    /// eşitliği) ve saf bir katlayıcı bunları **türetemez**. Türetmeye çalışmak
    /// §6.2'nin yasakladığı çıkarım olurdu; karar burada verilir, olgu olarak
    /// kayda yazılır.
    @discardableResult
    public mutating func backspaceTap(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        apply(session.backspaceTap(into: editor))
    }

    @discardableResult
    public mutating func backspaceRepeat(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        apply(session.backspaceRepeat(into: editor))
    }

    @discardableResult
    public mutating func deleteWord(into editor: DocumentEditor)
        -> Epistemic<DestructiveEffect> {
        apply(session.deleteWordBackward(into: editor))
    }

    /// Kurulan motorun uzamsal modeli — **anlık görüntü için**.
    ///
    /// Kayıt, motorun fiilen taşıdığı kalibrasyonu yazmak zorunda; çağıranın
    /// verdiği görüntüye güvenmek kaydın kendi motorunu yanlış anlatmasına yol
    /// açıyordu.
    public var spatialModel: SpatialModel {
        engine?.decoder.spatial ?? SpatialModel(layout: layout)
    }

    // MARK: - İç

    /// Oturumun sonucunu decoder'a çevirir.
    ///
    /// Artımlı kod çözme yalnız `.appended`'de korunur (§11.C.1); dokunma
    /// dizisi başka türlü değiştiyse beam bayat kalacağı için yeniden kurulur.
    mutating func apply(_ outcome: ComposingSession.Outcome) {
        switch outcome {
        case .unchanged:
            break
        case .appended:
            if let last = session.touches.last { incremental?.append(last) }
        case .rebuilt, .cleared:
            rebuildIncremental()
        }
    }

    /// Yıkıcı bir işlemin sonucunu uygular ve olguyu çağırana verir.
    mutating func apply(_ deletion: ComposingSession.Deletion)
        -> Epistemic<DestructiveEffect> {
        apply(deletion.outcome)
        return deletion.effect
    }

    mutating func rebuildIncremental() {
        guard let e = engine else { incremental = nil; return }
        var inc = IncrementalDecoder(decoder: e.decoder)
        for t in session.touches { inc.append(t) }
        incremental = inc
    }
}
