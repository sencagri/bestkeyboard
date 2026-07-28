import Foundation

/// Form listesi binary formatı — **açık byte offset'leri, little-endian**.
///
/// Skor sözleşmesi §4.2 gereği form listesi bir **trie**'dir, minimize edilmiş
/// DAWG değil: trie'de düğüm öneki tekil belirlediği için `surfaceId ≡ node`
/// olur ve farklı yüzey öneklerinin yanlış birleşmesi yapısal olarak imkânsızdır.
///
/// Swift `struct` yerleşimi bir dosya ABI'si **değildir**; bu yüzden okuma
/// sınır kontrollü unaligned little-endian alan okumalarıyla yapılır,
/// `unsafeBitCast` ile değil.
///
/// ```
/// Başlık (32 bayt)
///   0  magic          u32   "BKT1"
///   4  version        u16
///   6  flags          u16
///   8  nodeCount      u32
///  12  arcCount       u32
///  16  alphabetSize   u16
///  18  maxSurfaceLen  u16
///  20  reserved       u32
///  24  checksum       u64   FNV-1a, yük üzerinden
///
/// Yük (sırayla, hizalama yok)
///   alphabet     : alphabetSize × u32   (Unicode skaler; sembol kimliği = indeks)
///   arcOffset    : (nodeCount+1) × u32
///   arcSymbol    : arcCount × u16
///   arcTarget    : arcCount × u32
///   arcLexDelta  : arcCount × f32       ham F_lex deltası (maliyet itmeli, §7.1)
///   nodeFlags    : nodeCount × u8       bit0 = terminal
///   nodeTermExtra: nodeCount × f32      terminal ise L(w) − bound(node), değilse 0
/// ```
public enum FormTrieFormat {
    public static let magic: UInt32 = 0x314B_5442  // "BTK1" little-endian olarak "BKT1"
    public static let version: UInt16 = 1
    public static let headerSize = 32
}

/// Sınır kontrollü little-endian okuyucu.
/// mmap baytları üzerinde çalışır; hizalama varsayımı yapmaz.
public struct ByteReader {
    public let bytes: [UInt8]
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public enum Error: Swift.Error, CustomStringConvertible {
        case outOfBounds(offset: Int, need: Int, have: Int)
        case badMagic(UInt32)
        case badVersion(UInt16)
        case checksumMismatch(expected: UInt64, actual: UInt64)

        public var description: String {
            switch self {
            case let .outOfBounds(o, n, h): return "sınır dışı okuma: offset \(o), \(n) bayt gerekli, \(h) mevcut"
            case let .badMagic(m): return "geçersiz magic: \(String(m, radix: 16))"
            case let .badVersion(v): return "desteklenmeyen sürüm: \(v)"
            case let .checksumMismatch(e, a): return "checksum uyuşmuyor: beklenen \(e), bulunan \(a)"
            }
        }
    }

    public func u8(_ off: Int) throws -> UInt8 {
        guard off >= 0, off + 1 <= bytes.count else {
            throw Error.outOfBounds(offset: off, need: 1, have: bytes.count)
        }
        return bytes[off]
    }

    public func u16(_ off: Int) throws -> UInt16 {
        guard off >= 0, off + 2 <= bytes.count else {
            throw Error.outOfBounds(offset: off, need: 2, have: bytes.count)
        }
        return UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
    }

    public func u32(_ off: Int) throws -> UInt32 {
        guard off >= 0, off + 4 <= bytes.count else {
            throw Error.outOfBounds(offset: off, need: 4, have: bytes.count)
        }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[off + i]) << (8 * UInt32(i)) }
        return v
    }

    public func u64(_ off: Int) throws -> UInt64 {
        guard off >= 0, off + 8 <= bytes.count else {
            throw Error.outOfBounds(offset: off, need: 8, have: bytes.count)
        }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[off + i]) << (8 * UInt64(i)) }
        return v
    }

    public func f32(_ off: Int) throws -> Float {
        Float(bitPattern: try u32(off))
    }
}

/// Little-endian yazıcı — yalnız paket üretiminde kullanılır.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
    }
    public mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func replaceU64(at off: Int, _ v: UInt64) {
        for i in 0..<8 { bytes[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }
}

public enum FNV1a {
    public static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}
