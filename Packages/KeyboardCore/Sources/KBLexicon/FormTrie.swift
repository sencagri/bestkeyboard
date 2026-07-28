import Foundation

/// Otomat kaynağı — skor sözleşmesi §4.
public enum AutomatonKind: UInt8, Sendable {
    case formTrie = 0
    case morphology = 1
    case personal = 2
    case domain = 3
}

/// Salt-okunur form trie. Baytları **ayrıştırmaz**; sınır kontrollü
/// little-endian alan okumalarıyla doğrudan üzerinde yürür (§11.A).
public struct FormTrie: Sendable {
    public let nodeCount: Int
    public let arcCount: Int
    public let maxSurfaceLen: Int
    public let alphabet: [Character]
    /// Karakter → sembol kimliği.
    public let symbolOf: [Character: UInt16]

    private let bytes: [UInt8]
    private let offArcOffset: Int
    private let offArcSymbol: Int
    private let offArcTarget: Int
    private let offArcLexDelta: Int
    private let offNodeFlags: Int
    private let offNodeTermExtra: Int

    public init(bytes: [UInt8], verifyChecksum: Bool = true) throws {
        let r = ByteReader(bytes)
        let magic = try r.u32(0)
        guard magic == FormTrieFormat.magic else { throw ByteReader.Error.badMagic(magic) }
        let version = try r.u16(4)
        guard version == FormTrieFormat.version else { throw ByteReader.Error.badVersion(version) }

        let nodeCount = Int(try r.u32(8))
        let arcCount = Int(try r.u32(12))
        let alphabetSize = Int(try r.u16(16))
        let maxSurfaceLen = Int(try r.u16(18))
        let checksum = try r.u64(24)

        if verifyChecksum {
            guard bytes.count > FormTrieFormat.headerSize else {
                throw ByteReader.Error.outOfBounds(offset: FormTrieFormat.headerSize, need: 1, have: bytes.count)
            }
            let actual = FNV1a.hash(bytes[FormTrieFormat.headerSize...])
            guard actual == checksum else {
                throw ByteReader.Error.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        var off = FormTrieFormat.headerSize
        var alpha: [Character] = []
        alpha.reserveCapacity(alphabetSize)
        for i in 0..<alphabetSize {
            let scalarValue = try r.u32(off + i * 4)
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw ByteReader.Error.badVersion(version)  // bozuk alfabe
            }
            alpha.append(Character(scalar))
        }
        off += alphabetSize * 4

        self.offArcOffset = off;      off += (nodeCount + 1) * 4
        self.offArcSymbol = off;      off += arcCount * 2
        self.offArcTarget = off;      off += arcCount * 4
        self.offArcLexDelta = off;    off += arcCount * 4
        self.offNodeFlags = off;      off += nodeCount * 1
        self.offNodeTermExtra = off;  off += nodeCount * 4

        guard off <= bytes.count else {
            throw ByteReader.Error.outOfBounds(offset: off, need: 0, have: bytes.count)
        }

        self.bytes = bytes
        self.nodeCount = nodeCount
        self.arcCount = arcCount
        self.maxSurfaceLen = maxSurfaceLen
        self.alphabet = alpha
        var m = [Character: UInt16]()
        for (i, c) in alpha.enumerated() { m[c] = UInt16(i) }
        self.symbolOf = m
    }

    public static let rootNode: UInt32 = 0

    @inline(__always)
    public func arcRange(_ node: UInt32) -> Range<Int> {
        let r = ByteReader(bytes)
        let a = Int(try! r.u32(offArcOffset + Int(node) * 4))
        let b = Int(try! r.u32(offArcOffset + (Int(node) + 1) * 4))
        return a..<b
    }

    @inline(__always)
    public func arcSymbol(_ i: Int) -> UInt16 {
        let r = ByteReader(bytes)
        return try! r.u16(offArcSymbol + i * 2)
    }

    @inline(__always)
    public func arcTarget(_ i: Int) -> UInt32 {
        let r = ByteReader(bytes)
        return try! r.u32(offArcTarget + i * 4)
    }

    /// Ham `F_lex` deltası — çalışma anında `w_lex` ile çarpılır (§7.1).
    @inline(__always)
    public func arcLexDelta(_ i: Int) -> Double {
        let r = ByteReader(bytes)
        return Double(try! r.f32(offArcLexDelta + i * 4))
    }

    @inline(__always)
    public func isTerminal(_ node: UInt32) -> Bool {
        let r = ByteReader(bytes)
        return (try! r.u8(offNodeFlags + Int(node))) & 1 == 1
    }

    /// Terminal fazlası: `L(w) − bound(node)`, ham (§7.1).
    @inline(__always)
    public func nodeTermExtra(_ node: UInt32) -> Double {
        let r = ByteReader(bytes)
        return Double(try! r.f32(offNodeTermExtra + Int(node) * 4))
    }

    public func character(_ symbol: UInt16) -> Character { alphabet[Int(symbol)] }

    /// Yalnız test ve teşhis için — kelimenin trie'de olup olmadığı ve ham `F_lex`'i.
    public func lookup(_ word: String) -> Double? {
        var node = Self.rootNode
        var acc = 0.0
        for ch in word.precomposedStringWithCanonicalMapping {
            guard let s = symbolOf[ch] else { return nil }
            var found = false
            for i in arcRange(node) where arcSymbol(i) == s {
                acc += arcLexDelta(i)
                node = arcTarget(i)
                found = true
                break
            }
            if !found { return nil }
        }
        guard isTerminal(node) else { return nil }
        return acc + nodeTermExtra(node)
    }
}
