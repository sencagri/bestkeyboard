import Foundation

/// Kökler üzerinde **ortak önekli trie**.
///
/// Neden gerekli: her kök için ayrı başlangıç durumu üretmek, decoder'ın
/// başlangıç frontier'ını `O(kök sayısı)` yapıyordu. `kbbench` ile ölçüldü
/// (tuş başına p99, bütçe 8 ms):
///
///     8 kök    2.10 ms
///   108 kök    9.77 ms   ← bütçe aşıldı
///   408 kök   33.44 ms   ← 4× aşım
///
/// Üstelik tohumlar doğruluk için **budanamıyor** (budanınca doğru kök kanıt
/// görmeden eleniyordu), yani bu doğrusal maliyetten kaçış yoktu. Ortak önek
/// paylaşımıyla başlangıç frontier'ı `O(1)`'e iniyor.
///
/// **Varyantlar trie'ye ayrı yol olarak gömülür.** Yumuşama (`kitap → kitab`)
/// ve ünlü düşmesi (`burun → burn`) ark seviyesinde dallandırılsaydı, hangi
/// kökün bittiğini bilmek gerekirdi — ortak önekte bu bilgi yok. Varyantı ayrı
/// bir yol olarak eklemek hem daha basit hem de tekdüze:
///
///     kitap → terminal(kitap, .plain)
///     kitab → terminal(kitap, .softened)
///     burun → terminal(burun, .plain)
///     burn  → terminal(burun, .droppedVowel)
public struct RootTrie: Sendable {

    /// Bir kökün hangi biçimde bittiği — sonraki ekin ne olabileceğini belirler.
    public enum Variant: UInt8, Sendable {
        /// Kökün sözlük biçimi.
        case plain
        /// Yumuşamış son ünsüz (`kitab-`). Yalnız ünlüyle başlayan ek alır,
        /// kelime burada bitemez.
        case softened
        /// Son hecedeki ünlü düşmüş (`burn-`). Aynı kısıt.
        case droppedVowel
    }

    public struct Terminal: Sendable {
        public let rootIndex: UInt32
        public let variant: Variant
        /// `L(kök) − bound(düğüm)` — maliyet itmesinin terminal fazlası (§7.1).
        public let extraCost: Double
    }

    // CSR yerleşimi — form trie ile aynı desen.
    public private(set) var arcSymbol: [Character] = []
    public private(set) var arcTarget: [UInt32] = []
    /// `bound(hedef) − bound(kaynak)` — itilmiş ham `F_lex` deltası.
    public private(set) var arcDelta: [Double] = []
    private var arcOffset: [Int] = [0]

    public private(set) var terminals: [Terminal] = []
    private var terminalOffset: [Int] = [0]

    public var nodeCount: Int { arcOffset.count - 1 }
    public var arcCount: Int { arcSymbol.count }

    public static let root: UInt32 = 0

    @inline(__always)
    public func arcRange(_ node: UInt32) -> Range<Int> {
        arcOffset[Int(node)]..<arcOffset[Int(node) + 1]
    }

    @inline(__always)
    public func terminalRange(_ node: UInt32) -> Range<Int> {
        terminalOffset[Int(node)]..<terminalOffset[Int(node) + 1]
    }

    // MARK: - Kurulum

    private final class Builder {
        var children: [Character: Builder] = [:]
        /// (kök indeksi, varyant, ham L(kök))
        var terminals: [(UInt32, Variant, Double)] = []
        var bound: Double = .infinity
    }

    public init(roots: [Root]) {
        let rootNode = Builder()

        func insert(_ chars: [Character], _ rootIndex: UInt32, _ variant: Variant, _ cost: Double) {
            guard !chars.isEmpty else { return }
            var cur = rootNode
            for ch in chars {
                if let next = cur.children[ch] { cur = next }
                else { let n = Builder(); cur.children[ch] = n; cur = n }
            }
            cur.terminals.append((rootIndex, variant, cost))
        }

        for (i, r) in roots.enumerated() {
            let idx = UInt32(i)
            insert(r.surface, idx, .plain, r.lexCost)

            // Yumuşamış varyant: son ünsüz alternasyon sınıfına göre değişir.
            if let alt = r.finalAlternation, r.surface.last == alt.source {
                var soft = r.surface
                soft[soft.count - 1] = alt.target
                insert(soft, idx, .softened, r.lexCost)
            }

            // Ünlü düşmüş varyant: son ünlü çıkarılır (`burun → burn`).
            if r.dropsVowel, let vi = Self.lastVowelIndex(r.surface), vi < r.surface.count - 1 {
                var dropped = r.surface
                dropped.remove(at: vi)
                insert(dropped, idx, .droppedVowel, r.lexCost)
            }
        }

        // bound(n) = alt ağaçtaki en küçük L(kök) — özyinelemesiz post-order.
        var stack: [(Builder, Bool)] = [(rootNode, false)]
        while let (n, visited) = stack.popLast() {
            if visited {
                var b = n.terminals.map(\.2).min() ?? Double.infinity
                for c in n.children.values { b = min(b, c.bound) }
                n.bound = b
            } else {
                stack.append((n, true))
                for c in n.children.values { stack.append((c, false)) }
            }
        }

        // BFS numaralandırma + CSR serileştirme.
        var order: [Builder] = [rootNode]
        var index: [ObjectIdentifier: UInt32] = [ObjectIdentifier(rootNode): 0]
        var qi = 0
        while qi < order.count {
            let n = order[qi]; qi += 1
            for ch in n.children.keys.sorted() {
                let c = n.children[ch]!
                index[ObjectIdentifier(c)] = UInt32(order.count)
                order.append(c)
            }
        }

        for n in order {
            // Kökün bound'u 0 kabul edilir → yol toplamı mutlak `L(kök)` olur
            // (form trie ile aynı sözleşme, §7.1).
            let parentBound = (n === rootNode) ? 0.0 : n.bound
            for ch in n.children.keys.sorted() {
                let c = n.children[ch]!
                arcSymbol.append(ch)
                arcTarget.append(index[ObjectIdentifier(c)]!)
                arcDelta.append(max(0, c.bound - parentBound))
            }
            arcOffset.append(arcSymbol.count)

            for (ri, variant, cost) in n.terminals.sorted(by: { $0.0 < $1.0 }) {
                terminals.append(Terminal(rootIndex: ri, variant: variant,
                                          extraCost: max(0, cost - n.bound)))
            }
            terminalOffset.append(terminals.count)
        }
    }

    static func lastVowelIndex(_ s: [Character]) -> Int? {
        for i in stride(from: s.count - 1, through: 0, by: -1) where Phonology.isVowel(s[i]) {
            return i
        }
        return nil
    }
}
