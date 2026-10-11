import Foundation
import Compression

/// Small, bounded ZIP reader for chat exports. No files are extracted to disk.
/// ZIP64, multi-disk and encrypted archives are intentionally unsupported.
public enum BoundedZIPReader {
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    public static let maximumEntryBytes = 32 * 1024 * 1024

    public static func firstEntry(in data: Data, matching: (String) -> Bool) -> Data? {
        guard data.count >= 22, data.count <= maximumArchiveBytes else { return nil }
        let b = [UInt8](data)
        func fits(_ offset: Int, _ length: Int, end: Int) -> Bool {
            offset >= 0 && length >= 0 && offset <= end && length <= end - offset
        }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // EOCD is at most a 16-bit comment away from the end. A signature in
        // the comment is not an EOCD unless its declared comment ends at EOF.
        let lower = max(0, b.count - 22 - 65535)
        guard let end = stride(from: b.count - 22, through: lower, by: -1).first(where: {
            u32($0) == 0x06054b50 && u16($0 + 20) == b.count - $0 - 22
        }) else { return nil }
        let count = u16(end + 10), directorySize = u32(end + 12)
        var p = u32(end + 16)
        guard u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == count, count != 65535,
              fits(p, directorySize, end: end), p + directorySize == end else { return nil }
        let directoryEnd = end
        let directoryStart = p
        for _ in 0..<count {
            guard fits(p, 46, end: directoryEnd), u32(p) == 0x02014b50 else { return nil }
            let flags = u16(p + 8), method = u16(p + 10)
            let crc = UInt32(u32(p + 16)), compressed = u32(p + 20), expanded = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32)
            let local = u32(p + 42)
            guard u16(p + 34) == 0,
                  fits(p + 46, nameLength + extraLength + commentLength, end: directoryEnd) else { return nil }
            let nameBytes = Array(b[(p + 46)..<(p + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }
            p += 46 + nameLength + extraLength + commentLength
            guard matching(name) else { continue }
            guard flags & 0x41 == 0, compressed <= maximumArchiveBytes, expanded <= maximumEntryBytes,
                  fits(local, 30, end: directoryStart), u32(local) == 0x04034b50,
                  u16(local + 6) == flags, u16(local + 8) == method else { return nil }
            let localNameLength = u16(local + 26), localExtraLength = u16(local + 28)
            let start = local + 30 + localNameLength + localExtraLength
            guard fits(local + 30, localNameLength + localExtraLength, end: directoryStart),
                  localNameLength == nameLength,
                  Array(b[(local + 30)..<(local + 30 + localNameLength)]) == nameBytes,
                  fits(start, compressed, end: directoryStart) else { return nil }
            let source = Data(b[start..<(start + compressed)])
            let output: Data
            if method == 0 {
                guard compressed == expanded else { return nil }
                output = source
            } else if method == 8 {
                // One extra byte detects streams expanding beyond the declared size.
                var buffer = Data(count: expanded + 1)
                let n = buffer.withUnsafeMutableBytes { dst in
                    source.withUnsafeBytes { src in
                        guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                              let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(d, expanded + 1, s, compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                guard n == expanded, compressed > 0 else { return nil }
                output = Data(buffer.prefix(n))
            } else { return nil }
            guard crc32(output) == crc else { return nil }
            return output
        }
        return nil
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~crc
    }
}
