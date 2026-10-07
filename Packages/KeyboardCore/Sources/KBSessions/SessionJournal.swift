import Foundation
import KBGeometry
import KBRuntime

/// Append-only kayıt konteyneri — plan v8 §2.7.
///
/// ## Neden JSON dosyası yetmiyor
///
/// v2 her tuşta **tam JSON'u** yeniden yazıyordu. İki sorun: yazma maliyeti
/// deneme uzunluğuyla karesel büyüyor, ve güç kaybı yarım yazılmış bir dosya
/// bırakıyor — üstelik `attemptStarted` de kaybolduğu için deneme abort
/// oranının **paydasından tamamen düşüyor**. §12.6'nın *"başlar başlamaz diske
/// düşer"* şartı böyle bozuluyordu.
///
/// ## Konteyner
///
/// ```
/// magic("BKJ1") | containerVersion(u16) | schema(u16)
/// frame*  =  type(u8) | length(u32) | ~length(u32) | crc32(u32) | payload
/// ```
///
/// **`~length` neden var:** uzunluk alanı yük checksum'ının kapsamında değil ve
/// olamaz — checksum'ı doğrulamak için önce yükü okumak, yükü okumak için de
/// uzunluğu bilmek gerekiyor. Ortadaki bir frame'in uzunluğu dosyadan büyük bir
/// değere bozulursa okuyucu "yük eksik" görüp bunu **yarım son frame** sayıyor
/// ve arkasındaki sağlam frame'leri sessizce atıyordu. Tümleyen, uzunluğu
/// okumadan **önce** doğrulanabilen tek şey.
///
/// `containerVersion` şemadan **ayrı**: konteyner biçimi (çerçeveleme,
/// checksum) ile içerik şeması bağımsız evrilir. Tek bir sürüm numarası
/// olsaydı çerçevelemeye dokunmayan bir şema değişikliği eski dosyaları
/// okunamaz yapardı.
public enum SessionJournal {

    public static let magic = Data("BKJ1".utf8)
    /// Konteyner biçimi sürümü.
    ///
    /// 2: frame başlığına uzunluk tümleyeni eklendi (bozuk uzunluk artık yarım
    /// kuyruk sanılmıyor). Şemadan **ayrı** olmasının sebebi tam da bu:
    /// çerçeveleme değişti, içerik şeması değişmedi.
    public static let containerVersion: UInt16 = 2

    /// Frame türleri — **sıra anlamlı**.
    public enum FrameType: UInt8, Sendable, CaseIterable {
        /// Denemenin kimliği ve koşulları. **İlk** frame ve fsync'li.
        case attemptStarted = 1
        /// Motor kurulduğunda yazılır; paketler yüklenmeden önce bilinmiyor.
        case engineConfigured = 2
        case touch = 3
        case action = 4
        /// Nihai durum. **Son** frame; sonrasına ekleme reddedilir.
        case terminal = 5
    }

    /// Terminal frame'in yükü — **tek** tanım.
    ///
    /// Önce yazıcıda `Encodable` bir `Terminal`, okuyucuda `Decodable` bir
    /// `TerminalFrame` vardı. İki ayrı bildirim aynı olguyu tarif ediyordu ve
    /// hiçbir şey eşleşmelerini zorlamıyordu: yazıcıya bir alan eklenince
    /// okuyucu onu sessizce yok sayıyor, okuyucuya eklenince her eski kayıt
    /// "çözülemedi" oluyordu. Kurtarma yolunun **üçüncü** bir kopya üretmesi bu
    /// riski üçe çıkarırdı.
    public struct Terminal: Codable, Equatable, Sendable {
        /// `CanonicalSession.Status`'un ham değeri.
        ///
        /// Tipin kendisi değil: tanınmayan bir değer "eski kayıt" değil **bozuk**
        /// kayıttır ve okuyucu bunu kendi hatasıyla raporlamak zorunda
        /// (`Status` olarak decode etmek onu "çözülemedi"ye çevirirdi).
        public var reason: String
        /// `startedAt`'tan itibaren saniye.
        public var at: TimeInterval
        public var finalText: String
        /// Katlanmış durumun özeti — okuyucu bunu **çapraz doğruluyor**.
        public var cursor: Int
        /// Hedef dizisinin uzunluğu; bilinmiyorsa `-1`.
        public var promptTokenCount: Int
        public var violations: [String]
        public var unverifiable: [Int]
        /// Kullanıcının denemeden **sonra** yazdığı not.
        ///
        /// Gözlenmiş olgu değil, **anlatı**: "ne yazmak istedim, ne oldu".
        /// Şemanın geri kalanı klavyenin ürettiği ölçümler; bu, ölçümün
        /// açıklayamadığı şeyi taşıyan tek alan ve o yüzden ayrı durması
        /// gerekiyor — bir gün analizde kullanılırsa kaynağının insan olduğu
        /// görünmeli.
        ///
        /// Terminal yükünde: kullanıcı onu denemeyi kapatırken yazıyor ve
        /// append-only günlükte terminalden **sonra** frame olamaz.
        public var note: String?
        /// Deneme başlarken belge boş muydu — belge zincirinin dışarıdan
        /// doğrulanabilir olup olmadığı buna bağlı.
        public var documentBaselineKnown: Bool?

        public init(reason: String, at: TimeInterval, finalText: String,
                    cursor: Int, promptTokenCount: Int,
                    violations: [String], unverifiable: [Int],
                    note: String? = nil,
                    documentBaselineKnown: Bool? = nil) {
            self.reason = reason; self.at = at; self.finalText = finalText
            self.cursor = cursor; self.promptTokenCount = promptTokenCount
            self.violations = violations; self.unverifiable = unverifiable
            self.note = note
            self.documentBaselineKnown = documentBaselineKnown
        }
    }

    public struct Frame: Equatable, Sendable {
        public let type: FrameType
        public let payload: Data
        public init(type: FrameType, payload: Data) {
            self.type = type; self.payload = payload
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case notAJournal
        case unsupportedContainer(UInt16)
        /// Ortada bozuk frame — kurtarılamaz.
        case corruptFrame(index: Int, detail: String)
        case emptyJournal
        /// Başlık, okuyucunun bilmediği bir şema iddia ediyor.
        case unsupportedSchema(UInt16)

        public var description: String {
            switch self {
            case .notAJournal:               return "günlük dosyası değil"
            case let .unsupportedContainer(v): return "desteklenmeyen konteyner: \(v)"
            case let .corruptFrame(i, d):    return "\(i). frame bozuk: \(d)"
            case .emptyJournal:              return "hiç frame yok"
            case let .unsupportedSchema(v):  return "desteklenmeyen şema: \(v)"
            }
        }
    }

    public struct Loaded: Equatable, Sendable {
        public var frames: [Frame]
        /// Son frame yarım yazılmıştı ve **atıldı**.
        ///
        /// Ayrı bir olgu olarak dönüyor: sessizce kırpmak, güç kaybında
        /// kaybolan bir action'ı hiç olmamış gibi gösterirdi.
        public var truncatedTail: Bool
    }

    // MARK: - Yazma

    public static func header(schema: UInt16 = UInt16(CanonicalSession.currentSchema))
        -> Data {
        var w = ByteWriter()
        w.append(contentsOf: magic)
        w.u16(containerVersion)
        w.u16(schema)
        return w.data
    }

    public static func encode(_ frame: Frame) -> Data {
        let length = UInt32(frame.payload.count)
        var w = ByteWriter()
        w.reserveCapacity(frameHeaderSize + frame.payload.count)
        w.u8(frame.type.rawValue)
        w.u32(length)
        w.u32(~length)
        w.u32(crc32(frame.payload))
        w.append(contentsOf: frame.payload)
        return w.data
    }

    /// Frame başlığının bayt uzunluğu: tür + uzunluk + tümleyen + checksum.
    private static let frameHeaderSize = 1 + 4 + 4 + 4

    // MARK: - Okuma

    /// - Note: **Yalnız eksik son frame** kurtarılabilir. Ortadaki bozuk bir
    ///   frame yükleme hatasıdır: onu atlamak, kaydın ortasından bir olayı
    ///   sessizce silmek ve katlamayı yanlış bir sonuca götürmek olurdu.
    public static func load(_ data: Data) -> Result<Loaded, LoadError> {
        let headerSize = magic.count + 4
        guard data.count >= headerSize, data.prefix(magic.count) == magic else {
            return .failure(.notAJournal)
        }
        var i = magic.count
        let container: UInt16 = read(data, at: &i)
        guard container == containerVersion else {
            return .failure(.unsupportedContainer(container))
        }
        // **Başlıktaki şema da doğrulanıyor.**
        //
        // Önce `_`'ye okunup atılıyordu: başlık `schema: 4` derken yük v3
        // olabiliyor ve okuyucu bunu desteklenmeyen sürüm değil **geçerli bir
        // v3 kaydı** sayıyordu. Konteyner kendi içeriği hakkında bir iddiada
        // bulunuyor; iddiayı okumayıp yükten çıkarım yapmak, dosyanın kendi
        // anlattığını görmezden gelmek.
        //
        // İleri sürüm reddediliyor, geri sürüm değil: v2 yükü v3 okuyucuya
        // `SessionMigration` üzerinden giriyor ve bu meşru.
        let schema: UInt16 = read(data, at: &i)
        guard schema <= UInt16(CanonicalSession.currentSchema) else {
            return .failure(.unsupportedSchema(schema))
        }

        var frames: [Frame] = []
        var truncated = false

        while i < data.count {
            let frameStart = i
            // Başlık tam değilse: yarım yazılmış son frame.
            guard i + frameHeaderSize <= data.count else {
                truncated = true
                break
            }
            let rawType = data[data.startIndex + i]; i += 1
            let length: UInt32 = read(data, at: &i)
            let complement: UInt32 = read(data, at: &i)
            let checksum: UInt32 = read(data, at: &i)

            // Uzunluk **yükü okumadan önce** doğrulanıyor: bozuk bir uzunluk
            // "yük eksik" gibi görünüp arkasındaki sağlam frame'leri sessizce
            // attırıyordu.
            guard length == ~complement else {
                return .failure(.corruptFrame(index: frames.count,
                                              detail: "uzunluk tümleyeni tutmuyor"))
            }

            guard i + Int(length) <= data.count else {
                // Yük eksik ve uzunluk sağlam: gerçekten yarım yazılmış
                // son frame.
                truncated = true
                i = frameStart
                break
            }
            let payload = data.subdata(in: (data.startIndex + i)
                                        ..< (data.startIndex + i + Int(length)))
            i += Int(length)

            guard let type = FrameType(rawValue: rawType) else {
                // Tanınmayan tür: kaydın ortasında bilinmeyen bir olay var.
                // Atlamak, katlamayı eksik bir olay dizisiyle çalıştırmak olurdu.
                return .failure(.corruptFrame(index: frames.count,
                                              detail: "tanınmayan tür \(rawType)"))
            }
            // **Kurtarılabilir olan yalnız fiziksel eksiklik** (§7b): tam
            // uzunluktaki bir frame'de checksum hatası, son frame olsa bile,
            // load error.
            //
            // Önce son frame'deki checksum hatası da `truncatedTail` sayılıyordu
            // ve bu, veri bozulmasını normal bir güç kaybı gibi gösteriyordu:
            // tamamlanmış bir kaydın terminal yükünde tek bir bit dönerse
            // okuyucu terminali sessizce düşürüp kaydı "yarım kalmış" ilan
            // ediyor, çekme aracı "doğrulandı" diyor ve deneme `completed`
            // kovasından `recording` kovasına geçiyordu.
            //
            // Bayt sayısı **doğru** ama içerik yanlışsa "bu olay hiç yazılmadı"
            // diyemeyiz; elimizdeki tek dürüst cevap "bu dosyaya güvenilemez".
            guard crc32(payload) == checksum else {
                return .failure(.corruptFrame(index: frames.count,
                                              detail: "checksum tutmuyor"
                                                + (i == data.count
                                                   ? " (son frame; uzunluk tam,"
                                                     + " içerik bozuk)" : "")))
            }
            frames.append(Frame(type: type, payload: payload))
        }

        guard !frames.isEmpty else { return .failure(.emptyJournal) }
        return .success(Loaded(frames: frames, truncatedTail: truncated))
    }

    // MARK: - Yardımcılar

    /// Sınırı çağıranın doğruladığı little-endian okuma; imleci ilerletir.
    private static func read<T: FixedWidthInteger>(_ data: Data, at i: inout Int) -> T {
        defer { i += MemoryLayout<T>.size }
        return data.littleEndian(T.self, at: i)
    }

    /// CRC-32 (IEEE 802.3). Kriptografik değil — amaç bozulmayı yakalamak,
    /// kurcalamayı değil; kayıt zaten yalnız cihazın kendi dizininde.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
