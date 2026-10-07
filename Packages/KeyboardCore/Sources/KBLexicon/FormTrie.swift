import Foundation
import KBGeometry

/// Otomat kaynağı — skor sözleşmesi §4.
public enum AutomatonKind: UInt8, Sendable {
    case formTrie = 0
    case morphology = 1
    case personal = 2
    case domain = 3
}

/// Salt-okunur form trie.
///
/// **Doğrulama sözleşmesi:** `init` başlığı, checksum'ı **ve tüm yapısal
/// invariantları** doğrular (CSR monotonluğu, sembol/hedef sınırları). Bundan
/// sonra sıcak yol erişimleri kontrolsüz okuyabilir — bu, `try!`'ın anlamsız
/// olduğu değil, **init'in onu gereksiz kıldığı** anlamına gelir.
///
/// **Baytlar ayrıştırılmaz.** Trie, kendisine verilen `Data`'yı sahiplenir ve CSR
/// alanlarını okuma anında doğrudan onun üzerinden çözer (§11.A). `Data`
/// `.mappedIfSafe` ile açılmışsa sayfalar yalnız dokunuldukça resident olur;
/// ara kopya veya çözülmüş Swift dizisi **yoktur**.
public struct FormTrie: Sendable {
    public let nodeCount: Int
    public let arcCount: Int
    public let maxSurfaceLen: Int
    public let alphabet: [Unicode.Scalar]
    public let symbolOf: [Unicode.Scalar: UInt16]

    /// Sahiplenilen ham paket. mmap'lenmişse sayfalar tembel resident olur.
    private let data: Data
    private let offArcOffset: Int
    private let offArcSymbol: Int
    private let offArcTarget: Int
    private let offArcLexDelta: Int
    private let offNodeFlags: Int
    private let offNodeTermExtra: Int

    public enum StructureError: Error, CustomStringConvertible {
        case arcOffsetNotZeroBased(UInt32)
        case arcOffsetNotMonotone(index: Int, prev: UInt32, cur: UInt32)
        case arcOffsetEndMismatch(last: UInt32, arcCount: Int)
        case symbolOutOfRange(arc: Int, symbol: UInt16, alphabetSize: Int)
        case targetOutOfRange(arc: Int, target: UInt32, nodeCount: Int)
        case targetNotForward(arc: Int, source: Int, target: UInt32)
        case badScalar(UInt32)
        case noNodes

        public var description: String {
            switch self {
            case let .arcOffsetNotZeroBased(v): return "arcOffset[0] = \(v), 0 olmalı"
            case let .arcOffsetNotMonotone(i, p, c): return "arcOffset monoton değil: [\(i)] \(p) → \(c)"
            case let .arcOffsetEndMismatch(l, a): return "arcOffset sonu \(l), arcCount \(a) olmalı"
            case let .symbolOutOfRange(a, s, n): return "ark \(a): sembol \(s) alfabe sınırı \(n) dışında"
            case let .targetOutOfRange(a, t, n): return "ark \(a): hedef \(t) düğüm sayısı \(n) dışında"
            case let .targetNotForward(a, s, t): return "ark \(a): hedef \(t) kaynak \(s)'ten ileri değil (çevrim riski)"
            case let .badScalar(v): return "geçersiz Unicode skaler: \(v)"
            case .noNodes: return "düğüm yok"
            }
        }
    }

    public init(bytes: [UInt8], verifyChecksum: Bool = true) throws {
        try self.init(data: Data(bytes), verifyChecksum: verifyChecksum)
    }

    /// Asıl init. `data` **sahiplenilir** ve sıcak yolda doğrudan üzerinden okunur.
    /// `.mappedIfSafe` ile açılmış bir `Data` verilirse kopya oluşmaz.
    public init(data: Data, verifyChecksum: Bool = true) throws {
        let magic: UInt32 = try Self.readU32(data, 0)
        guard magic == FormTrieFormat.magic else { throw ByteReader.Error.badMagic(magic) }
        let version: UInt16 = try Self.readU16(data, 4)
        guard version == FormTrieFormat.version else { throw ByteReader.Error.badVersion(version) }

        let nodeCount = Int(try Self.readU32(data, 8))
        let arcCount = Int(try Self.readU32(data, 12))
        let alphabetSize = Int(try Self.readU16(data, 16))
        let maxSurfaceLen = Int(try Self.readU16(data, 18))
        let checksum = try Self.readU64(data, 24)
        guard nodeCount > 0 else { throw StructureError.noNodes }

        if verifyChecksum {
            guard data.count > FormTrieFormat.headerSize else {
                throw ByteReader.Error.outOfBounds(offset: FormTrieFormat.headerSize, need: 1, have: data.count)
            }
            let actual = data.withUnsafeBytes { FNV1a.hash($0[FormTrieFormat.headerSize...]) }
            guard actual == checksum else {
                throw ByteReader.Error.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        // --- Bölüm offset'leri ---
        var off = FormTrieFormat.headerSize
        let offAlphabet = off;        off += alphabetSize * 4
        let offArcOffset = off;       off += (nodeCount + 1) * 4
        let offArcSymbol = off;       off += arcCount * 2
        let offArcTarget = off;       off += arcCount * 4
        let offArcLexDelta = off;     off += arcCount * 4
        let offNodeFlags = off;       off += nodeCount
        let offNodeTermExtra = off;   off += nodeCount * 4

        guard off <= data.count else {
            throw ByteReader.Error.outOfBounds(offset: off, need: 0, have: data.count)
        }

        // Alfabe küçük ve sık erişilen bir tablo — tek kopyası tutulur.
        var alpha: [Unicode.Scalar] = []
        alpha.reserveCapacity(alphabetSize)
        for i in 0..<alphabetSize {
            let v = try Self.readU32(data, offAlphabet + i * 4)
            guard let sc = Unicode.Scalar(v) else { throw StructureError.badScalar(v) }
            alpha.append(sc)
        }

        // --- Yapısal invariantlar ---
        // Checksum'ı geçen ama bozuk bir paket, doğrulama olmadan sıcak yolda
        // sınır dışı okumaya veya sonsuz döngüye götürebilir. Bu tek seferlik
        // O(ark) tarama, sıcak yoldaki kontrolleri gereksiz kılar.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            func u16(_ o: Int) -> UInt16 {
                let a = UInt16(raw[o]), b = UInt16(raw[o + 1])
                return a | (b << 8)
            }
            func u32(_ o: Int) -> UInt32 {
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(raw[o + i]) << (8 * UInt32(i)) }
                return v
            }
            let first = u32(offArcOffset)
            guard first == 0 else { throw StructureError.arcOffsetNotZeroBased(first) }
            var prev: UInt32 = 0
            for i in 1...nodeCount {
                let cur = u32(offArcOffset + i * 4)
                guard cur >= prev else {
                    throw StructureError.arcOffsetNotMonotone(index: i, prev: prev, cur: cur)
                }
                prev = cur
            }
            guard Int(prev) == arcCount else {
                throw StructureError.arcOffsetEndMismatch(last: prev, arcCount: arcCount)
            }
            for node in 0..<nodeCount {
                let lo = Int(u32(offArcOffset + node * 4))
                let hi = Int(u32(offArcOffset + (node + 1) * 4))
                for a in lo..<hi {
                    let sym = u16(offArcSymbol + a * 2)
                    guard Int(sym) < alphabetSize else {
                        throw StructureError.symbolOutOfRange(arc: a, symbol: sym, alphabetSize: alphabetSize)
                    }
                    let tgt = u32(offArcTarget + a * 4)
                    guard Int(tgt) < nodeCount else {
                        throw StructureError.targetOutOfRange(arc: a, target: tgt, nodeCount: nodeCount)
                    }
                    // Trie BFS ile numaralandırıldığı için hedef daima kaynaktan ileridedir.
                    // Bu, OM kapanışının sonlanmasını **yapısal** olarak garanti eder (I1).
                    guard Int(tgt) > node else {
                        throw StructureError.targetNotForward(arc: a, source: node, target: tgt)
                    }
                }
            }
        }

        self.data = data
        self.nodeCount = nodeCount
        self.arcCount = arcCount
        self.maxSurfaceLen = maxSurfaceLen
        self.alphabet = alpha
        var m = [Unicode.Scalar: UInt16]()
        for (i, sc) in alpha.enumerated() { m[sc] = UInt16(i) }
        self.symbolOf = m
        self.offArcOffset = offArcOffset
        self.offArcSymbol = offArcSymbol
        self.offArcTarget = offArcTarget
        self.offArcLexDelta = offArcLexDelta
        self.offNodeFlags = offNodeFlags
        self.offNodeTermExtra = offNodeTermExtra
    }

    // MARK: - Sınır kontrollü başlık okuyucuları (yalnız init)

    private static func readU16(_ d: Data, _ o: Int) throws -> UInt16 {
        guard o >= 0, o + 2 <= d.count else {
            throw ByteReader.Error.outOfBounds(offset: o, need: 2, have: d.count)
        }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt16 in
            let a = UInt16(raw[o]), b = UInt16(raw[o + 1])
            return a | (b << 8)
        }
    }
    private static func readU32(_ d: Data, _ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= d.count else {
            throw ByteReader.Error.outOfBounds(offset: o, need: 4, have: d.count)
        }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(raw[o + i]) << (8 * UInt32(i)) }
            return v
        }
    }
    private static func readU64(_ d: Data, _ o: Int) throws -> UInt64 {
        guard o >= 0, o + 8 <= d.count else {
            throw ByteReader.Error.outOfBounds(offset: o, need: 8, have: d.count)
        }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(raw[o + i]) << (8 * UInt64(i)) }
            return v
        }
    }

    // MARK: - Sıcak yol: doğrudan mapped bellekten, init doğrulamasına dayanarak

    @inline(__always) private func u16(_ o: Int) -> UInt16 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt16 in
            let a = UInt16(raw[o]), b = UInt16(raw[o + 1])
            return a | (b << 8)
        }
    }
    @inline(__always) private func u32(_ o: Int) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(raw[o + i]) << (8 * UInt32(i)) }
            return v
        }
    }

    public static let rootNode: UInt32 = 0

    @inline(__always) public func arcRange(_ node: UInt32) -> Range<Int> {
        Int(u32(offArcOffset + Int(node) * 4))..<Int(u32(offArcOffset + (Int(node) + 1) * 4))
    }
    @inline(__always) public func arcSymbol(_ i: Int) -> UInt16 { u16(offArcSymbol + i * 2) }
    @inline(__always) public func arcTarget(_ i: Int) -> UInt32 { u32(offArcTarget + i * 4) }
    /// Ham `F_lex` deltası — çalışma anında `w_lex` ile çarpılır (§7.1).
    @inline(__always) public func arcLexDelta(_ i: Int) -> Double {
        Double(Float(bitPattern: u32(offArcLexDelta + i * 4)))
    }
    @inline(__always) public func isTerminal(_ node: UInt32) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            raw[offNodeFlags + Int(node)] & 1 == 1
        }
    }
    /// Terminal fazlası: `L(w) − bound(node)`, ham (§7.1).
    @inline(__always) public func nodeTermExtra(_ node: UInt32) -> Double {
        Double(Float(bitPattern: u32(offNodeTermExtra + Int(node) * 4)))
    }

    public func scalar(_ symbol: UInt16) -> Unicode.Scalar { alphabet[Int(symbol)] }
    public func character(_ symbol: UInt16) -> Character { Character(alphabet[Int(symbol)]) }

    /// Yalnız test ve teşhis için — kelimenin trie'de olup olmadığı ve ham `F_lex`'i.
    public func lookup(_ word: String) -> Double? {
        var node = Self.rootNode
        var acc = 0.0
        for sc in word.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard let sym = symbolOf[sc] else { return nil }
            var found = false
            for i in arcRange(node) where arcSymbol(i) == sym {
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
