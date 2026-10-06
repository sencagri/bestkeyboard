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
        /// `a`/`e` ile biten fiil kökünün **daralmış** biçimi (`başla → başl`).
        ///
        /// Yalnız şimdiki zaman `-Iyor` alıyor: `başlıyor` doğru, `başlır`
        /// değil (`başlar` doğru). Bu yüzden `droppedVowel`'dan ayrı bir
        /// varyant — o "her ünlüyle başlayan ek" diyor, bu tek bir eki.
        case contractedBeforeProgressive
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

    /// Trie'ye girecek bir yol: (yüzey, kök indeksi, varyant, ham L(kök)).
    private typealias Entry = (chars: [Character], root: UInt32, variant: Variant, cost: Double)

    /// **Ara ağaç kurulmuyor.** Önce her düğüm bir sınıf nesnesi ve bir
    /// `Dictionary` taşıyordu; 50k kökte (~100k yol) kurulum anında bellek
    /// tepesi kalıcı yapının birkaç katına çıkıyordu ve paket yüklemesi tek
    /// başına ~56 MB tepeye ulaşıyordu — klavye uzantısının bellek sınırına
    /// dayanıp sistem tarafından öldürülmesi için yeterli.
    ///
    /// Yollar sıralanınca her düğüm, sıralı listede **bitişik bir aralık**
    /// oluyor ve çocukları o aralığın bir sonraki karaktere göre bitişik
    /// grupları. CSR doğrudan bu aralıklardan, BFS sırasıyla üretiliyor —
    /// düğüm numaraları, ark sırası ve terminal sırası eski kurulumla aynı.
    public init(roots: [Root]) {
        var entries: [Entry] = []
        entries.reserveCapacity(roots.count * 2)

        func insert(_ chars: [Character], _ rootIndex: UInt32, _ variant: Variant, _ cost: Double) {
            guard !chars.isEmpty else { return }
            entries.append((chars, rootIndex, variant, cost))
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

            // Daralma: `a`/`e` ile biten **fiil** kökü `-Iyor` önünde son
            // ünlüsünü düşürür (`başla → başl`, `bekle → bekl`). Kural
            // düzenli, sözlüksel değil — bu yüzden bayrak istemiyor.
            // `oku → okuyor` daralmıyor; kural yalnız `a`/`e` için.
            if r.pos == .verb, let last = r.surface.last, last == "a" || last == "e",
               r.surface.count > 1 {
                insert(Array(r.surface.dropLast()), idx, .contractedBeforeProgressive, r.lexCost)
            }

            // Ünlü düşmüş varyant: son ünlü çıkarılır (`burun → burn`).
            if r.dropsVowel, let vi = Self.lastVowelIndex(r.surface), vi < r.surface.count - 1 {
                var dropped = r.surface
                dropped.remove(at: vi)
                insert(dropped, idx, .droppedVowel, r.lexCost)
            }
        }

        // Yüzeye göre sırala; eşitlikte ekleme sırası korunuyor ki bir düğümün
        // terminalleri kök indeksine göre sıralı kalsın (`insert` kökleri
        // artan indeksle ekliyor). Kısa yol, onu önek olarak paylaşan uzun
        // yoldan önce geliyor — yani bir aralığın terminalleri başta.
        let order = entries.indices.sorted { a, b in
            let x = entries[a].chars, y = entries[b].chars
            if x != y { return x.lexicographicallyPrecedes(y) }
            return a < b
        }

        // bound(n) = alt ağaçtaki en küçük L(kök) = aralığın en küçük maliyeti.
        func bound(_ r: Range<Int>) -> Double {
            var b = Double.infinity
            for i in r { b = min(b, entries[order[i]].cost) }
            return b
        }

        // BFS: düğüm = (sıralı aralık, derinlik, bound). Numara kuyruğa
        // girdiği anda veriliyor — eski kurulumdaki gibi.
        var queue: [(range: Range<Int>, depth: Int, bound: Double)] =
            [(0..<order.count, 0, bound(0..<order.count))]
        var qi = 0
        while qi < queue.count {
            let (range, depth, nodeBound) = queue[qi]
            // Kökün bound'u 0 kabul edilir → yol toplamı mutlak `L(kök)` olur
            // (form trie ile aynı sözleşme, §7.1).
            let parentBound = qi == 0 ? 0.0 : nodeBound
            qi += 1

            var i = range.lowerBound
            var nodeTerminals: [Terminal] = []
            while i < range.upperBound, entries[order[i]].chars.count == depth {
                let e = entries[order[i]]
                nodeTerminals.append(Terminal(rootIndex: e.root, variant: e.variant,
                                              extraCost: max(0, e.cost - nodeBound)))
                i += 1
            }
            while i < range.upperBound {
                let ch = entries[order[i]].chars[depth]
                var j = i + 1
                while j < range.upperBound, entries[order[j]].chars[depth] == ch { j += 1 }
                let childBound = bound(i..<j)
                arcSymbol.append(ch)
                arcTarget.append(UInt32(queue.count))
                arcDelta.append(max(0, childBound - parentBound))
                queue.append((i..<j, depth + 1, childBound))
                i = j
            }
            arcOffset.append(arcSymbol.count)
            terminals.append(contentsOf: nodeTerminals)
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
