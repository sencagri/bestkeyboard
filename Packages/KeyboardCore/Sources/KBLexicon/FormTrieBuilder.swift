import Foundation

/// Form trie üreticisi — `packbuilder`'ın Swift tarafı.
///
/// **Maliyet itme (§7.1):** paket **ham öznitelik deltalarını** iter, ağırlıklı
/// maliyeti değil. Böylece `w_lex` değişince paketin yeniden üretilmesi gerekmez.
///
/// İtme şeması:
/// - `bound(n)` = `n` düğümünün alt ağacındaki en küçük `L(w)`
/// - ark deltası `p → c` = `bound(c) − bound(p)`   (≥ 0, çünkü bound alt ağaçta minimum)
/// - terminal fazlası `n` = `L(w) − bound(n)`      (≥ 0)
///
/// Yol boyunca toplam = `bound(terminal) − bound(kök) + fazla = L(w)` (kök bound'u 0'a
/// normalize edilir). Ark deltaları negatif olmadığı için biriken maliyet her zaman
/// o düğümden ulaşılabilir en iyi kelimenin **admissible alt sınırıdır**.
public struct FormTrieBuilder {

    public struct Entry {
        public let word: String
        /// Ham leksikal öznitelik: `−log(freq / totalFreq)`.
        public let lexCost: Double
        public init(word: String, lexCost: Double) {
            self.word = word
            self.lexCost = lexCost
        }
    }

    private final class Node {
        var children: [UInt16: Node] = [:]
        var isTerminal = false
        var lexCost: Double = .infinity   // L(w), terminal ise
        var bound: Double = .infinity     // alt ağaçtaki min L(w)
    }

    public init() {}

    /// Frekanslardan ham leksikal maliyet üretir: `−log(count / total)`.
    public static func lexCosts(fromCounts counts: [String: Double]) -> [Entry] {
        let total = counts.values.reduce(0, +)
        precondition(total > 0, "boş frekans tablosu")
        return counts.map { Entry(word: $0.key, lexCost: -log($0.value / total)) }
            .sorted { $0.word < $1.word }
    }

    /// Trie'yi kurar ve binary'ye serileştirir.
    /// - Returns: (bytes, alphabet) — alfabe sembol kimliği sırasıyla.
    public func build(entries: [Entry], maxSurfaceLen: Int = 40) throws -> (bytes: [UInt8], alphabet: [Character]) {
        // Alfabe: NFC normalize edilmiş yüzey formlarındaki tüm karakterler (§7 kanonik kimlik).
        var alphabetSet = Set<Character>()
        var normalized: [(chars: [Character], lexCost: Double)] = []
        for e in entries {
            let chars = Array(e.word.precomposedStringWithCanonicalMapping)
            guard !chars.isEmpty, chars.count <= maxSurfaceLen else { continue }
            alphabetSet.formUnion(chars)
            normalized.append((chars, e.lexCost))
        }
        let alphabet = alphabetSet.sorted()
        precondition(alphabet.count <= Int(UInt16.max), "alfabe çok büyük")
        var symbolOf = [Character: UInt16]()
        for (i, c) in alphabet.enumerated() { symbolOf[c] = UInt16(i) }

        // Trie kurulumu.
        let root = Node()
        for (chars, cost) in normalized {
            var cur = root
            for ch in chars {
                let s = symbolOf[ch]!
                if let next = cur.children[s] {
                    cur = next
                } else {
                    let n = Node()
                    cur.children[s] = n
                    cur = n
                }
            }
            // Aynı yüzey birden çok kez gelirse en ucuzu kalır (tek sahiplik, §7).
            cur.isTerminal = true
            cur.lexCost = min(cur.lexCost, cost)
        }

        // bound(n) = alt ağaçtaki min L(w). Özyineleme yerine post-order yığın.
        computeBounds(root)

        // Düğümleri BFS ile numaralandır — 0 = kök.
        var nodes: [Node] = []
        var indexOf = [ObjectIdentifier: UInt32]()
        var queue: [Node] = [root]
        indexOf[ObjectIdentifier(root)] = 0
        nodes.append(root)
        var qi = 0
        while qi < queue.count {
            let n = queue[qi]; qi += 1
            for s in n.children.keys.sorted() {
                let c = n.children[s]!
                indexOf[ObjectIdentifier(c)] = UInt32(nodes.count)
                nodes.append(c)
                queue.append(c)
            }
        }

        // CSR arkları.
        var arcOffset: [UInt32] = [0]
        var arcSymbol: [UInt16] = []
        var arcTarget: [UInt32] = []
        var arcLexDelta: [Float] = []
        var nodeFlags: [UInt8] = []
        var nodeTermExtra: [Float] = []

        for n in nodes {
            // Kökün bound'u 0 kabul edilir; böylece yol boyunca toplam
            //   bound(terminal) + termExtra = L(w)
            // olur ve biriken maliyet **mutlak** kalır. (Kökü kendi bound'una eşitlemek
            // tüm L(w) değerlerini sabit bir miktar kaydırırdı; uzamsal ve edit
            // öznitelikleri kaymadığı için bu, terimler arası ölçeği bozar.)
            let parentBound = (n === root) ? 0.0 : n.bound
            for s in n.children.keys.sorted() {
                let c = n.children[s]!
                arcSymbol.append(s)
                arcTarget.append(indexOf[ObjectIdentifier(c)]!)
                // Δ = bound(child) − bound(parent) ≥ 0
                let delta = c.bound - parentBound
                precondition(delta >= -1e-9, "maliyet itme negatif delta üretti: \(delta)")
                arcLexDelta.append(Float(max(0, delta)))
            }
            arcOffset.append(UInt32(arcSymbol.count))
            nodeFlags.append(n.isTerminal ? 1 : 0)
            nodeTermExtra.append(n.isTerminal ? Float(max(0, n.lexCost - n.bound)) : 0)
        }

        // Serileştirme.
        var w = ByteWriter()
        w.u32(FormTrieFormat.magic)
        w.u16(FormTrieFormat.version)
        w.u16(0)                                  // flags
        w.u32(UInt32(nodes.count))
        w.u32(UInt32(arcSymbol.count))
        w.u16(UInt16(alphabet.count))
        w.u16(UInt16(maxSurfaceLen))
        w.u32(0)                                  // reserved
        let checksumOffset = w.bytes.count
        w.u64(0)                                  // checksum yer tutucu
        precondition(w.bytes.count == FormTrieFormat.headerSize)

        for c in alphabet { w.u32(c.unicodeScalars.first!.value) }
        for v in arcOffset { w.u32(v) }
        for v in arcSymbol { w.u16(v) }
        for v in arcTarget { w.u32(v) }
        for v in arcLexDelta { w.f32(v) }
        for v in nodeFlags { w.u8(v) }
        for v in nodeTermExtra { w.f32(v) }

        let payload = w.bytes[FormTrieFormat.headerSize...]
        w.replaceU64(at: checksumOffset, FNV1a.hash(payload))

        return (w.bytes, alphabet)
    }

    /// `bound(n)` — post-order, özyinelemesiz (derin trie'de yığın taşmasını önler).
    private func computeBounds(_ root: Node) {
        var stack: [(Node, Bool)] = [(root, false)]
        while let (n, visited) = stack.popLast() {
            if visited {
                var b = n.isTerminal ? n.lexCost : Double.infinity
                for c in n.children.values { b = min(b, c.bound) }
                n.bound = b
            } else {
                stack.append((n, true))
                for c in n.children.values { stack.append((c, false)) }
            }
        }
    }
}
