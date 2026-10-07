import Foundation
import KBFoundation

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

    /// Trie'ye özgü yapısal hatalar. Ortak durumlar (magic, sürüm, checksum,
    /// kesiklik, alfabe, CSR offset'leri) `BinaryFormatError`.
    public enum StructureError: Error, CustomStringConvertible {
        case symbolOutOfRange(arc: Int, symbol: UInt16, alphabetSize: Int)
        case targetOutOfRange(arc: Int, target: UInt32, nodeCount: Int)
        case targetNotForward(arc: Int, source: Int, target: UInt32)
        case noNodes

        public var description: String {
            switch self {
            case let .symbolOutOfRange(a, s, n): return "ark \(a): sembol \(s) alfabe sınırı \(n) dışında"
            case let .targetOutOfRange(a, t, n): return "ark \(a): hedef \(t) düğüm sayısı \(n) dışında"
            case let .targetNotForward(a, s, t): return "ark \(a): hedef \(t) kaynak \(s)'ten ileri değil (çevrim riski)"
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
        let r = try FormTrieFormat.container.open(data, verifyChecksum: verifyChecksum)
        let nodeCount = Int(try r.u32(8))
        let arcCount = Int(try r.u32(12))
        let alphabetSize = Int(try r.u16(16))
        let maxSurfaceLen = Int(try r.u16(18))
        guard nodeCount > 0 else { throw StructureError.noNodes }

        // --- Bölüm offset'leri ---
        var off = FormTrieFormat.container.headerSize
        let offAlphabet = off;        off += alphabetSize * 4
        let offArcOffset = off;       off += (nodeCount + 1) * 4
        let offArcSymbol = off;       off += arcCount * 2
        let offArcTarget = off;       off += arcCount * 4
        let offArcLexDelta = off;     off += arcCount * 4
        let offNodeFlags = off;       off += nodeCount
        let offNodeTermExtra = off;   off += nodeCount * 4
        try r.requireRange(0, off)

        // Alfabe küçük ve sık erişilen bir tablo — tek kopyası tutulur.
        let alpha = try r.alphabet(at: offAlphabet, count: alphabetSize)

        // --- Yapısal invariantlar ---
        // Checksum'ı geçen ama bozuk bir paket, doğrulama olmadan sıcak yolda
        // sınır dışı okumaya veya sonsuz döngüye götürebilir. Bu tek seferlik
        // O(ark) tarama, sıcak yoldaki kontrolleri gereksiz kılar.
        try r.offsets(at: offArcOffset, count: nodeCount, section: "arcOffset", end: arcCount)
        for node in 0..<nodeCount {
            let lo = Int(r.unchecked(UInt32.self, offArcOffset + node * 4))
            let hi = Int(r.unchecked(UInt32.self, offArcOffset + (node + 1) * 4))
            for a in lo..<hi {
                let sym = r.unchecked(UInt16.self, offArcSymbol + a * 2)
                guard Int(sym) < alphabetSize else {
                    throw StructureError.symbolOutOfRange(arc: a, symbol: sym, alphabetSize: alphabetSize)
                }
                let tgt = r.unchecked(UInt32.self, offArcTarget + a * 4)
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

    // MARK: - Sıcak yol: doğrudan mapped bellekten, init doğrulamasına dayanarak

    @inline(__always) private func u16(_ o: Int) -> UInt16 { data.littleEndian(UInt16.self, at: o) }
    @inline(__always) private func u32(_ o: Int) -> UInt32 { data.littleEndian(UInt32.self, at: o) }

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
        data.littleEndian(UInt8.self, at: offNodeFlags + Int(node)) & 1 == 1
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
