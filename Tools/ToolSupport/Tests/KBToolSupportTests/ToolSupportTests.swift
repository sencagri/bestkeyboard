import Foundation
import Testing
import KBGeometry
import KBToolSupport

@Suite("Araç ortak kodu")
struct ToolSupportTests {

    @Test("Yüzdelik ⌊n·p⌋ indeksi, sona kırpılmış; boşta NaN")
    func percentiles() {
        let v = (1...10).map(Double.init)
        #expect(percentile(v, 0.0) == 1)
        #expect(percentile(v, 0.5) == 6)       // ⌊10·0.5⌋ = 5 → 6
        #expect(percentile(v, 0.99) == 10)
        #expect(percentile(v, 1.0) == 10)      // kırpılmış
        #expect(percentile([], 0.5).isNaN)
    }

    @Test("Dolgu grapheme sayısına göre — Türkçe karakter tek sütun")
    func padding() {
        #expect(pad("şü", 4) == "şü  ")
        #expect(lpad("ğ", 3) == "  ğ")
        #expect(pad("uzun", 2) == "uzun")
    }

    @Test("TSV: yorum ve boş satır atlanır, satır numarası fiziksel")
    func tsvRecords() {
        let text = "# başlık\nkalem\t12\n\n  ev\t3  \nbozuk\nçift\t\t5\n"
        let r = TSV.records(text)
        #expect(r.map(\.line) == [2, 4, 5, 6])
        #expect(r[1].text == "ev\t3")
        #expect(TSV.wordCount(r[0])! == ("kalem", 12))
        #expect(TSV.wordCount(r[2]) == nil)
        // Boş alan varsayılan olarak atılıyor; korunması istenirse kayıyor.
        #expect(TSV.wordCount(r[3])! == ("çift", 5))
        #expect(TSV.records(text, keepingEmptyFields: true)[3].fields.count == 3)
    }

    @Test("Spike kökleri: alt küme ana sırayı koruyor")
    func spikeRoots() {
        let names = SpikeRoots.named(["gel", "kitap", "burun"]).map { String($0.surface) }
        #expect(names == ["kitap", "burun", "gel"])
        #expect(SpikeRoots.all.count == 8)
    }

    @Test("Temiz simülatör: edit olayı ve kalın kuyruk yok, tohum belirleyici")
    func cleanSimulator() {
        let layout = TurkishQ.layout()
        let s = TouchSimulator.clean(layout: layout, seed: 7, sigmaScale: 0.12)
        #expect(s.omissionRate == 0 && s.insertionRate == 0
                && s.transpositionRate == 0 && s.heavyTailRate == 0)
        #expect(s.sigmaScale == 0.12)

        var a = TouchSimulator.clean(layout: layout, seed: 7, sigmaScale: 0.12)
        var b = TouchSimulator.clean(layout: layout, seed: 7, sigmaScale: 0.12)
        let ta = a.touches(for: "kalem")!, tb = b.touches(for: "kalem")!
        #expect(ta.count == 5)
        #expect(zip(ta, tb).allSatisfy { $0.down == $1.down && $0.timestamp == $1.timestamp })
    }

    @Test("SplitMix64: aynı tohum aynı dizi, [0,1) aralığı")
    func splitMix() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        let xs = (0..<100).map { _ in a.nextDouble() }
        #expect(xs == (0..<100).map { _ in b.nextDouble() })
        #expect(xs.allSatisfy { $0 >= 0 && $0 < 1 })
    }
}
