import Foundation
import KBGeometry
import KBRuntime
import KBSpatial

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

    /// Türkçe küçük harf — `i/I` ve `ı/İ` ayrımı locale'e bağlı.
    ///
    /// **Tek yerde**: etiketi üreten (`RecordingEngine`) ve doğrulayan
    /// (`SessionValidator`) aynı kuralı kullanmak zorunda. İki kopya olsaydı biri
    /// `Locale`'i unutur ve `Ali`/`ali` karşılaştırması iki tarafta farklı sonuç
    /// verirdi — doğrulama da yazıcıyı onaylamış olurdu.
    public static func turkishLowercased(_ s: String) -> String {
        TurkishText.lowercased(s)
    }

    /// `touchID` → dokunmanın **son** fazı.
    ///
    /// ## Neden tek yerde
    ///
    /// Kayıt bir dokunmanın her fazını ayrı frame olarak taşıyor (gerçek bir
    /// cihaz kaydında 36 dokunma için 78 frame). Canlı motor sözlüğünü
    /// `touches[id] = touch` ile güncellediği için **son** fazı görüyor; diskten
    /// okuyan tarafta ise `uniquingKeysWith: { a, _ in a }` **ilk** fazı
    /// seçiyordu. Yani reducer, golden replay ve kalibrasyon `began`
    /// koordinatını kullanırken decoder `ended` koordinatını kullanmıştı.
    ///
    /// Sonuç sessizdi: kayıt doğru metni taşıyor, yaşam döngüsü validator'dan
    /// geçiyor, ama kalibrasyon **yanlış koordinatı** öğreniyor. Sürükleme
    /// olduğunda fark tuş genişliği mertebesine çıkıyor.
    ///
    /// Ayrıca `outcome` da faza bağlı: `began` daima `pending`, dolayısıyla
    /// `neverHit` teşhisi ilk faza bakıldığında hiç çalışmıyordu.
    ///
    /// Seçim **faza göre** yapılıyor, dosya sırasına göre değil: sıra bir
    /// değişmez değil ve ona bel bağlamak aynı hatayı başka bir kılıkta geri
    /// getirirdi.
    public var terminalTouches: [Int: Touch] {
        var out: [Int: Touch] = [:]
        for touch in touches {
            guard let existing = out[touch.touchID] else {
                out[touch.touchID] = touch
                continue
            }
            if touch.phase.isTerminal || !existing.phase.isTerminal {
                out[touch.touchID] = touch
            }
        }
        return out
    }

    // MARK: - Dokunma

    public struct Touch: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            case began, moved, ended, cancelled

            /// Dokunmanın **bittiği** fazlar.
            ///
            /// Kayıt tüketicileri hangi frame'in dokunmayı temsil ettiğini
            /// buradan soruyor; her biri kendi kuralını yazsaydı biri
            /// `cancelled`'ı atlar ve iptal edilmiş bir dokunma "hiç bitmemiş"
            /// sayılırdı.
            public var isTerminal: Bool {
                self == .ended || self == .cancelled
            }
        }
        /// Dokunmanın akıbeti.
        ///
        /// `neverHit` ile `leftBounds` **ayrı**: ilki `touchesBegan`'ın hiçbir
        /// tuşa denk gelmediği (görsel geri bildirim de yok), ikincisi tuşa
        /// basılıp parmağın dışarı kaydığı durum. Kullanıcının "boşluk bazen
        /// çalışmıyor" gözleminin iki farklı sebebi bunlar ve tek değere
        /// indirilirse hangisi olduğu ölçülemez.
        public enum Outcome: String, Codable, Sendable {
            case pending, committed, cancelled, leftBounds, neverHit, repeated
        }
        public var touchID: Int
        public var phase: Phase
        public var outcome: Outcome
        public var rawX: Double, rawY: Double
        public var normX: Double?, normY: Double?
        /// Decoder'a **fiilen** verilen nokta — ham noktayla aynı olmayabilir.
        public var decoderX: Double?, decoderY: Double?
        public var timestamp: TimeInterval
        public var majorRadius: Double
        public var majorRadiusTolerance: Double
        public var plane: String
        public var shift: String
        public var hitKind: String?
        public var key: String?
        public var keyIndex: Int?

        public init(touchID: Int, phase: Phase, outcome: Outcome,
                    rawX: Double, rawY: Double, normX: Double?, normY: Double?,
                    decoderX: Double?, decoderY: Double?, timestamp: TimeInterval,
                    majorRadius: Double, majorRadiusTolerance: Double,
                    plane: String, shift: String,
                    hitKind: String?, key: String?, keyIndex: Int?) {
            self.touchID = touchID; self.phase = phase; self.outcome = outcome
            self.rawX = rawX; self.rawY = rawY
            self.normX = normX; self.normY = normY
            self.decoderX = decoderX; self.decoderY = decoderY
            self.timestamp = timestamp
            self.majorRadius = majorRadius
            self.majorRadiusTolerance = majorRadiusTolerance
            self.plane = plane; self.shift = shift
            self.hitKind = hitKind; self.key = key; self.keyIndex = keyIndex
        }
    }

    // MARK: - Eylem

    public struct Action: Codable, Equatable, Sendable {

        /// Olay türü — **typed**, serbest string değil.
        ///
        /// String kind'lar üç yerde elle eşleniyordu (kayıt, token türetimi,
        /// golden) ve ayrışmışlardı: `backspaceWord` bir yerde işlenip
        /// diğerinde `default`'a düşüyordu. Derleyicinin yakalayabileceği bir
        /// hatayı çalışma anına bırakmanın bedeliydi.
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case letter, symbol, space, newline, suggestionPick
            /// Üçü ayrı: tap sınırda token açabilir, repeat açmaz, deleteWord
            /// bütün bir kelimeyi siler.
            case backspaceTap, backspaceRepeat, deleteWord
            case shift, planeChange
            /// **Yalnız v2 migrasyonunun** ürettiği kip; v3 asla yazmaz.
            ///
            /// v2 hem tap'i hem character-repeat'i aynı `"backspace"` ile
            /// yazıyordu. Kesin bir kipe uydurmak olguyu uydurmak olurdu.
            case backspaceUnspecified

            /// Token'ı kapatan olaylar — beam **tam burada** sıfırlanır.
            public var closesToken: Bool {
                switch self {
                case .space, .symbol, .suggestionPick, .newline: return true
                default: return false
                }
            }

            /// Artımlı beam durumunu bozan olaylar.
            public var invalidatesBeam: Bool {
                switch self {
                case .backspaceTap, .backspaceRepeat, .deleteWord,
                     .backspaceUnspecified: return true
                default: return false
                }
            }

            /// v3'ün üretmesi yasak olan kipler.
            public var isLegacyOnly: Bool { self == .backspaceUnspecified }
        }

        public var actionID: Int
        public var t: TimeInterval
        public var kind: Kind
        public var touchID: Int?

        /// Bağımsız replay'in motoru sürmesi için gereken komut.
        public var event: Epistemic<ReplayCommand>
        /// Yıkıcı işlemin kayıpsız sonucu; harf/UI olaylarında `.notApplicable`.
        public var effect: Epistemic<DestructiveEffect>

        /// Belgeye yapılan değişiklik ve sonrasındaki özet.
        ///
        /// İkisi **tek** olgu: mutasyon listesi özetsiz doğrulanamaz, özet de
        /// mutasyonsuz anlamsız. Ayrı alan olsalardı v2 migrasyonu `[]` + `0`
        /// yazmak zorunda kalırdı — ama boş mutasyon listesi `shift` gibi
        /// action'larda **yasal**, dolayısıyla "değişiklik yok" ile "bilinmiyor"
        /// ayırt edilemezdi.
        public var document: Epistemic<DocumentDelta>

        /// Bir action'ın belgeye etkisi — tam metin **taşınmıyor** (§O(n²)).
        public struct DocumentDelta: Codable, Equatable, Sendable {
            public var mutations: [DocumentMutation]
            /// Action **sonrası** tam belgenin FNV-1a 64 özeti.
            public var hashAfter: UInt64
            public init(mutations: [DocumentMutation], hashAfter: UInt64) {
                self.mutations = mutations; self.hashAfter = hashAfter
            }
        }

        public var targetTokenIndex: Int?
        public var targetToken: String?

        /// Decoder'ın ham adayları.
        ///
        /// `.notApplicable` = bu action'da anlık görüntü **alınmadı** (harf
        /// başına aday listesi tutmak kaydı gereksiz şişirir); `.known([])` =
        /// alındı ve boştu. İkisi ayrı sorulara cevap veriyor.
        public var candidates: Epistemic<[CandidateSnapshot]>
        /// Kullanıcıya **fiilen gösterilenler** — ham aday listesinden ayrı.
        ///
        /// Liste **ve** bütünlüğü birlikte: v2'de bilinen altküme eksiksiz
        /// liste diye yazılırsa "kullanıcı bunu görmedi" sonucu doğrulanmamış
        /// biçimde üretilirdi.
        public var shown: Epistemic<ShownSnapshot>

        public var commit: Commit?

        /// Yalnız v2'de var olan action düzeyi olgular.
        public var legacy: Epistemic<LegacyActionFacts>

        public struct LegacyActionFacts: Codable, Equatable, Sendable {
            /// §12.4'ün sapma bayrağı. v3 bunu `effect` olgularından **kesin**
            /// olarak katlıyor; v2'de tek kanıt bu bayraktı ve mevcut importer
            /// onu tüketiyor.
            public var alignmentDiverged: Bool
            /// v2 her action'da belgenin **tam metnini** taşıyordu. v3 mutasyon
            /// + özet kullanıyor (`O(n²)` yazma yerine `O(1)`), ama eski
            /// kayıtlarda doğrulanabilirliğin tek kaynağı bu metin.
            public var textAfter: String?

            public init(alignmentDiverged: Bool, textAfter: String?) {
                self.alignmentDiverged = alignmentDiverged
                self.textAfter = textAfter
            }
        }

        public init(actionID: Int, t: TimeInterval, kind: Kind, touchID: Int?,
                    event: Epistemic<ReplayCommand>,
                    effect: Epistemic<DestructiveEffect>,
                    document: Epistemic<DocumentDelta>,
                    targetTokenIndex: Int?, targetToken: String?,
                    candidates: Epistemic<[CandidateSnapshot]>,
                    shown: Epistemic<ShownSnapshot>,
                    commit: Commit?,
                    legacy: Epistemic<LegacyActionFacts> = .notApplicable) {
            self.actionID = actionID; self.t = t; self.kind = kind
            self.touchID = touchID
            self.event = event; self.effect = effect
            self.document = document
            self.targetTokenIndex = targetTokenIndex; self.targetToken = targetToken
            self.candidates = candidates; self.shown = shown
            self.commit = commit
            self.legacy = legacy
        }

        public struct Commit: Codable, Equatable, Sendable {
            public enum Kind: String, Codable, Sendable {
                case literal, autocorrect, suggestion, expansion, empty
            }
            public var kind: Kind
            /// Token'ın kararlı kimliği.
            ///
            /// v2'de **yoktu**. `actionID`'den türetmek deterministik olurdu
            /// ama deterministik olmak onu gözlenmiş olgu yapmaz: türetilmiş
            /// bir kimliği gerçek kimlik gibi yazmak §6.2 ihlalidir ve hedefli
            /// silme onun üzerinden yanlış token'ı işaretlerdi.
            public var tokenID: Epistemic<TokenID>
            public var literal: String
            public var displayBefore: String
            public var committed: String
            public var delta: Double?
            public var theta: Double?
            public var bestCost: Double?
            public var bestWord: String?
            public var language: Int?
            public var touchCount: Int
            public var casingApplied: Bool
            /// `θ` sonsuzdu — literal korundu. JSON sonsuz taşıyamaz.
            public var literalProtected: Bool
            /// §12.5 etiket gücü. Serbest string değil: değer kümesi
            /// sözleşmede kapalı ve tanınmayan bir değer "eski kayıt" değil
            /// **bozuk** kayıttır.
            public var label: Label

            public struct Label: Codable, Equatable, Sendable {
                /// Niyet nereden biliniyor: protokolden mi, üretim
                /// gözleminden mi.
                public enum Source: String, Codable, Sendable {
                    case `protocol`, production
                }
                /// §12.5: hedefli kayıtta `literal == hedef` ise `strong`.
                /// Koşulsuz `strong` yazmak etiketi sözleşmeden güçlü yapardı.
                public enum Confidence: String, Codable, Sendable {
                    case strong, weak
                }
                public var source: Source
                public var confidence: Confidence
                /// Bu token hangi hedef kelimeye karşılık geliyordu.
                public var targetWord: String?
                public var matchesTarget: Bool?

                public init(source: Source, confidence: Confidence,
                            targetWord: String?, matchesTarget: Bool?) {
                    self.source = source; self.confidence = confidence
                    self.targetWord = targetWord
                    self.matchesTarget = matchesTarget
                }

                /// §12.5 kuralı — **tek** uygulama.
                ///
                /// > `calibrationReplay` koşulunda, hedef kelime kelime kelime
                /// > gösterilmişse ve `literal == hedef` ise, o token `strong`
                /// > sayılabilir — çünkü niyet gözlemden değil **protokolden**
                /// > bilinir.
                ///
                /// Yazıcı (`RecordingEngine`) ve golden replay aynı fonksiyonu
                /// çağırıyor. İki kopya olsaydı golden kural değişikliğini
                /// **fark olarak göremezdi**: kendi kopyası da değişmediği
                /// sürece iki taraf da eski kuralı uygular ve regresyon
                /// görünmez kalırdı.
                public static func make(literal: String,
                                        promptTokens: [String]?,
                                        cursor: Int,
                                        alignmentIsConstructed: Bool,
                                        diverged: Bool) -> Label {
                    let target = promptTokens.flatMap {
                        cursor >= 0 && cursor < $0.count ? $0[cursor] : nil
                    }
                    let matches = target.map {
                        CanonicalSession.turkishLowercased(literal)
                            == CanonicalSession.turkishLowercased($0)
                    }
                    guard alignmentIsConstructed else {
                        return .init(source: .production, confidence: .weak,
                                     targetWord: target, matchesTarget: matches)
                    }
                    // Sapma varsa protokolün verdiği kesinlik de gitmiştir:
                    // token artık gösterilen kelimeye bağlı değil.
                    let strong = !diverged && matches == true
                    return .init(source: .protocol,
                                 confidence: strong ? .strong : .weak,
                                 targetWord: target, matchesTarget: matches)
                }
            }

            /// Commit **öncesi** cursor — geri açma/tam silme bunu geri yükler.
            ///
            /// v2'de yoktu ve `targetWordIndex`'ten türetmek §6.2'nin
            /// yasakladığı çıkarım olurdu → `.unknown`, tüketici için "bu token
            /// geri açılamaz".
            public var cursorBefore: Epistemic<Int>

            public init(kind: Kind, tokenID: Epistemic<TokenID>, literal: String,
                        displayBefore: String, committed: String,
                        delta: Double?, theta: Double?, bestCost: Double?,
                        bestWord: String?, language: Int?, touchCount: Int,
                        casingApplied: Bool, literalProtected: Bool,
                        label: Label, cursorBefore: Epistemic<Int>) {
                self.kind = kind; self.tokenID = tokenID
                self.literal = literal; self.displayBefore = displayBefore
                self.committed = committed
                self.delta = delta; self.theta = theta
                self.bestCost = bestCost; self.bestWord = bestWord
                self.language = language; self.touchCount = touchCount
                self.casingApplied = casingApplied
                self.literalProtected = literalProtected
                self.label = label
                self.cursorBefore = cursorBefore
            }
        }
    }

    // MARK: - Geometri

    public struct Geometry: Codable, Equatable, Sendable {
        public var layoutID: String
        /// **Tam layout parmak izi.** `layoutID` tekil değil: aynı kimlikle tuş
        /// sırası, geometri ve `asciiBase` değişebilir ve bu, kod regresyonu
        /// diye yanlış sınıflanırdı. v2'de yoktu → `.unknown`.
        public var layoutFingerprint: Epistemic<String>
        public var boundsX: Double, boundsY: Double
        public var boundsWidth: Double, boundsHeight: Double
        public var frameInScreenX: Double, frameInScreenY: Double
        public var frameInScreenWidth: Double, frameInScreenHeight: Double
        public var safeAreaBottom: Double
        public var screenScale: Double
        public var interfaceOrientation: String
        public var deviceModel: String
        public var systemVersion: String

        public init(layoutID: String, layoutFingerprint: Epistemic<String>,
                    boundsX: Double, boundsY: Double,
                    boundsWidth: Double, boundsHeight: Double,
                    frameInScreenX: Double, frameInScreenY: Double,
                    frameInScreenWidth: Double, frameInScreenHeight: Double,
                    safeAreaBottom: Double, screenScale: Double,
                    interfaceOrientation: String, deviceModel: String,
                    systemVersion: String) {
            self.layoutID = layoutID; self.layoutFingerprint = layoutFingerprint
            self.boundsX = boundsX; self.boundsY = boundsY
            self.boundsWidth = boundsWidth; self.boundsHeight = boundsHeight
            self.frameInScreenX = frameInScreenX; self.frameInScreenY = frameInScreenY
            self.frameInScreenWidth = frameInScreenWidth
            self.frameInScreenHeight = frameInScreenHeight
            self.safeAreaBottom = safeAreaBottom
            self.screenScale = screenScale
            self.interfaceOrientation = interfaceOrientation
            self.deviceModel = deviceModel
            self.systemVersion = systemVersion
        }
    }

    // MARK: - Motor anlık görüntüsü

    /// Replay'in **birebir** olabilmesi için gereken her şey.
    ///
    /// `appVersion` yetmez: aynı binary farklı paketle koşabilir. Temiz commit
    /// de tekil binary tanımlamaz — aynı kaynak farklı toolchain'de farklı
    /// sonuç verebilir ve bu kod regresyonu sanılırdı.
    public struct EngineSnapshot: Codable, Equatable, Sendable {
        public var buildConfiguration: String
        public var appVersion: String
        public var build: BuildManifest
        public var policy: PolicyRecord

        /// Paketler yüklendiğinde belli olan her şey.
        ///
        /// v2 yazıcısı oturum başında, paketler yüklenmeden bir **yer tutucu**
        /// (`beamWidth: 0`, `packs: []`) diske yazıyor ve yükleme bitince
        /// üzerine yazıyor. Deneme yükleme bitmeden yarıda kalırsa kayıtta yer
        /// tutucu kalıyor; onu gerçek konfigürasyon diye taşımak `beamWidth`'i
        /// sıfır olan bir motoru olgu gibi kaydetmek olurdu.
        ///
        /// Yalnız **bu** kısım `.unknown`: derleme kimliği, sürüm ve politika
        /// yer tutucuda da doğru ve atılmaları için sebep yok.
        public var configuration: Epistemic<Configuration>

        public struct Configuration: Codable, Equatable, Sendable {
            public var packs: [PackRef]
            public var beamWidth: Int
            public var oovTheta: Double
            public var suggestionWindow: Double
            public var autoCorrectsOutOfVocabulary: Bool
            /// Skor modelinin **tamamı** — replay bunsuz kurulamaz. v2
            /// taşımıyordu; `-1`/`[:]` nöbetçileriyle yazmak bilinmeyeni yasal
            /// görünen bir değere çevirmek olurdu.
            public var scoring: Epistemic<ScoringConfig>
            public var calibration: CalibrationSnapshot
            /// Oturum başındaki dil durumu — `remember(language:)` sonraki
            /// token'ların maliyetini etkiliyor.
            public var initialLanguage: Int?

            public init(packs: [PackRef], beamWidth: Int, oovTheta: Double,
                        suggestionWindow: Double,
                        autoCorrectsOutOfVocabulary: Bool,
                        scoring: Epistemic<ScoringConfig>,
                        calibration: CalibrationSnapshot,
                        initialLanguage: Int?) {
                self.packs = packs; self.beamWidth = beamWidth
                self.oovTheta = oovTheta
                self.suggestionWindow = suggestionWindow
                self.autoCorrectsOutOfVocabulary = autoCorrectsOutOfVocabulary
                self.scoring = scoring
                self.calibration = calibration
                self.initialLanguage = initialLanguage
            }
        }

        /// Kaydın **normatif** koşulu — bileşen bazında epistemik.
        ///
        /// Dördünü tek `Epistemic` altına koymak, v2'nin gerçekten bildiği
        /// `learningFrozen`'ı da kaybettiriyordu. Kalibrasyon filtresi bunu
        /// okuyor, `condition`'ı değil: `condition` yalnız **niyeti** gösteriyor,
        /// motorun fiilen nasıl kurulduğunu değil.
        public struct PolicyRecord: Codable, Equatable, Sendable {
            /// Yazılan metin kullanıcıya görünüyor muydu.
            public var feedbackVisible: Epistemic<Bool>
            /// Öneri çubuğu **dokunulabilir** miydi.
            public var suggestionsVisible: Epistemic<Bool>
            public var correction: Epistemic<RecordingPolicy.Correction>
            /// **Sarmalayıcı yok**: §12.3 şart koştuğu için v2 de yazıyordu,
            /// v3 de daima biliyor. `.unknown` için meşru bir durum olmayınca
            /// `Epistemic` yalnız tüketiciye gereksiz bir dal açıyor.
            public var learning: RecordingPolicy.Learning

            public init(feedbackVisible: Epistemic<Bool>,
                        suggestionsVisible: Epistemic<Bool>,
                        correction: Epistemic<RecordingPolicy.Correction>,
                        learning: RecordingPolicy.Learning) {
                self.feedbackVisible = feedbackVisible
                self.suggestionsVisible = suggestionsVisible
                self.correction = correction
                self.learning = learning
            }

            /// v3 yazıcısının yolu: politika bütün olarak biliniyor.
            public init(_ p: RecordingPolicy) {
                self.init(feedbackVisible: .known(p.feedbackVisible),
                          suggestionsVisible: .known(p.suggestionsVisible),
                          correction: .known(p.correction),
                          learning: p.learning)
            }
        }

        /// Skor modelini birebir kurmak için gereken her şey.
        ///
        /// **İki ayrı `ScoreWeights` var**: decoder'ınki ve literal kanalınınki.
        /// Tek sözlük yazmak, ikisinin ayrıştığı bir kaydı birmiş gibi
        /// gösterirdi — `PackLoader` bugün onları eşitliyor ama bu bir çalışma
        /// anı davranışı, şema değişmezi değil.
        public struct ScoringConfig: Codable, Equatable, Sendable {
            public var decoder: WeightsSnapshot
            public var literalChannel: WeightsSnapshot
            /// Sözlük dışı karakter maliyeti — kanal kalibre değilse yedek.
            public var cUnk: Double
            /// Uzamsal modelin alt sınırı.
            public var sigmaMin: Double
            /// Decoder'ın dil modeli.
            public var decoderLanguageModel: LanguageModelSnapshot
            /// Literal kanalının **ayrı** dil modeli kopyası.
            ///
            /// Runtime'da gerçekten iki kopya var. Tek alana çökertmek,
            /// ayrıştıkları bir kaydı birmiş gibi gösterip replay'i sessizce
            /// yanlış kurardı.
            public var literalChannelLanguageModel: LanguageModelSnapshot

            /// Skor ağırlıkları — **her alan adıyla ve gerçek tipiyle**.
            ///
            /// Açık bir `[String: Double]` sözlüğü sıkı v3 decode'undan
            /// geçiyordu: eksik ağırlık, fazladan anahtar ve
            /// `maxKeyCandidates: 6.5` gibi geçersiz tamsayılar fark
            /// edilmiyordu. Tipli alanlar bunların üçünü de derleyiciye ve
            /// decoder'a yaptırıyor.
            public struct WeightsSnapshot: Codable, Equatable, Sendable {
                public var wSpaEq: Double, wEq: Double
                public var wOmGem: Double, wOmInit: Double, wOm: Double
                public var wInsNear: Double, wInsRepeat: Double
                public var wIns: Double, wInsBg: Double
                public var wTr: Double, wLen: Double, wLex: Double
                public var wCtx: Double, wLang: Double, wSwitch: Double
                public var maxConsecutiveOmissions: Int
                public var maxKeyCandidates: Int
                public var candidateCostWindow: Double
                public var tauFast: Double, dNear: Double

                public init(wSpaEq: Double, wEq: Double, wOmGem: Double,
                            wOmInit: Double, wOm: Double, wInsNear: Double,
                            wInsRepeat: Double, wIns: Double, wInsBg: Double,
                            wTr: Double, wLen: Double, wLex: Double,
                            wCtx: Double, wLang: Double, wSwitch: Double,
                            maxConsecutiveOmissions: Int, maxKeyCandidates: Int,
                            candidateCostWindow: Double, tauFast: Double,
                            dNear: Double) {
                    self.wSpaEq = wSpaEq; self.wEq = wEq
                    self.wOmGem = wOmGem; self.wOmInit = wOmInit; self.wOm = wOm
                    self.wInsNear = wInsNear; self.wInsRepeat = wInsRepeat
                    self.wIns = wIns; self.wInsBg = wInsBg
                    self.wTr = wTr; self.wLen = wLen; self.wLex = wLex
                    self.wCtx = wCtx; self.wLang = wLang; self.wSwitch = wSwitch
                    self.maxConsecutiveOmissions = maxConsecutiveOmissions
                    self.maxKeyCandidates = maxKeyCandidates
                    self.candidateCostWindow = candidateCostWindow
                    self.tauFast = tauFast; self.dNear = dNear
                }
            }

            public struct LanguageModelSnapshot: Codable, Equatable, Sendable {
                /// Dil kimliği → önsel maliyet.
                public var prior: [UInt8: Double]
                /// Oturum başındaki `previous` — dil geçiş cezası buna bakıyor.
                public var previous: UInt8?

                public init(prior: [UInt8: Double], previous: UInt8?) {
                    self.prior = prior; self.previous = previous
                }
            }

            public init(decoder: WeightsSnapshot,
                        literalChannel: WeightsSnapshot,
                        cUnk: Double, sigmaMin: Double,
                        decoderLanguageModel: LanguageModelSnapshot,
                        literalChannelLanguageModel: LanguageModelSnapshot) {
                self.decoder = decoder
                self.literalChannel = literalChannel
                self.cUnk = cUnk
                self.sigmaMin = sigmaMin
                self.decoderLanguageModel = decoderLanguageModel
                self.literalChannelLanguageModel = literalChannelLanguageModel
            }
        }

        public struct BuildManifest: Codable, Equatable, Sendable {
            /// v2'nin taşıdığı **tek** derleme olgusu — ve o da `"unknown"`
            /// olabiliyordu, çünkü build fazı hiç koşmuyordu.
            public var codeRevision: Epistemic<String>
            /// Gerisi v2'de yoktu.
            public var provenance: Epistemic<Provenance>

            public struct Provenance: Codable, Equatable, Sendable {
                /// Temiz mi kirli mi — ve kirliyse **hangi** kirli.
                ///
                /// Ayrı `dirty: Bool` + `sourceDigest: String` alanları
                /// `dirty == true` ama digest boş gibi çelişkili durumları
                /// temsil edilebilir kılıyordu.
                public enum SourceTree: Codable, Equatable, Sendable {
                    case clean
                    /// Özet **boş olamaz**: `.dirty(digest: "")` enum'un
                    /// kapatmak için var olduğu çelişkinin ta kendisiydi.
                    /// Kirli olduğunu söyleyip hangi kirli olduğunu
                    /// söylememek, `dirty: true` + boş `sourceDigest`
                    /// alanlarının aynısı.
                    case dirty(digest: String)
                    /// Kirli ama özeti hesaplanamadı (git yok, depo değil).
                    case dirtyUnknownDigest

                    public init(digest: String?) {
                        guard let digest else { self = .clean; return }
                        self = digest.isEmpty ? .dirtyUnknownDigest
                                              : .dirty(digest: digest)
                    }
                }
                public var sourceTree: SourceTree
                public var swiftVersion: String
                public var targetTriple: String
                public var arch: String
                /// `-Onone` ile `-O` arasında **13 kat** gecikme farkı ölçüldü;
                /// hangisiyle alındığı bilinmeden zamanlama karşılaştırılamaz.
                public var optimization: String
                public var xcodeVersion: String

                public init(sourceTree: SourceTree, swiftVersion: String,
                            targetTriple: String, arch: String,
                            optimization: String, xcodeVersion: String) {
                    self.sourceTree = sourceTree
                    self.swiftVersion = swiftVersion
                    self.targetTriple = targetTriple
                    self.arch = arch
                    self.optimization = optimization
                    self.xcodeVersion = xcodeVersion
                }
            }

            public init(codeRevision: Epistemic<String>,
                        provenance: Epistemic<Provenance>) {
                self.codeRevision = codeRevision
                self.provenance = provenance
            }
        }

        public struct PackRef: Codable, Equatable, Sendable {
            public var name: String
            /// v2 yazıcısı özet hesaplamayı atlayabiliyordu → `.unknown`.
            public var sha256: Epistemic<String>
            public var bytes: Int
            /// Ad ve hash **topolojiyi kanıtlamaz**: aynı dosya farklı rolde,
            /// farklı dilde ya da farklı kaynak sırasında yüklenebilir.
            /// v2 topolojiyi hiç taşımıyordu → `.unknown`.
            public var topology: Epistemic<Topology>

            public struct Topology: Codable, Equatable, Sendable {
                /// Kapalı küme — serbest `String` replay edilemeyen bir rol
                /// yazılmasına izin veriyordu.
                public var role: PackRole
                public var language: Int
                /// `LexiconSet.sources` içindeki sıra; sözlük kaynağı olmayan
                /// paketlerde (karakter modeli, genişletme) `nil`.
                public var sourceOrder: Int?
                /// Kaynak maliyet ofseti; yalnız sözlük kaynaklarında anlamlı.
                public var offset: Double?
                public init(role: PackRole, language: Int, sourceOrder: Int?,
                            offset: Double?) {
                    self.role = role; self.language = language
                    self.sourceOrder = sourceOrder; self.offset = offset
                }
            }

            public init(name: String, sha256: Epistemic<String>, bytes: Int,
                        topology: Epistemic<Topology>) {
                self.name = name; self.sha256 = sha256; self.bytes = bytes
                self.topology = topology
            }
        }

        public struct CalibrationSnapshot: Codable, Equatable, Sendable {
            public var applied: Bool
            public var strongSamples: Int
            /// Tuş başına toplam sapma — v2 de taşıyordu.
            public var biasX: [Double]
            public var biasY: [Double]
            /// Hiyerarşik ayrışım (`b_c = g + r_row(c) + d_c`) — v2 de taşıyordu.
            public var hierarchical: Hierarchical
            /// v2 yalnız sapmayı kaydediyordu, ölçeği değil → `.unknown`.
            /// `[]` yazmak "kalibre edilmiş σ yok" demekti; oysa vardı,
            /// kaydedilmemişti.
            public var sigma: Epistemic<Sigma>

            public struct Hierarchical: Codable, Equatable, Sendable {
                public var globalX: Double, globalY: Double
                public var rowX: [Double], rowY: [Double]
                public var keyX: [Double], keyY: [Double]
                public init(globalX: Double, globalY: Double,
                            rowX: [Double], rowY: [Double],
                            keyX: [Double], keyY: [Double]) {
                    self.globalX = globalX; self.globalY = globalY
                    self.rowX = rowX; self.rowY = rowY
                    self.keyX = keyX; self.keyY = keyY
                }
            }

            public struct Sigma: Codable, Equatable, Sendable {
                public var x: [Double]
                public var y: [Double]
                public init(x: [Double], y: [Double]) { self.x = x; self.y = y }
            }

            public init(applied: Bool, strongSamples: Int,
                        biasX: [Double], biasY: [Double],
                        hierarchical: Hierarchical, sigma: Epistemic<Sigma>) {
                self.applied = applied; self.strongSamples = strongSamples
                self.biasX = biasX; self.biasY = biasY
                self.hierarchical = hierarchical
                self.sigma = sigma
            }
        }

        /// Kaydedilen kalibrasyonu uzamsal modele uygular — **tek** uygulama.
        ///
        /// Hem `RecordingEngine.configure` hem `ReplayEngineFactory` buradan
        /// geçiyor. Önce yalnız replay uyguluyordu: `configure` snapshot'ı
        /// **kaydediyor ama motora uygulamıyordu**, yani `applied: true` verilen
        /// bir kayıtta canlı motor kalibrasyonsuz koşarken kayıt "uygulandı"
        /// diyor ve replay kalibrasyonlu koşuyordu. Fark ortam uyuşmazlığı
        /// olarak da görünmüyordu — sahte bir kod regresyonu olarak okunurdu.
        ///
        /// Kısa dizide sessizce durmak da tehlikeliydi: yarısı kalibre bir model
        /// kurulup ortam yine "doğrulanabilir" kalıyordu. Artık eksik dizi
        /// **hiçbir şey uygulamıyor** ve çağıran bunu öğreniyor.
        ///
        /// - Returns: uygulandıysa `true`; dizi eksikse `false`.
        @discardableResult
        static func applyCalibration(
            _ cal: CalibrationSnapshot,
            sigma: CalibrationSnapshot.Sigma,
            to spatial: inout SpatialModel,
            layout: KeyLayout) -> Bool {
            let n = layout.keys.count
            guard cal.biasX.count >= n, cal.biasY.count >= n,
                  sigma.x.count >= n, sigma.y.count >= n else { return false }
            for i in 0..<n {
                spatial.setCalibration(.init(biasX: cal.biasX[i],
                                             biasY: cal.biasY[i],
                                             sigmaX: sigma.x[i],
                                             sigmaY: sigma.y[i]), at: i)
            }
            return true
        }

        /// Paketler **henüz yüklenmeden** yazılan anlık görüntü.
        ///
        /// Deneme başlar başlamaz diske düşmek zorunda (§12.6) ama motor o anda
        /// kurulu değil. Yer tutucu bir konfigürasyon uydurmak yerine
        /// `.unknown` yazılıyor; `engineConfigured` frame'i geldiğinde üzerine
        /// yazılıyor.
        ///
        /// ## Neden varsayılanı yok
        ///
        /// Önce hepsi varsayılanlıydı ve varsayılanlar `.unknown`'du. Sonuç: bir
        /// çağıran parametreleri geçmeyi atlarsa **native** bir kayıt bilinmeyen
        /// derleme ve bilinmeyen politikayla diske düşüyordu — ve bunu ancak
        /// validator, kaydı okurken "bozuk" diye raporlayınca görüyorduk. Oysa
        /// bu olgular deneme başlamadan biliniyor; bilinmemeleri için meşru bir
        /// durum yok. Derleyicinin sorması, okuyucunun şikâyet etmesinden iyi.
        public static func unconfigured(
            buildConfiguration: String,
            appVersion: String,
            build: BuildManifest,
            policy: PolicyRecord) -> EngineSnapshot {
            .init(buildConfiguration: buildConfiguration, appVersion: appVersion,
                  build: build, policy: policy, configuration: .unknown)
        }

        public init(buildConfiguration: String, appVersion: String,
                    build: BuildManifest, policy: PolicyRecord,
                    configuration: Epistemic<Configuration>) {
            self.buildConfiguration = buildConfiguration
            self.appVersion = appVersion
            self.build = build
            self.policy = policy
            self.configuration = configuration
        }
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
