import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder
import KBMorphology

let layout = TurkishQ.layout()
let spatial = SpatialModel(layout: layout)
let w = ScoreWeights()

let counts: [String: Double] = [
    "kalem": 900, "işlem": 1500, "kalan": 700, "eklem": 180, "islem": 5,
    "kalemi": 300, "kalıp": 260, "ıslak": 120,
]
let entries = try FormTrieBuilder.lexCosts(fromCounts: counts)
let (bytes, _) = try FormTrieBuilder().build(entries: entries)
_ = try FormTrie(bytes: bytes)
let oracle = Oracle(layout: layout, spatial: spatial, weights: w)

func touches(_ s: String) -> [TouchSample] {
    s.enumerated().map { i, ch in
        TouchSample(down: layout.keys[layout.keyIndex(for: ch)!].center, timestamp: Double(i) * 0.15)
    }
}

let t = touches("lslem")
print("=== 'lslem' dokunma dizisi ===")
print("kelime       toplam      F_lex      kanal")
for e in entries.sorted(by: { oracle.cost(word: $0.word, touches: t, lexCost: $0.lexCost)
                            < oracle.cost(word: $1.word, touches: t, lexCost: $1.lexCost) }) {
    let total = oracle.cost(word: e.word, touches: t, lexCost: e.lexCost)
    let lex = w.wLex * e.lexCost
    print(e.word.padding(toLength: 12, withPad: " ", startingAt: 0)
          + String(format: "%8.3f   %8.3f   %8.3f", total, lex, total - lex))
}

print("\n=== Tuş bazlı uzamsal maliyet ===")
func spa(_ typed: Character, _ target: Character) {
    let tt = TouchSample(down: layout.keys[layout.keyIndex(for: typed)!].center)
    let direct = spatial.negLogP(tt, keyIndex: layout.keyIndex(for: target)!)
    var line = "\(typed)→\(target)  doğrudan=" + String(format: "%8.3f", direct)
    if let b = layout.asciiBaseKeyIndex(for: target) {
        let eq = w.wSpaEq * spatial.negLogP(tt, keyIndex: b) + w.wEq
        line += "  eşdeğerlik=" + String(format: "%8.3f", eq)
             + "  min=" + String(format: "%8.3f", min(direct, eq))
    }
    print(line)
}
spa("l", "k"); spa("s", "a"); spa("l", "i"); spa("s", "ş")

// MARK: - -1A₂ state şeması ölçümü

let spikeRoots: [Root] = [
    Root("kitap", pos: .noun, lexCost: 4.0, finalAlternation: .pToB),
    Root("kalem", pos: .noun, lexCost: 4.2),
    Root("çocuk", pos: .noun, lexCost: 4.4, finalAlternation: .kToĞ),
    Root("renk",  pos: .noun, lexCost: 5.2, finalAlternation: .kToG),
    Root("burun", pos: .noun, lexCost: 5.6, dropsVowel: true),
    Root("gel",   pos: .verb, lexCost: 4.0),
]
let morph = MorphologyAutomaton(roots: spikeRoots)

print("\n=== -1A₂ düğüm şeması: ölçülen bit genişlikleri ===")
func report(_ name: String, _ l: MorphologyNodeLayout) {
    print("""
    \(name)
      \(l.breakdown)
      UInt32'ye sığar mı: \(l.fitsInUInt32 ? "EVET" : "HAYIR")
      TAM dedup anahtarı: \(DecoderKeyLayout.total(nodeBits: l.total)) bit
    """)
}
report("spike (\(spikeRoots.count) kök)", morph.nodeLayout)
report("ÜRETİM tahmini (Faz 4)", MorphologyNodeLayout.productionEstimate)

let reach = morph.reachableStates(maxSurfaceLen: 10)
var packed = Set<UInt64>()
for st in reach { if let p = st.packed(morph.nodeLayout) { packed.insert(p) } }
print("  erişilebilir durum: \(reach.count) · benzersiz paketlenmiş: \(packed.count) · çakışma: \(reach.count - packed.count)")

print("\n=== türetilen formlar ===")
for name in ["kitap", "çocuk", "renk", "burun"] {
    let i = spikeRoots.firstIndex { String($0.surface) == name }!
    let forms = (try? morph.generate(rootIndex: i, maxSuffixes: 1)) ?? []
    let uniq = Set(forms.map(\.surface)).sorted()
    print("  \(name) → \(uniq.joined(separator: ", "))")
}
