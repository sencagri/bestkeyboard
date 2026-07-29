import Foundation
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
/// frame*  =  type(u8) | length(u32) | crc32(u32) | payload
/// ```
///
/// `containerVersion` şemadan **ayrı**: konteyner biçimi (çerçeveleme,
/// checksum) ile içerik şeması bağımsız evrilir. Tek bir sürüm numarası
/// olsaydı çerçevelemeye dokunmayan bir şema değişikliği eski dosyaları
/// okunamaz yapardı.
public enum SessionJournal {

    public static let magic = Data("BKJ1".utf8)
    public static let containerVersion: UInt16 = 1

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

        public var description: String {
            switch self {
            case .notAJournal:               return "günlük dosyası değil"
            case let .unsupportedContainer(v): return "desteklenmeyen konteyner: \(v)"
            case let .corruptFrame(i, d):    return "\(i). frame bozuk: \(d)"
            case .emptyJournal:              return "hiç frame yok"
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
        var out = magic
        out.append(le(containerVersion))
        out.append(le(schema))
        return out
    }

    public static func encode(_ frame: Frame) -> Data {
        var out = Data([frame.type.rawValue])
        out.append(le(UInt32(frame.payload.count)))
        out.append(le(crc32(frame.payload)))
        out.append(frame.payload)
        return out
    }

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
        let _: UInt16 = read(data, at: &i)      // schema — okuyucu ayrıca doğruluyor

        var frames: [Frame] = []
        var truncated = false

        while i < data.count {
            let frameStart = i
            // Başlık tam değilse: yarım yazılmış son frame.
            guard i + 9 <= data.count else {
                truncated = true
                break
            }
            let rawType = data[data.startIndex + i]; i += 1
            let length: UInt32 = read(data, at: &i)
            let checksum: UInt32 = read(data, at: &i)

            guard i + Int(length) <= data.count else {
                // Yük eksik. Son frame'se kurtarılır; değilse zaten dosya
                // sonundayız demektir.
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
            guard crc32(payload) == checksum else {
                // Bozukluk son frame'de ise kurtarılabilir; ortadaysa değil.
                if i == data.count {
                    truncated = true
                    break
                }
                return .failure(.corruptFrame(index: frames.count,
                                              detail: "checksum tutmuyor"))
            }
            frames.append(Frame(type: type, payload: payload))
        }

        guard !frames.isEmpty else { return .failure(.emptyJournal) }
        return .success(Loaded(frames: frames, truncatedTail: truncated))
    }

    // MARK: - Yardımcılar

    private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, at i: inout Int) -> T {
        let size = MemoryLayout<T>.size
        let slice = data.subdata(in: (data.startIndex + i)
                                  ..< (data.startIndex + i + size))
        i += size
        return slice.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
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
