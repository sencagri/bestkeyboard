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
struct TypingSession: Codable {

    /// Şema sürümü. Alan eklenirse artar; importer eski sürümü tanımalı.
    var schema = 2

    // MARK: - Kimlik ve protokol

    var attemptID: String
    /// Anonim ama **kararlı** katılımcı kimliği. Kullanıcı dağılımı ancak
    /// birden çok katılımcıyla kurulabilir (§12.8); tek kişide bile alan
    /// bulunmalı ki sonradan birleştirme mümkün olsun.
    var participantID: String
    var protocolVersion = 1
    /// Bu oturumun kaçıncı olduğu — oturum-ayrık split için gerekli.
    var sessionOrdinal: Int

    /// §12.3'ün iki koşulu. Karıştırılmamaları için kayda yazılıyor.
    enum Condition: String, Codable {
        /// Yazılan metin ve öneriler **gizli**, düzeltme uygulanmıyor, model
        /// donmuş. Uzamsal dağılım ve kalibrasyon için.
        case calibrationReplay
        /// Gerçek klavye davranışı: öneri çubuğu dokunulabilir, düzeltme
        /// uygulanıyor. Karar davranışı için.
        case behavior
    }
    var condition: Condition

    /// §12.6: **vazgeçilen deneme de kaydedilir.** Yalnız tamamlananları
    /// saklamak seçim yanlılığıdır — kullanıcı kötü denemeleri atıp iyileri
    /// saklarsa abort oranı görünmez olur.
    enum Status: String, Codable {
        case inProgress, completed, aborted, interrupted, invalid
    }
    var status: Status = .inProgress

    // MARK: - Hedef

    var promptID: String
    var promptText: String
    enum PromptSource: String, Codable { case builtin, manual }
    var promptSource: PromptSource
    /// Manifestte **veri görülmeden önce** sabitlenmiş split (§12.8).
    var split: String

    /// §12.4: hizalama çıkarılmaz, kurgulanır.
    enum AlignmentSource: String, Codable {
        /// Hedef kelime kelime gösterildi; hangi dokunmanın hangi kelimeye ait
        /// olduğu bir çıkarım değil, UI durumunun kaydı.
        case constructed
        /// Cümlenin tamamı görünüyordu; sıraya dayalı, **daha zayıf**.
        case sequential
        case none
    }
    var alignmentSource: AlignmentSource

    // MARK: - Koşullar

    var startedAt: Date
    var endedAt: Date?

    /// El duruşu ve hareket — dokunma sapmasının baskın belirleyicileri ve
    /// oturumlar arasında değişirler. Bilinmiyorsa `unknown`.
    struct Posture: Codable {
        enum Hands: String, Codable { case oneThumb, twoThumbs, indexFinger, unknown }
        enum Mobility: String, Codable { case seated, standing, walking, unknown }
        var hands: Hands = .unknown
        var mobility: Mobility = .unknown
    }
    var posture = Posture()

    // MARK: - Motor durumu (§12.7)

    /// Replay'in birebir olabilmesi için gereken her şey.
    ///
    /// `appVersion` **yetmez**: aynı binary farklı paketle koşabilir. Paket
    /// hash'leri ve ağırlıklar olmadan replay farkı "değişiklik mi, ortam mı"
    /// ayırt edilemez.
    struct EngineSnapshot: Codable {
        var buildConfiguration: String
        var appVersion: String
        var packs: [PackRef]
        var beamWidth: Int
        var oovTheta: Double
        var suggestionWindow: Double
        var autoCorrectsOutOfVocabulary: Bool
        /// Uygulanan kalibrasyon — **donmuş** olduğu için tek anlık görüntü yeter.
        var calibration: CalibrationSnapshot
        /// Kayıt boyunca öğrenme kapalı mıydı. §12.3 bunu şart koşuyor:
        /// açık olsaydı ölçülecek şey ölçüm setinin içine gömülürdü.
        var learningFrozen: Bool

        struct PackRef: Codable {
            var name: String
            var sha256: String
            var bytes: Int
        }

        struct CalibrationSnapshot: Codable {
            var applied: Bool
            var strongSamples: Int
            var globalX: Double
            var globalY: Double
            var rowX: [Double]
            var rowY: [Double]
            var keyX: [Double]
            var keyY: [Double]
            var biasX: [Double]
            var biasY: [Double]
        }
    }
    var engine: EngineSnapshot

    // MARK: - Geometri (§12.7)

    /// Yalnız `viewSize` ham → normalize dönüşümünü **kanıtlamaz**:
    /// normalizasyon `bounds.minX/minY`'yi de çıkarıyor ve `CGPoint` piksel
    /// değil nokta cinsindendir.
    struct Geometry: Codable {
        var layoutID: String
        var boundsX: Double, boundsY: Double
        var boundsWidth: Double, boundsHeight: Double
        var frameInScreenX: Double, frameInScreenY: Double
        var frameInScreenWidth: Double, frameInScreenHeight: Double
        var safeAreaBottom: Double
        var screenScale: Double
        var interfaceOrientation: String
        var deviceModel: String
        var systemVersion: String
    }
    var geometry: Geometry

    // MARK: - Ham dokunmalar (§12.7)

    /// Bir dokunmanın tam yaşam döngüsü.
    ///
    /// `decoderSample` ayrı tutuluyor: ham noktayla aynı olmayabilir ve
    /// replay'in birebir eşleşmesi için decoder'ın **gördüğü** değer gerekiyor.
    struct Touch: Codable {
        var touchID: Int
        var phase: String
        var outcome: String
        var rawX: Double, rawY: Double
        var normX: Double?, normY: Double?
        /// Decoder'a fiilen verilen nokta — yalnız kesinleşen harflerde dolu.
        var decoderX: Double?, decoderY: Double?
        var timestamp: TimeInterval
        var majorRadius: Double
        var majorRadiusTolerance: Double
        var plane: String
        var shift: String
        var hitKind: String?
        var key: String?
        var keyIndex: Int?
    }
    var touches: [Touch] = []

    // MARK: - Olay günlüğü (§12.6 — append-only)

    struct Action: Codable {
        var actionID: Int
        /// Oturum başından saniye.
        var t: TimeInterval
        var kind: String
        /// Bu eylemi doğuran dokunma; yoksa `nil` (ör. otomatik olaylar).
        var touchID: Int?
        /// `calibrationReplay`'de hangi hedef kelimedeydik — hizalama kaydı.
        var targetWordIndex: Int?
        var targetWord: String?
        /// Eylemden **sonra** alınan aday anlık görüntüsü (§12.7 sıra kuralı).
        var suggestions: [Suggestion]?
        var commit: Commit?
        /// Belgede eylemden sonra duran metin — replay doğrulaması için.
        var textAfter: String?

        struct Suggestion: Codable {
            var word: String
            var cost: Double
            var source: Int
            var language: Int
            /// Decoder'ın ham adayı mı, kullanıcıya **gösterilen** yüzey mi.
            var shown: Bool
        }

        struct Commit: Codable {
            var kind: String
            var literal: String
            var displayBefore: String
            var committed: String
            var delta: Double?
            var theta: Double?
            var bestCost: Double?
            var bestWord: String?
            var language: Int?
            var touchCount: Int
            var casingApplied: Bool
            /// `θ` sonsuzdu — literal korundu (koruma kuralı ya da
            /// `fieldProtectsLiteral`). JSON sonsuz taşıyamadığı için `theta`
            /// `nil` kalır; "ölçülmedi" ile "korundu" karışmasın diye ayrı alan.
            var literalProtected: Bool
            /// §12.5: hedefli kayıtta niyet **protokolden** bilinir; üretimin
            /// `.weak` kuralı burada geçerli değil.
            var labelSource: String
            var confidence: String
            /// Bu token hangi hedef kelimeye karşılık geliyordu.
            var targetWord: String?
            var matchesTarget: Bool?
        }
    }
    var actions: [Action] = []

    var finalText: String = ""

    /// Kullanıcı geri silip önceki token'ı yeniden açtı mı — importer'ın
    /// türetme yaparken bilmesi gereken bayrak.
    var hadBackspace = false
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
enum SessionStore {

    static var directory: URL {
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

    static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Yazar. **Deneme başlar başlamaz** da çağrılır (§12.6): vazgeçilen
    /// deneme de kayda geçmeli, yoksa abort oranı görünmez olur.
    static func save(_ session: TypingSession) throws {
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

    static func load() -> [TypingSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TypingSession.self,
                                              from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func delete(_ id: String) throws {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    static func deleteAll() throws {
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
