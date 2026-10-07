import Foundation
import KBRuntime

/// Yazım kaydının **kanonik** şeması — sözleşme §12, plan v8 §2.2.
///
/// v2 (`TypingSession`) yanında duruyor ve tüketiciler adım adım buraya geçecek.
/// Aynı anda iki şema tutmak bilinçli: her commit'in yeşil kalması, tek seferde
/// büyük bir geçişten daha güvenli.
///
/// ## Tek kural
///
/// **Bilinmeyen, bilinen gibi kaydedilmez.** v2'nin taşımadığı her olgu
/// `Epistemic.unknown`; `-1`, `""`, `[:]` gibi nöbetçiler kullanılmaz, çünkü
/// nöbetçi tüketici için yasal veriden ayırt edilemez.
///
/// Bunun ikizi de geçerli: v2'nin **taşıdığı** hiçbir olgu düşürülmez.
/// Migrasyon her şeyi `.unknown`'a çevirerek "güvenli" davransaydı eski
/// kayıtlar tamamen değersizleşirdi.
///
/// ## Granülerlik
///
/// `Epistemic` bir **grubu** ancak grubun tamamı birlikte bilinip birlikte
/// bilinmiyorsa sarar. `RecordingPolicy`'nin dördünü tek sarmalın altına
/// koymak, v2'nin gerçekten bildiği `learningFrozen`'ı da kaybettiriyordu —
/// bu yüzden politika bileşen bazında epistemik.
///
/// ## Sürüm-önce okuma
///
/// Blanket `decodeIfPresent` ile geriye uyumluluk **kurulamaz**: eksik alanlı
/// **bozuk bir v3** kaydını da "eski kayıt" sayar. Doğrusu önce `schema`'yı
/// okumak, v2'yi ayrı bir DTO üzerinden migrate etmek, v3'ü **sıkı** decode
/// etmek ve bilinmeyen sürümü reddetmek.
///
/// ## Dosya düzeni
///
/// Oturum düzeyi alanlar burada; iç içe tipler kendi dosyalarında:
/// `+Touch` (dokunma ve son faz), `+Action` (eylem, commit, komut ↔ kip),
/// `+Geometry`, `+EngineSnapshot`. Etiket **kuralı** `CommitLabelRule`'da,
/// kalibrasyonun uygulanması `EngineSnapshotCapture`'da — yakalama ile kurulum
/// karşılıklı dursun diye.
public struct CanonicalSession: Codable, Equatable, Sendable {

    public static let currentSchema = 3

    /// Kaydın **geldiği** şema. Migrasyondan sonra da korunur: `.unknown`
    /// olguların nereden geldiğini açıklayan tek şey bu.
    public var sourceSchema: Int

    /// Şema sürümü — **sabit**.
    ///
    /// `var` olduğu sürece v3 biçimli bir nesne `schema: 2` ile encode
    /// edilebiliyordu; okuyucu onu v2 sanıp migrate etmeye kalkardı ve codec
    /// simetrisi inşa edilebilir bir değer için bozulurdu. `let` + başlangıç
    /// değeri hem memberwise init'ten hem decode'dan çıkarıyor.
    public let schema = CanonicalSession.currentSchema

    // MARK: Kimlik

    public var attemptID: String
    public var participantID: String
    public var protocolVersion: Int
    public var sessionOrdinal: Int

    public enum Condition: String, Codable, Sendable {
        case calibrationReplay, behavior
    }
    public var condition: Condition

    /// Deneme durumu — terminal durumlar **değişmez**.
    ///
    /// `.recording` yarım kalmış bir kaydı anlatıyor ve **terminal değil**.
    /// Okuma sırasında onu `.interrupted` yapmak bir yargıydı: okuyucu
    /// dosyanın bayatladığını da, yazıcının hâlâ koştuğunu da bilmiyor.
    /// Üstelik `endedAt == nil` olan terminal bir durum üretiyordu.
    public enum Status: String, Codable, Sendable {
        case recording, completed, aborted, interrupted, invalid
        /// Kullanıcı **üretimde** yazarken bir dilimi saklamayı seçti.
        ///
        /// `completed`'dan ayrı ve olmak zorunda: orada hedef dizisi var ve
        /// tamamlanma **ölçülüyor** (`cursor == promptTokens.count`). Üretimde
        /// hedef yok — ne yazmak istediğini yalnız kullanıcı biliyor ve o da
        /// nota yazıyor. Böyle bir kaydı `completed` saymak, ölçülmemiş bir şeyi
        /// ölçülmüş göstermek olurdu.
        ///
        /// Kalibrasyona **girmez**: hizalama `constructed` değil, dolayısıyla
        /// uygunluk kapısı onu zaten eliyor. Değeri teşhiste.
        case captured
    }
    public var status: Status

    // MARK: Hedef

    public var promptID: String
    public var promptText: String
    public enum PromptSource: String, Codable, Sendable { case builtin, manual }
    public var promptSource: PromptSource
    public var split: String

    /// **Gösterilen** hedef dizisi.
    ///
    /// Kayda yazılıyor ki tokenizer ileride değişse eski replay değişmesin.
    /// v2 bunu kaydetmiyordu → `.unknown`: bugünkü kuralla yeniden üretmek,
    /// eski replay'i bugünkü koda bağlar ve tokenizer değişince geçmiş
    /// kayıtların anlamını sessizce değiştirirdi.
    public var promptTokens: Epistemic<[String]>

    public enum AlignmentSource: String, Codable, Sendable {
        /// Hedef kelime kelime gösterildi — hizalama UI durumunun **kaydı**.
        case constructed
        /// Cümlenin tamamı görünüyordu; sıraya dayalı, **daha zayıf**.
        case sequential
        case none
    }
    public var alignmentSource: AlignmentSource

    /// **Hedefli protokol** mü — §12.5: niyet gözlemden değil protokolden
    /// biliniyor (hedef kelime kelime gösterildi).
    ///
    /// Yazıcı (etiketi kurarken), golden (etiketi yeniden hesaplarken) ve
    /// validator (etiketi sınarken) bu soruyu ayrı ayrı soruyordu. Üç kopyadan
    /// biri bir koşulu unutsaydı etiket ile doğrulaması sessizce ayrışırdı.
    public var isTargetedProtocol: Bool {
        condition == .calibrationReplay && alignmentSource == .constructed
    }

    // MARK: Koşullar

    public var startedAt: Date
    public var endedAt: Date?

    public struct Posture: Codable, Equatable, Sendable {
        public enum Hands: String, Codable, Sendable {
            case oneThumb, twoThumbs, indexFinger, unknown
        }
        public enum Mobility: String, Codable, Sendable {
            case seated, standing, walking, unknown
        }
        public var hands: Hands
        public var mobility: Mobility
        public init(hands: Hands = .unknown, mobility: Mobility = .unknown) {
            self.hands = hands; self.mobility = mobility
        }
    }
    public var posture: Posture

    // MARK: Motor

    /// Motor anlık görüntüsü.
    ///
    /// **Kendisi daima biliniyor**, `configuration` alanı bilinmeyebilir:
    /// derleme kimliği ve politika deneme başlarken zaten belli, paketler ise
    /// yüklendiğinde. Tüm anlık görüntüyü `Epistemic` sarmak, yer tutucu
    /// durumunda bilinen derleme/politika olgularını da attırıyordu.
    public var engine: EngineSnapshot
    public var geometry: Geometry

    // MARK: Akış

    public var touches: [Touch]
    public var actions: [Action]
    /// Yalnız terminalde yazılır; ara metin `document`'tan türetilir.
    public var finalText: String

    /// Deneme başlarken belge boş muydu.
    ///
    /// `false` ise belge zinciri **dışarıdan doğrulanamaz**: mutasyonlar
    /// bilinmeyen bir tabanın üstüne uygulanıyor. Tabanı kaydetmek host'un
    /// zaten yazılı olan içeriğini saklamak olurdu, dolayısıyla bilinmediğini
    /// **söylemek** tek dürüst seçenek.
    /// `nil` = kayıt bunu söylemiyor. Bu bir tahmin değil olgu: alan eklenmeden
    /// önceki bütün v3 kayıtları kayıt ekranından geliyor ve oradaki tampon
    /// **sıfırdan** başlıyor. Zorunlu alan yapmak diskteki gerçek kayıtları
    /// okunamaz hâle getirirdi.
    public var documentBaselineKnown: Bool?

    /// Taban biliniyor mu — okumayan tüketiciler için.
    public var documentBaselineIsKnown: Bool { documentBaselineKnown ?? true }

    /// Kullanıcının denemeden **sonra** yazdığı not — "ne yazmak istedim, ne
    /// oldu".
    ///
    /// **Anlatı, ölçüm değil.** Şemanın geri kalanı klavyenin ürettiği olgular;
    /// bu alan ölçümün açıklayamadığı şeyi taşıyor. Ayrı durması bilinçli: bir
    /// gün analize girerse kaynağının insan olduğu görünmeli. Boş bırakılabilir
    /// ve bırakılması bir eksiklik değil.
    public var note: String?

    /// Yalnız v2'de var olan oturum düzeyi olgular.
    ///
    /// v3'te `.notApplicable`: hepsi olay günlüğünden **tam** olarak
    /// türetilebiliyor, dolayısıyla ayrıca kaydetmek aynı olguyu iki yerde
    /// tutmak olurdu.
    public var legacy: Epistemic<LegacySessionFacts>

    public struct LegacySessionFacts: Codable, Equatable, Sendable {
        /// v2'nin kalibrasyon dışlama olgusu: kullanıcı geri silip önceki
        /// token'ı yeniden açtı mı. v3'te `backspace*` action'larının varlığı
        /// aynı şeyi daha kesin söylüyor.
        public var hadBackspace: Bool
        public init(hadBackspace: Bool) { self.hadBackspace = hadBackspace }
    }

    public init(sourceSchema: Int = CanonicalSession.currentSchema,
                attemptID: String, participantID: String,
                protocolVersion: Int = 1, sessionOrdinal: Int,
                condition: Condition, status: Status = .recording,
                promptID: String, promptText: String, promptSource: PromptSource,
                split: String, promptTokens: Epistemic<[String]>,
                alignmentSource: AlignmentSource, startedAt: Date,
                endedAt: Date? = nil, posture: Posture = .init(),
                engine: EngineSnapshot, geometry: Geometry,
                touches: [Touch] = [], actions: [Action] = [],
                finalText: String = "", note: String? = nil,
                legacy: Epistemic<LegacySessionFacts> = .notApplicable) {
        self.sourceSchema = sourceSchema
        self.attemptID = attemptID; self.participantID = participantID
        self.protocolVersion = protocolVersion
        self.sessionOrdinal = sessionOrdinal
        self.condition = condition; self.status = status
        self.promptID = promptID; self.promptText = promptText
        self.promptSource = promptSource; self.split = split
        self.promptTokens = promptTokens
        self.alignmentSource = alignmentSource
        self.startedAt = startedAt; self.endedAt = endedAt
        self.posture = posture
        self.note = note
        self.engine = engine; self.geometry = geometry
        self.touches = touches; self.actions = actions
        self.finalText = finalText
        self.legacy = legacy
    }
}
