import Foundation

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
/// Baytlar ayrıştırılmaz; CSR dizileri okuma anında sınır kontrollü little-endian
/// alan okumalarıyla çözülür (§11.A). Sıcak yol için diziler init'te bir kez
/// çözülüp saklanır — `-1A₁`'de hedef doğruluk; mmap tabanlı sıfır-kopya erişim
/// performans fazının işi.
public struct FormTrie: Sendable {
    public let nodeCount: Int
    public let arcCount: Int
    public let maxSurfaceLen: Int
    public let alphabet: [Unicode.Scalar]
    public let symbolOf: [Unicode.Scalar: UInt16]

    private let arcOffset: [UInt32]
    private let arcSymbolArr: [UInt16]
    private let arcTargetArr: [UInt32]
    private let arcLexDeltaArr: [Float]
    private let nodeTerminal: [Bool]
    private let nodeTermExtraArr: [Float]

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
        guard nodeCount > 0 else { throw StructureError.noNodes }

        if verifyChecksum {
            guard bytes.count > FormTrieFormat.headerSize else {
                throw ByteReader.Error.outOfBounds(offset: FormTrieFormat.headerSize, need: 1, have: bytes.count)
            }
            let actual = FNV1a.hash(bytes[FormTrieFormat.headerSize...])
            guard actual == checksum else {
                throw ByteReader.Error.checksumMismatch(expected: checksum, actual: actual)
            }
        }

        // --- Bölümleri sınır kontrollü çöz ---
        var off = FormTrieFormat.headerSize

        var alpha: [Unicode.Scalar] = []
        alpha.reserveCapacity(alphabetSize)
        for i in 0..<alphabetSize {
            let v = try r.u32(off + i * 4)
            guard let s = Unicode.Scalar(v) else { throw StructureError.badScalar(v) }
            alpha.append(s)
        }
        off += alphabetSize * 4

        var arcOffset = [UInt32](); arcOffset.reserveCapacity(nodeCount + 1)
        for i in 0...nodeCount { arcOffset.append(try r.u32(off + i * 4)) }
        off += (nodeCount + 1) * 4

        var arcSymbolArr = [UInt16](); arcSymbolArr.reserveCapacity(arcCount)
        for i in 0..<arcCount { arcSymbolArr.append(try r.u16(off + i * 2)) }
        off += arcCount * 2

        var arcTargetArr = [UInt32](); arcTargetArr.reserveCapacity(arcCount)
        for i in 0..<arcCount { arcTargetArr.append(try r.u32(off + i * 4)) }
        off += arcCount * 4

        var arcLexDeltaArr = [Float](); arcLexDeltaArr.reserveCapacity(arcCount)
        for i in 0..<arcCount { arcLexDeltaArr.append(try r.f32(off + i * 4)) }
        off += arcCount * 4

        var nodeTerminal = [Bool](); nodeTerminal.reserveCapacity(nodeCount)
        for i in 0..<nodeCount { nodeTerminal.append((try r.u8(off + i)) & 1 == 1) }
        off += nodeCount

        var nodeTermExtraArr = [Float](); nodeTermExtraArr.reserveCapacity(nodeCount)
        for i in 0..<nodeCount { nodeTermExtraArr.append(try r.f32(off + i * 4)) }
        off += nodeCount * 4

        guard off <= bytes.count else {
            throw ByteReader.Error.outOfBounds(offset: off, need: 0, have: bytes.count)
        }

        // --- Yapısal invariantlar ---
        // Checksum'ı geçen ama bozuk bir paket, doğrulama olmadan sıcak yolda
        // dizi taşmasına veya sonsuz döngüye götürebilir.
        guard arcOffset[0] == 0 else { throw StructureError.arcOffsetNotZeroBased(arcOffset[0]) }
        for i in 1...nodeCount {
            guard arcOffset[i] >= arcOffset[i - 1] else {
                throw StructureError.arcOffsetNotMonotone(index: i, prev: arcOffset[i - 1], cur: arcOffset[i])
            }
        }
        guard Int(arcOffset[nodeCount]) == arcCount else {
            throw StructureError.arcOffsetEndMismatch(last: arcOffset[nodeCount], arcCount: arcCount)
        }
        for node in 0..<nodeCount {
            for a in Int(arcOffset[node])..<Int(arcOffset[node + 1]) {
                guard Int(arcSymbolArr[a]) < alphabetSize else {
                    throw StructureError.symbolOutOfRange(arc: a, symbol: arcSymbolArr[a], alphabetSize: alphabetSize)
                }
                guard Int(arcTargetArr[a]) < nodeCount else {
                    throw StructureError.targetOutOfRange(arc: a, target: arcTargetArr[a], nodeCount: nodeCount)
                }
                // Trie BFS ile numaralandırıldığı için hedef daima kaynaktan ileridedir.
                // Bu, `closeOmissions`'ın sonlanmasını **yapısal** olarak garanti eder (I1).
                guard Int(arcTargetArr[a]) > node else {
                    throw StructureError.targetNotForward(arc: a, source: node, target: arcTargetArr[a])
                }
            }
        }

        self.nodeCount = nodeCount
        self.arcCount = arcCount
        self.maxSurfaceLen = maxSurfaceLen
        self.alphabet = alpha
        var m = [Unicode.Scalar: UInt16]()
        for (i, s) in alpha.enumerated() { m[s] = UInt16(i) }
        self.symbolOf = m
        self.arcOffset = arcOffset
        self.arcSymbolArr = arcSymbolArr
        self.arcTargetArr = arcTargetArr
        self.arcLexDeltaArr = arcLexDeltaArr
        self.nodeTerminal = nodeTerminal
        self.nodeTermExtraArr = nodeTermExtraArr
    }

    public static let rootNode: UInt32 = 0

    // Aşağıdaki erişimler init'in yapısal doğrulamasına dayanır; `try!` yoktur.
    @inline(__always) public func arcRange(_ node: UInt32) -> Range<Int> {
        Int(arcOffset[Int(node)])..<Int(arcOffset[Int(node) + 1])
    }
    @inline(__always) public func arcSymbol(_ i: Int) -> UInt16 { arcSymbolArr[i] }
    @inline(__always) public func arcTarget(_ i: Int) -> UInt32 { arcTargetArr[i] }
    /// Ham `F_lex` deltası — çalışma anında `w_lex` ile çarpılır (§7.1).
    @inline(__always) public func arcLexDelta(_ i: Int) -> Double { Double(arcLexDeltaArr[i]) }
    @inline(__always) public func isTerminal(_ node: UInt32) -> Bool { nodeTerminal[Int(node)] }
    /// Terminal fazlası: `L(w) − bound(node)`, ham (§7.1).
    @inline(__always) public func nodeTermExtra(_ node: UInt32) -> Double { Double(nodeTermExtraArr[Int(node)]) }

    public func scalar(_ symbol: UInt16) -> Unicode.Scalar { alphabet[Int(symbol)] }
    public func character(_ symbol: UInt16) -> Character { Character(alphabet[Int(symbol)]) }

    /// Yalnız test ve teşhis için — kelimenin trie'de olup olmadığı ve ham `F_lex`'i.
    public func lookup(_ word: String) -> Double? {
        var node = Self.rootNode
        var acc = 0.0
        for s in word.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard let sym = symbolOf[s] else { return nil }
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
