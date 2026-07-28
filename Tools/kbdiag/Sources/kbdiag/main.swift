import Foundation
import KBGeometry
import KBSpatial
import KBLexicon
import KBDecoder

let layout = TurkishQ.layout()
let spatial = SpatialModel(layout: layout)
let w = ScoreWeights()

let counts: [String: Double] = [
    "kalem": 900, "işlem": 1500, "kalan": 700, "eklem": 180, "islem": 5,
    "kalemi": 300, "kalıp": 260, "ıslak": 120,
]
let entries = FormTrieBuilder.lexCosts(fromCounts: counts)
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
