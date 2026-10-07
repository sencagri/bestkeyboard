import Foundation
import KBRuntime

// MARK: - Kaydedicinin tipleri

extension RecordingEngine {

    /// Deneme durum makinesi.
    ///
    /// Terminal durumlar **değişmez**. Kurtarma yalnız `recording →
    /// interrupted`: tamamlanmış bir denemeyi sonradan kesintiye çevirmek,
    /// geçmişe dönük olarak veriyi yeniden yorumlamak olurdu.
    public enum Phase: String, Equatable, Sendable {
        case initializing
        /// Deneme diske düştü ama paketler henüz yüklenmedi.
        ///
        /// Ayrı bir faz olmak zorunda: bu aralıkta gelen bir komut, motoru
        /// kurulmadan sürerdi ve kayıt hangi konfigürasyonla üretildiğini
        /// söyleyemezdi.
        case awaitingConfiguration
        case recording, finishing
        case completed, aborted, invalid, interrupted
        /// Üretimden saklanan dilim.
        case captured

        public var isTerminal: Bool {
            switch self {
            case .initializing, .awaitingConfiguration, .recording, .finishing:
                return false
            case .completed, .aborted, .invalid, .interrupted, .captured:
                return true
            }
        }

        /// Kaydın durumu → kaydedicinin fazı — **açık** eşleme.
        ///
        /// Önce `Phase(rawValue: reason.rawValue) ?? .invalid` ile köprüleniyordu:
        /// iki enum'dan birine bir durum eklenip diğerine eklenmeseydi köprü
        /// sessizce `.invalid`'e düşerdi. Eşleme total olunca derleyici sorar.
        init(_ status: CanonicalSession.Status) {
            switch status {
            case .recording:   self = .recording
            case .completed:   self = .completed
            case .aborted:     self = .aborted
            case .interrupted: self = .interrupted
            case .invalid:     self = .invalid
            case .captured:    self = .captured
            }
        }
    }

    public enum TerminalReason: String, Sendable {
        case completed, aborted, invalid, interrupted
        /// Üretimde yazarken saklanan dilim — hedef yok, tamamlanma ölçülmez.
        case captured

        /// Çağıranın **iddia ettiği** durum. `completed` iddiası doğrulamadan
        /// geçiyor (`resolve`); diğerleri olduğu gibi.
        var claimedStatus: CanonicalSession.Status {
            switch self {
            case .completed:   return .completed
            case .aborted:     return .aborted
            case .invalid:     return .invalid
            case .interrupted: return .interrupted
            case .captured:    return .captured
            }
        }
    }

    public enum IngressError: Error, Equatable, CustomStringConvertible {
        case wrongPhase(expected: [Phase], actual: Phase)
        /// Motor iki kez yapılandırıldı.
        ///
        /// İkinci kurulum, önceki eylemlerin **başka** bir motorla üretildiği
        /// anlamına gelir; kayıt tek bir konfigürasyon iddia ederken iki
        /// tanesiyle koşmuş olurdu.
        case alreadyConfigured
        /// Harf komutu, zaten tüketilmiş bir dokunmaya bağlanmaya çalıştı.
        case touchAlreadyConsumed(Int)
        /// Harf komutunun dokunması hiç kaydedilmemiş.
        case unknownTouch(Int)
        /// Harf komutu dokunma taşımıyor.
        case letterWithoutTouch
        case writeFailed(String)
        /// `attemptStarted` politikayı bilmiyor.
        ///
        /// Native bir kayıt politikasını **bilmek zorunda**: §12.3 normatif
        /// koşulu tanımlıyor ve motor onu uyguluyor. Bilinmiyorsa hangi
        /// klavyenin ölçüldüğü söylenemez — deneme hiç başlamasın.
        case policyUnknown(String)
        /// Dokunma zamanı denemenin saatiyle aynı tabanda değil.
        ///
        /// `UITouch.timestamp` sistem açılışına göre, `CFAbsoluteTimeGetCurrent`
        /// duvar saatine göre. İkisini aynı alanda karıştırmak kaydın zaman
        /// çizgisini çöpe çeviriyordu (gerçek bir cihaz kaydında harf
        /// action'larının `t`'si −806 576 468 ölçüldü) ve **hiçbir şey** bunu
        /// yakalamıyordu: tek kelimelik bir kayıtta dizi kendi içinde monoton
        /// kaldığı için validator da yeşil geçiyordu.
        case clockMismatch(touchID: Int, touch: TimeInterval, start: TimeInterval)
        /// Kalibrasyon "uygulandı" deniyor ama uygulanamıyor.
        ///
        /// Kaydedip uygulamamak, kaydın kendi anlattığından başka bir motoru
        /// ölçmesi demek — ve replay onu uyguladığı için fark sahte bir kod
        /// regresyonu gibi görünürdü.
        case calibrationUnusable(String)
        /// Komut şemanın izin verdiği biçimde değil.
        ///
        /// Klavyeyi **düşürmek yerine** denemeyi reddediyor: bozuk bir kayıt
        /// kullanıcının günlük aracını çökertmemeli.
        case malformedCommand(String)

        public var description: String {
            switch self {
            case let .wrongPhase(e, a):
                return "faz \(a); beklenen \(e.map(\.rawValue).joined(separator: "|"))"
            case .alreadyConfigured:            return "motor zaten yapılandırıldı"
            case let .touchAlreadyConsumed(id): return "dokunma \(id) zaten tüketildi"
            case let .unknownTouch(id):         return "dokunma \(id) kayıtta yok"
            case .letterWithoutTouch:           return "harf komutunun dokunması yok"
            case let .writeFailed(d):           return "yazılamadı: \(d)"
            case let .policyUnknown(f):         return "politika bilinmiyor: \(f)"
            case let .calibrationUnusable(d):
                return "kalibrasyon uygulanamıyor: \(d)"
            case let .malformedCommand(d):      return "bozuk komut: \(d)"
            case let .clockMismatch(id, t, start):
                return "dokunma \(id) başka bir saatten: \(t) < deneme başlangıcı"
                    + " \(start). `UITouch.timestamp` açılışa göre,"
                    + " `CFAbsoluteTimeGetCurrent` duvar saatine göre."
            }
        }
    }

    /// Harf komutu, **tüketilmemiş terminal `touchID`** taşıyan bir zarfla
    /// gelir.
    ///
    /// "Son dokunmaya" örtük bağlanmak kimlik korunumunu zayıflatıyordu: iki
    /// parmak üst üste bindiğinde ya da bir dokunma sınır dışına çıkıp
    /// düştüğünde harf yanlış dokunmaya bağlanıyordu ve kalibrasyon o yanlış
    /// koordinatı öğreniyordu.
    public struct CommandEnvelope {
        public var command: ReplayCommand
        /// Harf komutlarında **zorunlu**; diğerlerinde `nil`.
        public var touchID: Int?
        public var timestamp: TimeInterval

        public init(command: ReplayCommand, touchID: Int? = nil,
                    timestamp: TimeInterval) {
            self.command = command
            self.touchID = touchID
            self.timestamp = timestamp
        }
    }

    struct BuildIdentity {
        let buildConfiguration: String
        let appVersion: String
        let build: CanonicalSession.EngineSnapshot.BuildManifest
    }
}
