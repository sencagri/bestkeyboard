import Foundation

/// Cihazda toplanan gerçek yazım kaydı — sözleşme §12.
///
/// ## Neden var
///
/// §8.3, §8.5 ve §8.6'daki kalibrasyon ve ağırlık ölçümlerinin **tamamı
/// sentetik** ve her biri *"gerçek kabul kapısı gerçek dokunma verisiyle
/// kurulacak"* diyor. Bu tip o veriyi taşıyor.
///
/// §12.1 iki somut iş tanımlıyor:
///
/// 1. **Karar teşhisi** — klavye hangi kararı neden verdi.
/// 2. **Tekrarlanabilir test** — bir kez kaydedilen yazım, sonraki her
///    değişikliğe karşı yeniden oynatılır ve fark ölçülür.
///
/// İkincisi şemanın en sert kısıtını doğuruyor: kayıt, decode'u **birebir
/// yeniden üretebilecek** kadar eksiksiz olmalı. Motor durumu ve decoder'a
/// fiilen verilen dokunma noktası kayda girmezse replay farkı "değişiklik mi,
/// ortam mı" ayırt edilemez.
///
/// ## Değişmezlik
///
/// `actions` **append-only**'dir ve token görünümü buradan türetilmez — Mac
/// tarafındaki importer türetir. Sebep somut: boşluğu silmek önceki kelimeyi
/// dokunmalarıyla birlikte geri açabiliyor (`ComposingSession`), yani ilk
/// commit kaydı artık nihai token değildir. Cihazda token listesi tutmak
/// yanlış sayım üretirdi (§12.6).
public struct TypingSession: Codable {

    /// Şema sürümü. Alan eklenirse artar; importer eski sürümü tanımalı.
    public var schema = 2

    // MARK: - Kimlik ve protokol

    public var attemptID: String
    /// Anonim ama **kararlı** katılımcı kimliği. Kullanıcı dağılımı ancak
    /// birden çok katılımcıyla kurulabilir (§12.8); tek kişide bile alan
    /// bulunmalı ki sonradan birleştirme mümkün olsun.
    public var participantID: String
    public var protocolVersion = 1
    /// Bu oturumun kaçıncı olduğu — oturum-ayrık split için gerekli.
    public var sessionOrdinal: Int

    /// §12.3'ün iki koşulu. Karıştırılmamaları için kayda yazılıyor.
    public enum Condition: String, Codable {
        /// Yazılan metin ve öneriler **gizli**, düzeltme uygulanmıyor, model
        /// donmuş. Uzamsal dağılım ve kalibrasyon için.
        case calibrationReplay
        /// Gerçek klavye davranışı: öneri çubuğu dokunulabilir, düzeltme
        /// uygulanıyor. Karar davranışı için.
        case behavior
    }
    public var condition: Condition

    /// §12.6: **vazgeçilen deneme de kaydedilir.** Yalnız tamamlananları
    /// saklamak seçim yanlılığıdır — kullanıcı kötü denemeleri atıp iyileri
    /// saklarsa abort oranı görünmez olur.
    public enum Status: String, Codable {
        case inProgress, completed, aborted, interrupted, invalid
    }
    public var status: Status = .inProgress

    // MARK: - Hedef

    public var promptID: String
    public var promptText: String
    public enum PromptSource: String, Codable { case builtin, manual }
    public var promptSource: PromptSource
    /// Manifestte **veri görülmeden önce** sabitlenmiş split (§12.8).
    public var split: String

    /// §12.4: hizalama çıkarılmaz, kurgulanır.
    public enum AlignmentSource: String, Codable {
        /// Hedef kelime kelime gösterildi; hangi dokunmanın hangi kelimeye ait
        /// olduğu bir çıkarım değil, UI durumunun kaydı.
        case constructed
        /// Cümlenin tamamı görünüyordu; sıraya dayalı, **daha zayıf**.
        case sequential
        case none
    }
    public var alignmentSource: AlignmentSource

    // MARK: - Koşullar

    public var startedAt: Date
    public var endedAt: Date?

    /// El duruşu ve hareket — dokunma sapmasının baskın belirleyicileri ve
    /// oturumlar arasında değişirler. Bilinmiyorsa `unknown`.
    public struct Posture: Codable {
        public enum Hands: String, Codable { case oneThumb, twoThumbs, indexFinger, unknown }
        public enum Mobility: String, Codable { case seated, standing, walking, unknown }
        public var hands: Hands = .unknown
        public var mobility: Mobility = .unknown
        public init(hands: Hands = .unknown, mobility: Mobility = .unknown) {
            self.hands = hands; self.mobility = mobility
        }
    }
    public var posture = Posture()

    // MARK: - Motor durumu (§12.7)

    /// Replay'in birebir olabilmesi için gereken her şey.
    ///
    /// `appVersion` **yetmez**: aynı binary farklı paketle koşabilir. Paket
    /// hash'leri ve ağırlıklar olmadan replay farkı "değişiklik mi, ortam mı"
    /// ayırt edilemez.
    public struct EngineSnapshot: Codable {
        public var buildConfiguration: String
        public var appVersion: String
        public var packs: [PackRef]
        public var beamWidth: Int
        public var oovTheta: Double
        public var suggestionWindow: Double
        public var autoCorrectsOutOfVocabulary: Bool
        /// Uygulanan kalibrasyon — **donmuş** olduğu için tek anlık görüntü yeter.
        public var calibration: CalibrationSnapshot
        /// Kayıt boyunca öğrenme kapalı mıydı. §12.3 bunu şart koşuyor:
        /// açık olsaydı ölçülecek şey ölçüm setinin içine gömülürdü.
        public var learningFrozen: Bool
        /// Kaydı üreten kodun sürümü — `appVersion` yetmez, aynı sürüm farklı
        /// commit'lerle derlenebilir. §12.7 bunu açıkça istiyor.
        public var codeRevision: String
        /// Oturum başındaki dil durumu.
        ///
        /// `remember(language:)` her commit'te `languageModel.previous`'ı
        /// değiştiriyor ve **sonraki** token'ların maliyetini etkiliyor. Replay
        /// bunu kurmadan başlarsa ikinci kelimeden itibaren fark çıkar ve o fark
        /// "kod mu değişti, ortam mı" diye yorumlanamaz (§12.1).
        public var initialLanguage: Int?

        public struct PackRef: Codable {
            public var name: String
            public var sha256: String
            public var bytes: Int
            public init(name: String, sha256: String, bytes: Int) {
                self.name = name; self.sha256 = sha256; self.bytes = bytes
            }
        }

        public struct CalibrationSnapshot: Codable {
            public var applied: Bool
            public var strongSamples: Int
            public var globalX: Double
            public var globalY: Double
            public var rowX: [Double]
            public var rowY: [Double]
            public var keyX: [Double]
            public var keyY: [Double]
            public var biasX: [Double]
            public var biasY: [Double]
            public init(applied: Bool, strongSamples: Int,
                        globalX: Double, globalY: Double,
                        rowX: [Double], rowY: [Double],
                        keyX: [Double], keyY: [Double],
                        biasX: [Double], biasY: [Double]) {
                self.applied = applied; self.strongSamples = strongSamples
                self.globalX = globalX; self.globalY = globalY
                self.rowX = rowX; self.rowY = rowY
                self.keyX = keyX; self.keyY = keyY
                self.biasX = biasX; self.biasY = biasY
            }
        }

        public init(buildConfiguration: String, appVersion: String,
                    packs: [PackRef], beamWidth: Int, oovTheta: Double,
                    suggestionWindow: Double, autoCorrectsOutOfVocabulary: Bool,
                    calibration: CalibrationSnapshot, learningFrozen: Bool,
                    codeRevision: String, initialLanguage: Int?) {
            self.buildConfiguration = buildConfiguration
            self.appVersion = appVersion
            self.packs = packs
            self.beamWidth = beamWidth
            self.oovTheta = oovTheta
            self.suggestionWindow = suggestionWindow
            self.autoCorrectsOutOfVocabulary = autoCorrectsOutOfVocabulary
            self.calibration = calibration
            self.learningFrozen = learningFrozen
            self.codeRevision = codeRevision
            self.initialLanguage = initialLanguage
        }
    }
    public var engine: EngineSnapshot

    // MARK: - Geometri (§12.7)

    /// Yalnız `viewSize` ham → normalize dönüşümünü **kanıtlamaz**:
    /// normalizasyon `bounds.minX/minY`'yi de çıkarıyor ve `CGPoint` piksel
    /// değil nokta cinsindendir.
    public struct Geometry: Codable {
        public var layoutID: String
        public var boundsX: Double, boundsY: Double
        public var boundsWidth: Double, boundsHeight: Double
        public var frameInScreenX: Double, frameInScreenY: Double
        public var frameInScreenWidth: Double, frameInScreenHeight: Double
        public var safeAreaBottom: Double
        public var screenScale: Double
        public var interfaceOrientation: String
        public var deviceModel: String
        public var systemVersion: String
        public init(layoutID: String, boundsX: Double, boundsY: Double,
                    boundsWidth: Double, boundsHeight: Double,
                    frameInScreenX: Double, frameInScreenY: Double,
                    frameInScreenWidth: Double, frameInScreenHeight: Double,
                    safeAreaBottom: Double, screenScale: Double,
                    interfaceOrientation: String, deviceModel: String,
                    systemVersion: String) {
            self.layoutID = layoutID
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
    public var geometry: Geometry

    // MARK: - Ham dokunmalar (§12.7)

    /// Bir dokunmanın tam yaşam döngüsü.
    ///
    /// `decoderSample` ayrı tutuluyor: ham noktayla aynı olmayabilir ve
    /// replay'in birebir eşleşmesi için decoder'ın **gördüğü** değer gerekiyor.
    public struct Touch: Codable {
        public var touchID: Int
        public var phase: String
        public var outcome: String
        public var rawX: Double, rawY: Double
        public var normX: Double?, normY: Double?
        /// Decoder'a fiilen verilen nokta — yalnız kesinleşen harflerde dolu.
        public var decoderX: Double?, decoderY: Double?
        public var timestamp: TimeInterval
        public var majorRadius: Double
        public var majorRadiusTolerance: Double
        public var plane: String
        public var shift: String
        public var hitKind: String?
        public var key: String?
        public var keyIndex: Int?
        public init(touchID: Int, phase: String, outcome: String,
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
    public var touches: [Touch] = []

    // MARK: - Olay günlüğü (§12.6 — append-only)

    public struct Action: Codable {
        public var actionID: Int
        /// Oturum başından saniye.
        public var t: TimeInterval
        public var kind: String
        /// Bu eylemi doğuran dokunma; yoksa `nil` (ör. otomatik olaylar).
        public var touchID: Int?
        /// `calibrationReplay`'de hangi hedef kelimedeydik — hizalama kaydı.
        public var targetWordIndex: Int?
        public var targetWord: String?
        /// Eylemden **sonra** alınan aday anlık görüntüsü (§12.7 sıra kuralı).
        public var suggestions: [Suggestion]?
        public var commit: Commit?
        /// Belgede eylemden sonra duran metin — replay doğrulaması için.
        public var textAfter: String?
        /// §12.4'ün şart koştuğu **sapma bayrağı**.
        ///
        /// Hizalama `constructed` olsa bile kenar durumlar onu delebiliyor:
        /// sınırda geri silme önceki kelimeyi geri açar, noktalama token'ı
        /// boşluksuz kapatır, çift boşluk hedef kelimeyi atlar. Bu bayrak
        /// olmadan analiz, delinmiş bir hizalamayı sağlam sanır.
        public var alignmentDiverged: Bool = false

        public init(actionID: Int, t: TimeInterval, kind: String, touchID: Int?,
                    targetWordIndex: Int?, targetWord: String?,
                    suggestions: [Suggestion]?, commit: Commit?,
                    textAfter: String?, alignmentDiverged: Bool = false) {
            self.actionID = actionID; self.t = t; self.kind = kind
            self.touchID = touchID
            self.targetWordIndex = targetWordIndex; self.targetWord = targetWord
            self.suggestions = suggestions; self.commit = commit
            self.textAfter = textAfter; self.alignmentDiverged = alignmentDiverged
        }

        public struct Suggestion: Codable {
            public var word: String
            public var cost: Double
            public var source: Int
            public var language: Int
            /// Kullanıcıya **fiilen gösterildi** mi.
            ///
            /// `calibrationReplay`'de öneri çubuğu gizli olduğu için bu daima
            /// `false` olmalı — pencere içindeki adayı "gösterildi" yazmak,
            /// "kullanıcı öneriyi görüp görmezden geldi" analizini yanıltır.
            public var shown: Bool
            public init(word: String, cost: Double, source: Int,
                        language: Int, shown: Bool) {
                self.word = word; self.cost = cost; self.source = source
                self.language = language; self.shown = shown
            }
        }

        public struct Commit: Codable {
            public var kind: String
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
            /// `θ` sonsuzdu — literal korundu (koruma kuralı ya da
            /// `fieldProtectsLiteral`). JSON sonsuz taşıyamadığı için `theta`
            /// `nil` kalır; "ölçülmedi" ile "korundu" karışmasın diye ayrı alan.
            public var literalProtected: Bool
            /// §12.5: hedefli kayıtta niyet **protokolden** bilinir; üretimin
            /// `.weak` kuralı burada geçerli değil.
            public var labelSource: String
            public var confidence: String
            /// Bu token hangi hedef kelimeye karşılık geliyordu.
            public var targetWord: String?
            public var matchesTarget: Bool?
            public init(kind: String, literal: String, displayBefore: String,
                        committed: String, delta: Double?, theta: Double?,
                        bestCost: Double?, bestWord: String?, language: Int?,
                        touchCount: Int, casingApplied: Bool,
                        literalProtected: Bool, labelSource: String,
                        confidence: String, targetWord: String?,
                        matchesTarget: Bool?) {
                self.kind = kind; self.literal = literal
                self.displayBefore = displayBefore; self.committed = committed
                self.delta = delta; self.theta = theta
                self.bestCost = bestCost; self.bestWord = bestWord
                self.language = language; self.touchCount = touchCount
                self.casingApplied = casingApplied
                self.literalProtected = literalProtected
                self.labelSource = labelSource; self.confidence = confidence
                self.targetWord = targetWord; self.matchesTarget = matchesTarget
            }
        }
    }
    public var actions: [Action] = []

    public var finalText: String = ""

    /// Kullanıcı geri silip önceki token'ı yeniden açtı mı — importer'ın
    /// türetme yaparken bilmesi gereken bayrak.
    public var hadBackspace = false

    // Swift `public struct` için sentezlediği memberwise init'i `internal`
    // bırakıyor; yazıcı ayrı modülde olduğu için init'ler açıkça public.
    public init(attemptID: String, participantID: String, sessionOrdinal: Int,
                condition: Condition, promptID: String, promptText: String,
                promptSource: PromptSource, split: String,
                alignmentSource: AlignmentSource, startedAt: Date,
                posture: Posture, engine: EngineSnapshot, geometry: Geometry) {
        self.attemptID = attemptID
        self.participantID = participantID
        self.sessionOrdinal = sessionOrdinal
        self.condition = condition
        self.promptID = promptID
        self.promptText = promptText
        self.promptSource = promptSource
        self.split = split
        self.alignmentSource = alignmentSource
        self.startedAt = startedAt
        self.posture = posture
        self.engine = engine
        self.geometry = geometry
    }
}

// MARK: - Depo

/// Oturum dosyalarının kalıcı deposu.
///
/// ## Neden `Application Support`, `Documents` değil
///
/// Ham dokunma koordinatı bu depoda zaten kişisel veri kabul ediliyor
/// (`CalibrationStore` yedeği dışlıyor ve file protection uyguluyor) ve **elle
/// girilen hedef metin daha da hassas olabilir**. `Documents` kullanıcıya ve
/// yedeğe açıktır; §12.9 bu yüzden `Application Support` diyor.
///
/// ## Neden oturum başına bir dosya
///
/// Kısmi bozulma diğer oturumları etkilemesin ve çekme sırasında yarım
/// yazılmış dosya görülmesin diye. Yazma atomik: geçici dosya + rename —
/// `CalibrationStore`'daki desenin aynısı.
public enum SessionStore {

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("typing-sessions", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Yazar. **Deneme başlar başlamaz** da çağrılır (§12.6): vazgeçilen
    /// deneme de kayda geçmeli, yoksa abort oranı görünmez olur.
    public static func save(_ session: TypingSession) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        let target = url(for: session.attemptID)
        let tmp = directory.appendingPathComponent(".\(session.attemptID).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
        try protect(target)
    }

    /// Yarım kalmış denemeleri `interrupted` olarak işaretler.
    ///
    /// Uygulama öldürülürse dosya sonsuza dek `inProgress` kalır ve abort
    /// oranının paydasını bulandırır — hangi denemenin gerçekten yarım
    /// bırakıldığı ile hangisinin çöktüğü ayrılmalı (§12.6).
    public static func markStaleAsInterrupted() {
        for var s in load() where s.status == .inProgress {
            s.status = .interrupted
            s.endedAt = s.endedAt ?? Date()
            try? save(s)
        }
    }

    public static func load() -> [TypingSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TypingSession.self,
                                              from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public static func delete(_ id: String) throws {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    public static func deleteAll() throws {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for u in items { try FileManager.default.removeItem(at: u) }
    }

    private static func protect(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }
}
