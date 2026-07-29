import Foundation
import KBRuntime

/// Yazım kaydının **kanonik** şeması — sözleşme §12, plan v8 §2.2.
///
/// v2 (`TypingSession`) yanında duruyor ve tüketiciler adım adım buraya geçecek.
/// Aynı anda iki şema tutmak bilinçli: her commit'in yeşil kalması, tek seferde
/// büyük bir geçişten daha güvenli.
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
    public var schema: Int

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
    /// Boş liste attempt başlatmaz (yalnız sembol/rakam içeren manuel hedef).
    ///
    /// v2 bunu kaydetmiyordu → `.unknown`. Bugünkü tokenizer'la yeniden
    /// üretmek, eski replay'i bugünkü koda bağlar ve tokenizer değişince
    /// geçmiş kayıtların anlamını sessizce değiştirirdi.
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

    public var engine: EngineSnapshot
    public var geometry: Geometry

    // MARK: Akış

    public var touches: [Touch]
    public var actions: [Action]
    /// Yalnız terminalde yazılır; ara metin `mutations`'tan türetilir.
    public var finalText: String

    // MARK: - Dokunma

    public struct Touch: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            case began, moved, ended, cancelled
        }
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
            /// Üçü ayrı: tap sınırda token açabilir, repeat açmaz.
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

        /// Decoder'ın ham adayları ve kullanıcıya **fiilen gösterilenler** ayrı.
        public var candidates: [CandidateSnapshot]?
        public var shown: [ShownSuggestion]?

        public var commit: Commit?

        public init(actionID: Int, t: TimeInterval, kind: Kind, touchID: Int?,
                    event: Epistemic<ReplayCommand>,
                    effect: Epistemic<DestructiveEffect>,
                    document: Epistemic<DocumentDelta>,
                    targetTokenIndex: Int?, targetToken: String?,
                    candidates: [CandidateSnapshot]?, shown: [ShownSuggestion]?,
                    commit: Commit?) {
            self.actionID = actionID; self.t = t; self.kind = kind
            self.touchID = touchID
            self.event = event; self.effect = effect
            self.document = document
            self.targetTokenIndex = targetTokenIndex; self.targetToken = targetToken
            self.candidates = candidates; self.shown = shown
            self.commit = commit
        }

        public struct Commit: Codable, Equatable, Sendable {
            public enum Kind: String, Codable, Sendable {
                case literal, autocorrect, suggestion, expansion, empty
            }
            public var kind: Kind
            public var tokenID: TokenID
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
            /// v2'de yoktu ve `targetWordIndex`'ten türetmek §6.2'nin yasakladığı
            /// çıkarım olurdu → `.unknown`, yani "bu token geri açılamaz".
            public var cursorBefore: Epistemic<Int>

            public init(kind: Kind, tokenID: TokenID, literal: String,
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
        /// v2 politikayı kaydetmiyordu. `condition`'dan türetmek **çıkarım**
        /// olurdu: koşul yalnız **niyeti** gösterir, motorun fiilen nasıl
        /// kurulduğunu değil. → migrasyonda `.unknown`, v3'te daima `.known`.
        public var policy: Epistemic<RecordingPolicy>

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

        /// Skor modelini birebir kurmak için gereken her şey — hepsi birlikte
        /// bilinir ya da birlikte bilinmez.
        public struct ScoringConfig: Codable, Equatable, Sendable {
            public var weights: [String: Double]
            /// Arama sezgiselleri: model terimi değil ama sonucu belirliyor.
            public var maxKeyCandidates: Int
            public var candidateCostWindow: Double
            public var maxConsecutiveOmissions: Int
            /// Uzamsal modelin alt sınırı.
            public var sigmaMin: Double
            public var languagePrior: [String: Double]

            public init(weights: [String: Double], maxKeyCandidates: Int,
                        candidateCostWindow: Double, maxConsecutiveOmissions: Int,
                        sigmaMin: Double, languagePrior: [String: Double]) {
                self.weights = weights
                self.maxKeyCandidates = maxKeyCandidates
                self.candidateCostWindow = candidateCostWindow
                self.maxConsecutiveOmissions = maxConsecutiveOmissions
                self.sigmaMin = sigmaMin
                self.languagePrior = languagePrior
            }
        }

        public struct BuildManifest: Codable, Equatable, Sendable {
            /// v2'nin taşıdığı **tek** derleme olgusu.
            public var codeRevision: String
            /// Gerisi v2'de yoktu. `dirty: true` varsaymak "bu kayıt kirli bir
            /// ağaçtan geldi" **iddiası** olurdu ve golden'da sahte bir
            /// açıklama üretirdi.
            public var provenance: Epistemic<Provenance>

            public struct Provenance: Codable, Equatable, Sendable {
                public var dirty: Bool
                /// Kirli ağaçta kaynak içerik özeti; temizse boş.
                public var sourceDigest: String
                public var swiftVersion: String
                public var targetTriple: String
                public var optimization: String

                public init(dirty: Bool, sourceDigest: String, swiftVersion: String,
                            targetTriple: String, optimization: String) {
                    self.dirty = dirty; self.sourceDigest = sourceDigest
                    self.swiftVersion = swiftVersion
                    self.targetTriple = targetTriple
                    self.optimization = optimization
                }
            }

            public init(codeRevision: String, provenance: Epistemic<Provenance>) {
                self.codeRevision = codeRevision
                self.provenance = provenance
            }
        }

        public struct PackRef: Codable, Equatable, Sendable {
            public var name: String
            public var sha256: String
            public var bytes: Int
            /// Ad ve hash **topolojiyi kanıtlamaz**: aynı dosya farklı rolde,
            /// farklı dilde ya da farklı kaynak sırasında yüklenebilir.
            /// v2 topolojiyi hiç taşımıyordu → `.unknown`.
            public var topology: Epistemic<Topology>

            public struct Topology: Codable, Equatable, Sendable {
                public var role: String
                public var language: Int
                public var sourceOrder: Int
                public var offset: Double
                public init(role: String, language: Int, sourceOrder: Int,
                            offset: Double) {
                    self.role = role; self.language = language
                    self.sourceOrder = sourceOrder; self.offset = offset
                }
            }

            public init(name: String, sha256: String, bytes: Int,
                        topology: Epistemic<Topology>) {
                self.name = name; self.sha256 = sha256; self.bytes = bytes
                self.topology = topology
            }
        }

        public struct CalibrationSnapshot: Codable, Equatable, Sendable {
            public var applied: Bool
            public var strongSamples: Int
            public var biasX: [Double]
            public var biasY: [Double]
            /// v2 yalnız sapmayı kaydediyordu, ölçeği değil → `.unknown`.
            /// `[]` yazmak "kalibre edilmiş σ yok" demekti; oysa vardı,
            /// kaydedilmemişti.
            public var sigma: Epistemic<Sigma>

            public struct Sigma: Codable, Equatable, Sendable {
                public var x: [Double]
                public var y: [Double]
                public init(x: [Double], y: [Double]) { self.x = x; self.y = y }
            }

            public init(applied: Bool, strongSamples: Int,
                        biasX: [Double], biasY: [Double], sigma: Epistemic<Sigma>) {
                self.applied = applied; self.strongSamples = strongSamples
                self.biasX = biasX; self.biasY = biasY
                self.sigma = sigma
            }
        }

        public init(buildConfiguration: String, appVersion: String,
                    build: BuildManifest, packs: [PackRef],
                    policy: Epistemic<RecordingPolicy>, beamWidth: Int,
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
                schema: Int = CanonicalSession.currentSchema,
                attemptID: String, participantID: String,
                protocolVersion: Int = 1, sessionOrdinal: Int,
                condition: Condition, status: Status = .recording,
                promptID: String, promptText: String, promptSource: PromptSource,
                split: String, promptTokens: Epistemic<[String]>,
                alignmentSource: AlignmentSource, startedAt: Date,
                endedAt: Date? = nil, posture: Posture = .init(),
                engine: EngineSnapshot, geometry: Geometry,
                touches: [Touch] = [], actions: [Action] = [],
                finalText: String = "") {
        self.sourceSchema = sourceSchema; self.schema = schema
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
    }
}
