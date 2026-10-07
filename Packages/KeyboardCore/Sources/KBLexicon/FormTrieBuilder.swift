import Foundation
import KBFoundation

/// Form trie üreticisi — `packbuilder`'ın Swift tarafı.
///
/// **Maliyet itme (§7.1):** paket **ham öznitelik deltalarını** iter, ağırlıklı
/// maliyeti değil. Böylece `w_lex` değişince paketin yeniden üretilmesi gerekmez.
///
/// İtme şeması:
/// - `bound(n)` = `n` düğümünün alt ağacındaki en küçük `L(w)`
/// - ark deltası `p → c` = `bound(c) − bound(p)`   (kök için `bound(kök) := 0`)
/// - terminal fazlası `n` = `L(w) − bound(n)`      (≥ 0)
///
/// Yol boyunca toplam = `bound(terminal) + fazla = L(w)`. Ark deltaları negatif
/// olmadığı için biriken maliyet her zaman o düğümden ulaşılabilir en iyi kelimenin
/// **admissible alt sınırıdır**.
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

    /// (I2) sonlanma invariantı parametreleri — skor sözleşmesi §2.5.
    ///
    /// `minOmissionCost + wLen + wLex · ΔF_lex_min > 0`
    ///
    /// `ΔF_lex_min` builder tarafından gerçek trie'den hesaplanır. Ağırlıklar
    /// `KBDecoder`'da yaşadığı için buraya düz sayı olarak geçirilir (modül
    /// bağımlılığı ters çevrilmesin diye).
    public struct TerminationInvariant {
        public let minOmissionCost: Double
        public let wLen: Double
        public let wLex: Double
        public init(minOmissionCost: Double, wLen: Double, wLex: Double) {
            self.minOmissionCost = minOmissionCost
            self.wLen = wLen
            self.wLex = wLex
        }
    }

    public enum BuildError: Error, CustomStringConvertible {
        case emptyInput
        case invalidCount(word: String, count: Double)
        case invalidLexCost(word: String, cost: Double)
        case multiScalarGrapheme(word: String, grapheme: String)
        case emptyWord
        case tooLong(word: String, length: Int, max: Int)
        case alphabetTooLarge(Int)
        case terminationInvariantViolated(minOmissionCost: Double, wLen: Double,
                                          wLex: Double, minLexDelta: Double, net: Double)

        public var description: String {
            switch self {
            case .emptyInput:
                return "boş girdi"
            case let .invalidCount(w, c):
                return "geçersiz frekans: '\(w)' = \(c) (sonlu ve pozitif olmalı)"
            case let .invalidLexCost(w, c):
                return "geçersiz leksikal maliyet: '\(w)' = \(c)"
            case let .multiScalarGrapheme(w, g):
                return "çok skalerli grapheme desteklenmiyor: '\(w)' içinde '\(g)' " +
                       "(sembol birimi Unicode skalerdir; NFC normalizasyonu sonrası tek skaler olmalı)"
            case .emptyWord:
                return "boş kelime"
            case let .tooLong(w, l, m):
                return "kelime çok uzun: '\(w)' \(l) karakter, sınır \(m) (I1)"
            case let .alphabetTooLarge(n):
                return "alfabe çok büyük: \(n)"
            case let .terminationInvariantViolated(om, len, lex, delta, net):
                return "(I2) sonlanma invariantı ihlal edildi: " +
                       "minOmissionCost=\(om) + wLen=\(len) + wLex=\(lex)·ΔF_lex_min=\(delta) = \(net) ≤ 0. " +
                       "Emisyon-only yolların net maliyeti pozitif olmalı (§2.5)."
            }
        }
    }

    private final class Node {
        var children: [UInt32: Node] = [:]   // anahtar: Unicode skaler değeri
        var isTerminal = false
        var lexCost: Double = .infinity
        var bound: Double = .infinity
    }

    public init() {}

    /// Frekanslardan ham leksikal maliyet üretir: `−log(count / total)`.
    /// Geçersiz sayımlarda hata fırlatır — `NaN`/`∞` sessizce bozuk paket üretmesin.
    public static func lexCosts(fromCounts counts: [String: Double]) throws -> [Entry] {
        guard !counts.isEmpty else { throw BuildError.emptyInput }
        for (w, c) in counts {
            guard c.isFinite, c > 0 else { throw BuildError.invalidCount(word: w, count: c) }
        }
        let total = counts.values.reduce(0, +)
        guard total.isFinite, total > 0 else { throw BuildError.emptyInput }
        return counts.map { Entry(word: $0.key, lexCost: -log($0.value / total)) }
            .sorted { $0.word < $1.word }
    }

    /// Trie'yi kurar ve binary'ye serileştirir.
    ///
    /// - Parameter termination: verildiğinde (I2) invariantı gerçek `ΔF_lex_min`
    ///   üzerinden denetlenir ve ihlalde **üretim başarısız olur** (§2.5).
    public func build(entries: [Entry],
                      maxSurfaceLen: Int = LexiconLimits.maxSurfaceLength,
                      termination: TerminationInvariant? = nil) throws -> (bytes: [UInt8], alphabet: [Unicode.Scalar]) {
        guard !entries.isEmpty else { throw BuildError.emptyInput }

        // Sembol birimi **Unicode skalerdir**. NFC sonrası hâlâ çok skalerli olan
        // grapheme'ler sessizce bozulmasın diye açıkça reddedilir (§7 kanonik kimlik).
        var scalarSet = Set<UInt32>()
        var normalized: [(scalars: [UInt32], lexCost: Double)] = []
        for e in entries {
            guard e.lexCost.isFinite else {
                throw BuildError.invalidLexCost(word: e.word, cost: e.lexCost)
            }
            let nfc = e.word.precomposedStringWithCanonicalMapping
            guard !nfc.isEmpty else { throw BuildError.emptyWord }
            for g in nfc {
                guard g.unicodeScalars.count == 1 else {
                    throw BuildError.multiScalarGrapheme(word: e.word, grapheme: String(g))
                }
            }
            let scalars = nfc.unicodeScalars.map(\.value)
            guard scalars.count <= maxSurfaceLen else {
                throw BuildError.tooLong(word: e.word, length: scalars.count, max: maxSurfaceLen)
            }
            scalarSet.formUnion(scalars)
            normalized.append((scalars, e.lexCost))
        }

        let alphabet = ScalarAlphabet(scalarSet)
        guard alphabet.count <= Int(UInt16.max) else {
            throw BuildError.alphabetTooLarge(alphabet.count)
        }

        // Trie kurulumu.
        let root = Node()
        for (scalars, cost) in normalized {
            var cur = root
            for v in scalars {
                if let next = cur.children[v] {
                    cur = next
                } else {
                    let n = Node()
                    cur.children[v] = n
                    cur = n
                }
            }
            // Aynı yüzey birden çok kez gelirse en ucuzu kalır (tek sahiplik, §7).
            cur.isTerminal = true
            cur.lexCost = min(cur.lexCost, cost)
        }

        computeBounds(root)

        // Düğümleri BFS ile numaralandır — 0 = kök.
        var nodes: [Node] = [root]
        var indexOf: [ObjectIdentifier: UInt32] = [ObjectIdentifier(root): 0]
        var qi = 0
        while qi < nodes.count {
            let n = nodes[qi]; qi += 1
            for v in n.children.keys.sorted() {
                let c = n.children[v]!
                indexOf[ObjectIdentifier(c)] = UInt32(nodes.count)
                nodes.append(c)
            }
        }

        // CSR arkları.
        var arcOffset: [UInt32] = [0]
        var arcSymbol: [UInt16] = []
        var arcTarget: [UInt32] = []
        var arcLexDelta: [Float] = []
        var nodeFlags: [UInt8] = []
        var nodeTermExtra: [Float] = []
        var minPositiveArcDelta = Double.infinity

        for n in nodes {
            // Kökün bound'u 0 kabul edilir; böylece yol toplamı **mutlak** `L(w)` olur.
            // (Kökü kendi bound'una eşitlemek tüm `L(w)`'leri sabit kaydırırdı ve
            // uzamsal/edit öznitelikleri kaymadığı için terimler arası ölçeği bozardı.)
            let parentBound = (n === root) ? 0.0 : n.bound
            for v in n.children.keys.sorted() {
                let c = n.children[v]!
                arcSymbol.append(alphabet.symbolOf[v]!)
                arcTarget.append(indexOf[ObjectIdentifier(c)]!)
                let delta = c.bound - parentBound
                precondition(delta >= -1e-9, "maliyet itme negatif delta üretti: \(delta)")
                let d = max(0, delta)
                arcLexDelta.append(Float(d))
                minPositiveArcDelta = min(minPositiveArcDelta, d)
            }
            arcOffset.append(UInt32(arcSymbol.count))
            nodeFlags.append(n.isTerminal ? 1 : 0)
            nodeTermExtra.append(n.isTerminal ? Float(max(0, n.lexCost - n.bound)) : 0)
        }

        // (I2) — gerçek ΔF_lex_min üzerinden, üretim zamanında (§2.5).
        if let t = termination {
            let deltaMin = minPositiveArcDelta.isFinite ? minPositiveArcDelta : 0
            let net = t.minOmissionCost + t.wLen + t.wLex * deltaMin
            guard net > 0 else {
                throw BuildError.terminationInvariantViolated(
                    minOmissionCost: t.minOmissionCost, wLen: t.wLen,
                    wLex: t.wLex, minLexDelta: deltaMin, net: net)
            }
        }

        // Serileştirme.
        let format = FormTrieFormat.container
        var w = format.writer { w in
            w.u16(0)                                  // flags
            w.u32(UInt32(nodes.count))
            w.u32(UInt32(arcSymbol.count))
            w.u16(UInt16(alphabet.count))
            w.u16(UInt16(maxSurfaceLen))
            w.u32(0)                                  // reserved
        }
        w.alphabet(alphabet.values)
        for v in arcOffset { w.u32(v) }
        for v in arcSymbol { w.u16(v) }
        for v in arcTarget { w.u32(v) }
        for v in arcLexDelta { w.f32(v) }
        for v in nodeFlags { w.u8(v) }
        for v in nodeTermExtra { w.f32(v) }

        return (format.seal(w), alphabet.scalars)
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
