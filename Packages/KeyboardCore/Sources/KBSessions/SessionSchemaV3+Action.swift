import Foundation
import KBRuntime

extension CanonicalSession {

    /// Token kimliği → o token'ı kapatan commit.
    ///
    /// Kimlik monoton ve tekil (validator bunu sınıyor); yine de çift kayıt
    /// olursa **ilk** commit kazanıyor — eylem sırasıyla ilk eşleşmeyi arayan
    /// eski döngülerle aynı sonuç.
    public var commitsByToken: [TokenID: Action.Commit] {
        Dictionary(actions.compactMap { a -> (TokenID, Action.Commit)? in
                       guard let c = a.commit, let id = c.tokenID.value else { return nil }
                       return (id, c)
                   },
                   uniquingKeysWith: { first, _ in first })
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
            /// Token sınırında yazılan hazır metin (`ReplayCommand.text`).
            case text
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
                case .space, .symbol, .text, .suggestionPick, .newline: return true
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

            /// Aday listesinin anlık görüntüsü bu olayda **alınıyor** mu.
            ///
            /// Görüntü olaydan **önce** alınmalı: sınır beam'i sıfırlıyor ve
            /// sonrasında liste boş çıkardı. Sembol de token kapatıyor ama
            /// (metin de) görüntü almıyor — kullanıcı noktalamayla kapatırken öneri
            /// çubuğuna bakmıyor ve kayıt harf başına liste tutmuyor. Yazıcı
            /// ile golden aynı kümeyi kullanmazsa golden kaydın hiç almadığı
            /// bir listeyi karşılaştırır.
            public var snapshotsSuggestions: Bool {
                switch self {
                case .space, .newline, .suggestionPick: return true
                default: return false
                }
            }
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
}

// MARK: - Komut ↔ kip

public extension ReplayCommand {
    /// Komutun kaydedilen **kipi** — tek eşleme.
    ///
    /// Eşleme üç yerde elle yazılıyordu: yazıcı (`RecordingEngine.apply`),
    /// validator (yük–kip uyumu) ve v2 migrasyonu. Bir komut eklendiğinde
    /// derleyici yalnız bunu sorar.
    var actionKind: CanonicalSession.Action.Kind {
        switch self {
        case .letter:          return .letter
        case .symbol:          return .symbol
        case .text:            return .text
        case .space:           return .space
        case .newline:         return .newline
        case .suggestionPick:  return .suggestionPick
        case .backspaceTap:    return .backspaceTap
        case .backspaceRepeat: return .backspaceRepeat
        case .deleteWord:      return .deleteWord
        case .planeChange:     return .planeChange
        case .shift:           return .shift
        }
    }
}
