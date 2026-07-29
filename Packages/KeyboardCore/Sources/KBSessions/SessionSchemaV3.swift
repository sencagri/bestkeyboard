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

    /// Motor anlık görüntüsü — **kurulmamış olabilir**.
    ///
    /// v2 yazıcısı oturum başında, paketler yüklenmeden bir yer tutucu
    /// (`beamWidth: 0`, `packs: []`) diske yazıyor ve yükleme bitince üzerine
    /// yazıyor. Deneme yükleme bitmeden yarıda kalırsa kayıtta yer tutucu
    /// kalıyor. Onu gerçek konfigürasyon diye taşımak, `beamWidth`'i sıfır olan
    /// bir motoru olgu gibi kaydetmek olurdu.
    public var engine: Epistemic<EngineSnapshot>
    public var geometry: Geometry

    // MARK: Akış

    public var touches: [Touch]
    public var actions: [Action]
    /// Yalnız terminalde yazılır; ara metin `document`'tan türetilir.
    public var finalText: String

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

    // MARK: - Dokunma

    public struct Touch: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            case began, moved, ended, cancelled
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
        public var shown: Epistemic<[ShownSuggestion]>

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
                    shown: Epistemic<[ShownSuggestion]>,
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
        public var packs: [PackRef]
        public var policy: PolicyRecord

        public var beamWidth: Int
        public var oovTheta: Double
        public var suggestionWindow: Double
        public var autoCorrectsOutOfVocabulary: Bool
        /// Skor modelinin **tamamı** — replay bunsuz kurulamaz. v2 taşımıyordu.
        ///
        /// Eksikliği `-1`/`[:]` nöbetçileriyle yazmak, `Epistemic`'in var oluş
        /// sebebi olan hatanın aynısı olurdu: bilinmeyeni yasal görünen bir
        /// değere çevirmek. `[:]` ağırlık, "ağırlıklar sıfır" diye de okunabilir.
        public var scoring: Epistemic<ScoringConfig>
        public var calibration: CalibrationSnapshot
        /// Oturum başındaki dil durumu — `remember(language:)` sonraki
        /// token'ların maliyetini etkiliyor.
        public var initialLanguage: Int?

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
            public var learning: Epistemic<RecordingPolicy.Learning>

            public init(feedbackVisible: Epistemic<Bool>,
                        suggestionsVisible: Epistemic<Bool>,
                        correction: Epistemic<RecordingPolicy.Correction>,
                        learning: Epistemic<RecordingPolicy.Learning>) {
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
                          learning: .known(p.learning))
            }
        }

        /// Skor modelini birebir kurmak için gereken her şey.
        ///
        /// **İki ayrı `ScoreWeights` var**: decoder'ınki ve literal kanalınınki.
        /// Tek sözlük yazmak, ikisinin ayrıştığı bir kaydı birmiş gibi
        /// gösterirdi — `PackLoader` bugün onları eşitliyor ama bu bir çalışma
        /// anı davranışı, şema değişmezi değil.
        public struct ScoringConfig: Codable, Equatable, Sendable {
            public var decoderWeights: [String: Double]
            public var literalChannelWeights: [String: Double]
            /// Sözlük dışı karakter maliyeti — kanal kalibre değilse yedek.
            public var cUnk: Double
            /// Uzamsal modelin alt sınırı.
            public var sigmaMin: Double
            public var languagePrior: [String: Double]
            /// Oturum başındaki `languageModel.previous` — dil geçiş cezası
            /// buna bakıyor.
            public var languagePrevious: Int?

            public init(decoderWeights: [String: Double],
                        literalChannelWeights: [String: Double],
                        cUnk: Double, sigmaMin: Double,
                        languagePrior: [String: Double],
                        languagePrevious: Int?) {
                self.decoderWeights = decoderWeights
                self.literalChannelWeights = literalChannelWeights
                self.cUnk = cUnk
                self.sigmaMin = sigmaMin
                self.languagePrior = languagePrior
                self.languagePrevious = languagePrevious
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
                    case dirty(digest: String)
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
                public var role: String
                public var language: Int
                /// `LexiconSet.sources` içindeki sıra; sözlük kaynağı olmayan
                /// paketlerde (karakter modeli, genişletme) `nil`.
                public var sourceOrder: Int?
                /// Kaynak maliyet ofseti; yalnız sözlük kaynaklarında anlamlı.
                public var offset: Double?
                public init(role: String, language: Int, sourceOrder: Int?,
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

        public init(buildConfiguration: String, appVersion: String,
                    build: BuildManifest, packs: [PackRef],
                    policy: PolicyRecord, beamWidth: Int,
                    oovTheta: Double, suggestionWindow: Double,
                    autoCorrectsOutOfVocabulary: Bool,
                    scoring: Epistemic<ScoringConfig>,
                    calibration: CalibrationSnapshot, initialLanguage: Int?) {
            self.buildConfiguration = buildConfiguration
            self.appVersion = appVersion
            self.build = build; self.packs = packs; self.policy = policy
            self.beamWidth = beamWidth; self.oovTheta = oovTheta
            self.suggestionWindow = suggestionWindow
            self.autoCorrectsOutOfVocabulary = autoCorrectsOutOfVocabulary
            self.scoring = scoring
            self.calibration = calibration
            self.initialLanguage = initialLanguage
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
                engine: Epistemic<EngineSnapshot>, geometry: Geometry,
                touches: [Touch] = [], actions: [Action] = [],
                finalText: String = "",
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
        self.engine = engine; self.geometry = geometry
        self.touches = touches; self.actions = actions
        self.finalText = finalText
        self.legacy = legacy
    }
}
