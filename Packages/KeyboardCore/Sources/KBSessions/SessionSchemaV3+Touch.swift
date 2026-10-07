import Foundation
import KBGeometry
import KBSpatial

extension CanonicalSession {

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

        /// Decoder'a verilen nokta: `decoder*` varsa o, yoksa normalize nokta.
        ///
        /// `nil` = nokta **yok**. Harfi `(0,0)`'dan sürmek uzamsal kanıtı
        /// uydurmak olurdu; her tüketici bu durumda ne yapacağını kendisi seçer.
        ///
        /// Seçim kuralı beş yerde kopyaydı (kaydedici, golden, kalibrasyon
        /// çıkarıcısı, kalibrasyon kolları, dil önceli sondası). Biri
        /// `decoderX`'i atlayıp `normX`'e baksaydı kalibrasyon decoder'ın
        /// görmediği bir koordinatı öğrenirdi.
        public var decoderPoint: Point? {
            guard let x = decoderX ?? normX, let y = decoderY ?? normY else {
                return nil
            }
            return Point(x: x, y: y)
        }

        /// Decoder'ın gördüğü dokunma — nokta yoksa `nil`.
        public var decoderSample: TouchSample? {
            decoderPoint.map { TouchSample(down: $0, timestamp: timestamp) }
        }

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
}
