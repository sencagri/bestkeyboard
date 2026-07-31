import Foundation

/// Kayıt için **olgular** — sözleşme §12, plan v8 §2.1.
///
/// ## Neden `KBRuntime`'da
///
/// Bu tipleri `KBSessions`'a koymak `KBSessions ↔ KBRuntime` döngüsü açardı:
/// kayıt motora bağımlıdır, motor kayda değil. Olguları üreten `InputCoordinator`
/// burada yaşıyor, dolayısıyla tipleri de burada.
///
/// ## Neden "olgu"
///
/// Geri açma ve kanıt kopması kararları `ComposingSession`'ın: belge bağlamına
/// bakıyorlar (`contextBeforeInput`, `hasSuffix(" ")`, tam token eşitliği) ve
/// saf bir katlayıcı bunları **türetemez**. Türetmeye çalışmak §6.2'nin
/// yasakladığı çıkarım olurdu.
///
/// Sözleşme: **karar burada verilir, olgu olarak kayda yazılır, reducer katlar.**

/// Commit edilmiş bir token'ın kararlı kimliği.
///
/// Deneme içinde monoton, benzersiz ve **asla yeniden kullanılmaz**. Geri açılıp
/// yeniden commit edilen token **yeni** kimlik alır; eskisi "geri alınmış"
/// durumdadır ve hedefli etkilere konu olamaz.
///
/// Kimlik olmadan tekrarlı silme yanlış token'ı işaretliyordu: "son token"
/// ifadesi art arda silmede belirsizdir.
public struct TokenID: Hashable, Codable, Sendable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
}

/// Belgeden silinen bir aralığın token'lara atfı.
///
/// **Tek bir değer yetmiyor:** `deleteWordBackward` önce boşlukları, sonra
/// **tüm** non-whitespace diziyi siliyor. Tokenizer'ın iki token saydığı
/// `wi-fi ` tek çağrıda ikisini ve ayırıcıyı birden yiyebilir.
public enum DeletedSpan: Codable, Equatable, Sendable {
    /// Token'ın **bir kısmı** silindi; kalanı belgede duruyor.
    /// Cursor geri alınmaz — yeniden yazılan harfler aynı hedefe gider.
    case editedToken(TokenID)
    /// Token **tamamen** gitti.
    case removedToken(TokenID)
    /// Ayırıcı — hiçbir token'a ait değil.
    case separator
    /// Defterde karşılığı yok; hiza kayıp.
    case unattributed
}

/// Yıkıcı bir işlemin **kayıpsız** sonucu.
public struct DestructiveEffect: Codable, Equatable, Sendable {

    /// Bekleyen (henüz commit edilmemiş) kanıta ne oldu.
    public enum PendingMutation: String, Codable, Sendable {
        case none
        /// Bir dokunma düştü.
        case dropLast
        /// **Tümü** düştü — `detachEvidence()` ya da `clearComposing()`.
        case dropAll
        /// Önceki token geri açıldı; dokunmaları bekleyene döndü.
        case restoreToken
    }

    /// Kanıtın işlem **sonrasındaki** durumu.
    ///
    /// Olay bildirimi değil **post-state** olması zorunlu: canlı oturum
    /// `isDetached`'i üç ayrı yerde temizliyor (yüzey boşalınca, token
    /// kapanınca, oturum sıfırlanınca). Yalnız "koptu" demek, reducer'ın
    /// kopukluktan **çıkışı** hiç görmemesine ve sonraki bütün harfleri
    /// yanlışlıkla düşürmesine yol açardı.
    public enum EvidenceState: String, Codable, Sendable {
        case attached, detached, cleared
    }

    public var pending: PendingMutation
    /// Belgeden silinen aralıklar, **belgedeki sıraya göre** (eskiden yeniye).
    ///
    /// **Kanonik biçim** — golden karşılaştırması ancak tekilse anlamlı:
    /// bitişik ayırıcılar tek `.separator`'a, bitişik `.unattributed`'lar tek
    /// öğeye indirgenir; her token en fazla **bir** span katkısı yapar;
    /// `[]` "hiçbir şey silinmedi".
    public var deleted: [DeletedSpan]
    public var evidenceStateAfter: EvidenceState
    /// `restoreToken`'da hangi token geri açıldı.
    public var restoredToken: TokenID?

    public init(pending: PendingMutation, deleted: [DeletedSpan],
                evidenceStateAfter: EvidenceState, restoredToken: TokenID? = nil) {
        self.pending = pending
        self.deleted = deleted
        self.evidenceStateAfter = evidenceStateAfter
        self.restoredToken = restoredToken
    }

    /// Yıkıcı olmayan sınır işlemleri (`space`, `symbol`, `newline`,
    /// `suggestionPick`) için: kanıt sıfırlanır, hiçbir şey silinmez.
    ///
    /// Bu değerin **var olması** şart: `finishToken → clearComposing`
    /// `isDetached`'i sıfırlıyor. Sınır işlemleri olgu taşımasaydı reducer'ın
    /// kanıt durumu sonsuza dek `detached` kalırdı.
    public static let boundary = DestructiveEffect(
        pending: .none, deleted: [], evidenceStateAfter: .cleared)
}

/// Bağımsız replay'in motoru sürebilmesi için gereken **tam** komut.
///
/// Kayıtlı sonucu motora geri beslemek replay'i bağımsız olmaktan çıkarır;
/// motor komutlarla yeniden sürülür ve **çıktısı** kayıtla karşılaştırılır.
public enum ReplayCommand: Codable, Equatable, Sendable {
    /// `baseKey` uzamsal kanıtın ait olduğu tuş, `display` belgeye yazılan
    /// biçim. İkisi ayrı olmak zorunda: `İ`/`I` locale'e bağlı ve
    /// `insertLetter` ile `insertUppercaseLetter` farklı yollar — "basılan
    /// karakter" tek başına hangisinin çağrılacağını söylemiyor.
    ///
    /// `baseKey` **tek grapheme** taşır ama tipi `String`: `Character` `Codable`
    /// değil ve elle codec yazmak, JSON temsili zaten string olduğu için
    /// gereksiz bir katman olurdu. Tekillik `SessionValidator`'ın kontrolü.
    case letter(baseKey: String, display: String, shifted: Bool)
    case symbol(String)
    case space
    case newline
    case suggestionPick(id: String, surface: String, origin: SuggestionOrigin)

    /// Üçü **ayrı**: tap sınırda token açabilir, repeat açmaz, deleteWord
    /// bütün bir kelimeyi siler.
    case backspaceTap
    case backspaceRepeat
    case deleteWord
    /// Düzlem değişimi — replay'i sürmek için **hedef** gerekli.
    ///
    /// v2 bunu `"plane.numbers"` gibi tek bir kind string'ine gömüyordu ve
    /// migrasyon üçünü de tek `.planeChange`'e çökertiyordu: hedef düzlem
    /// açıkça kayıtlıyken kayboluyordu.
    case planeChange(String)
    /// Shift durumu değişimi. **Sonuç** durumu taşınıyor, "shift'e basıldı"
    /// değil: aynı tuş kilitli/tek seferlik/kapalı arasında dönüyor ve hangi
    /// duruma geçildiği bilinmeden replay yazılan harfin büyüklüğünü kuramaz.
    case shift(String)

    /// `baseKey`'in tek karakterlik hâli — `layout.keyIndex(for:)` için.
    /// Doğrulanmamış kayıtta çok karakterli olabilir; `nil` dönüşü ihlaldir.
    public var baseCharacter: Character? {
        guard case let .letter(baseKey, _, _) = self,
              baseKey.count == 1 else { return nil }
        return baseKey.first
    }

    public var symbolCharacter: Character? {
        guard case let .symbol(s) = self, s.count == 1 else { return nil }
        return s.first
    }
}

/// Bir paketin motordaki **rolü** — kapalı küme.
///
/// Serbest `String` olduğu sürece kayda `"lexicon"` gibi çalışma anında
/// karşılığı olmayan bir rol yazılabiliyor ve **replay edilemeyen** bir kayıt
/// geçerli sayılıyordu. Küme yükleyicide zaten kapalı; şemanın onu gevşetmesi
/// için sebep yok.
public enum PackRole: String, Codable, Equatable, Sendable, CaseIterable {
    case forms, roots, charModel, expansions
    /// Kişisel sözlük (§8.7) — **diskte paket dosyası yok**.
    ///
    /// Yine de bir `PackRef` olarak kaydediliyor: decoder'ın leksikon
    /// kaynaklarından biri ve onu yazmamak, kaydın kendi motorunu eksik
    /// anlatması demekti. `ReplayEngineFactory` aynı adda bir paket
    /// bulamayacağı için replay'i **ortam uyuşmazlığı** olarak işaretler —
    /// istenen davranış tam da bu: fark sessizce "kod regresyonu" diye
    /// raporlanmasın.
    case personal
}

/// Gösterilen bir önerinin **kökeni**.
///
/// Üyelikten çıkarılamıyor: bir genişletme aynı anda ham aday listesinde de
/// olabilir ama gösterilen ilk üçün dışında kalabilir.
public enum SuggestionOrigin: Codable, Equatable, Sendable {
    case candidate(id: String)
    case expansion(trigger: String)
}

/// Decoder'ın ham adayı — golden'ın "tüm adaylar" karşılaştırması için kanonik tip.
public struct CandidateSnapshot: Codable, Equatable, Sendable {
    /// Adayın kararlı kimliği. v2 kaydetmiyordu → `.unknown`; alan **bazında**
    /// epistemik, çünkü v2 `word`/`cost`/`source`/`language`'ı biliyordu ve
    /// tüm adayı `.unknown` saymak bilinen dördünü de atmak olurdu.
    public var id: Epistemic<String>
    public var word: String
    public var cost: Double
    /// Kaç emisyonla üretildi — omission/insertion teşhisi buna bakıyor.
    public var emitCount: Epistemic<Int>
    public var source: Int
    public var language: Int

    public init(id: Epistemic<String>, word: String, cost: Double,
                emitCount: Epistemic<Int>, source: Int, language: Int) {
        self.id = id; self.word = word; self.cost = cost
        self.emitCount = emitCount; self.source = source; self.language = language
    }
}

/// Kullanıcıya **fiilen gösterilen** yüzey.
/// Gösterilen yüzeylerin listesi **ve** listenin eksiksiz olup olmadığı.
///
/// v2 yalnız decoder adaylarını saklıyordu; öneri çubuğunda ayrıca gösterilen
/// **genişletme** yüzeyleri (`suggestionSurfaces`) o listede yoktu. Bilinen bir
/// altkümeyi eksiksiz liste diye yazmak, "kullanıcı bunu görmedi" sonucunu
/// doğrulanmamış biçimde üretirdi.
public struct ShownSnapshot: Codable, Equatable, Sendable {
    public enum Completeness: String, Codable, Sendable {
        /// Kullanıcının gördüğü **her** yüzey listede.
        case complete
        /// Listedekiler görüldü, ama görülenlerin hepsi listede değil.
        case partial
    }
    public var items: [ShownSuggestion]
    public var completeness: Completeness

    public init(items: [ShownSuggestion], completeness: Completeness) {
        self.items = items; self.completeness = completeness
    }
}

public struct ShownSuggestion: Codable, Equatable, Sendable {
    public var id: Epistemic<String>
    public var surface: String
    /// Köken üyelikten **çıkarılamıyor**: bir genişletme aynı anda ham aday
    /// listesinde de olabilir ama gösterilen ilk üçün dışında kalabilir.
    /// v2 bunu kaydetmiyordu → `.unknown`.
    public var origin: Epistemic<SuggestionOrigin>

    public init(id: Epistemic<String>, surface: String,
                origin: Epistemic<SuggestionOrigin>) {
        self.id = id; self.surface = surface; self.origin = origin
    }
}

/// Bir eylemin belgeye yaptığı değişiklik.
///
/// Her action'da **tam belgeyi** taşımak `O(n²)` yazma demekti: i'nci harfte
/// `O(i)` metin. Mutasyonları taşıyıp metni okuyucuda türetmek aynı
/// doğrulanabilirliği `O(1)` yazmayla veriyor.
public enum DocumentMutation: Codable, Equatable, Sendable {
    case insert(String)
    /// Silme birimi **`Character`** (grapheme) — `deleteBackward` öyle sayıyor.
    case deleteBackward(count: Int)
}

/// Kayıt koşulunun **normatif** politikası.
///
/// Kalibrasyon filtresi bunu okur, `condition`'ı değil: `condition` yalnız
/// **niyeti** gösteriyor ve `literalProtected` yalnız **bir kararın** sonucunu
/// (alternatif aday yokken `false` olabilir). Politika ise motorun fiilen nasıl
/// kurulduğunu söylüyor.
public struct RecordingPolicy: Codable, Equatable, Sendable {
    public enum Correction: String, Codable, Sendable { case applied, suppressed }
    public enum Learning: String, Codable, Sendable { case frozen, live }

    /// Yazılan metin kullanıcıya görünüyor mu.
    public var feedbackVisible: Bool
    /// Öneri çubuğu **dokunulabilir** mi.
    public var suggestionsVisible: Bool
    public var correction: Correction
    public var learning: Learning

    public init(feedbackVisible: Bool, suggestionsVisible: Bool,
                correction: Correction, learning: Learning) {
        self.feedbackVisible = feedbackVisible
        self.suggestionsVisible = suggestionsVisible
        self.correction = correction
        self.learning = learning
    }

    /// Kalibrasyon koşulu: geri bildirim yok, öneri yok, düzeltme yok, öğrenme yok.
    public static let calibration = RecordingPolicy(
        feedbackVisible: false, suggestionsVisible: false,
        correction: .suppressed, learning: .frozen)

    /// Davranış koşulu: gerçek klavye, ama öğrenme yine donmuş — kayıt
    /// kullanıcının profilini kirletmemeli.
    public static let behavior = RecordingPolicy(
        feedbackVisible: true, suggestionsVisible: true,
        correction: .applied, learning: .frozen)
}
