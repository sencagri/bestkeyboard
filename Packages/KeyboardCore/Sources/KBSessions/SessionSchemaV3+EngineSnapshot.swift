import Foundation
import KBRuntime

extension CanonicalSession {

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
}
