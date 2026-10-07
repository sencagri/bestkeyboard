import Testing
import Foundation
import KBDecoder
import KBGeometry
import KBLexicon
import KBSpatial

@Suite("Paket üretimi — girdi ve invariant doğrulaması")
struct BuilderValidationTests {

    /// Sözleşme §2.5: "(I2) paket üretim zamanında denetlenir; sağlanmıyorsa
    /// üretim başarısız olur." Yardımcı Boolean'ı test etmek yetmez — `build`
    /// gerçekten reddetmeli.
    @Test("(I2) ihlali paket üretimini BAŞARISIZ kılar")
    func terminationEnforcedAtBuild() throws {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: TestLexicon.counts)
        let w = ScoreWeights()

        let ok = FormTrieBuilder.TerminationInvariant(
            minOmissionCost: min(w.wOmGem, min(w.wOmInit, w.wOm)),
            wLen: w.wLen, wLex: w.wLex)
        #expect(throws: Never.self) {
            _ = try FormTrieBuilder().build(entries: entries, termination: ok)
        }

        // Aşırı negatif w_len → emisyon-only yolun net maliyeti ≤ 0 → reddedilmeli.
        let bad = FormTrieBuilder.TerminationInvariant(
            minOmissionCost: 2.0, wLen: -10, wLex: 1)
        #expect(throws: FormTrieBuilder.BuildError.self) {
            _ = try FormTrieBuilder().build(entries: entries, termination: bad)
        }
    }

    @Test("Geçersiz frekanslar reddedilir (NaN, sıfır, negatif, sonsuz)")
    func invalidCounts() {
        for bad: Double in [Double.nan, 0, -1, .infinity] {
            #expect(throws: FormTrieBuilder.BuildError.self) {
                _ = try FormTrieBuilder.lexCosts(fromCounts: ["a": 1, "b": bad])
            }
        }
    }

    /// Sembol birimi Unicode skalerdir. NFC sonrası hâlâ çok skalerli olan
    /// grapheme'ler sessizce ilk skalere indirgenmemeli — reddedilmeli (§7).
    @Test("Çok skalerli grapheme sessizce bozulmaz, reddedilir")
    func multiScalarGrapheme() {
        let combining = "e" + "\u{0301}" + "\u{0327}"   // e + acute + cedilla
        #expect(combining.count == 1, "tek grapheme cluster olmalı")
        #expect(combining.unicodeScalars.count > 1, "NFC bunu tek skalere indiremez")
        #expect(throws: FormTrieBuilder.BuildError.self) {
            _ = try FormTrieBuilder().build(
                entries: [FormTrieBuilder.Entry(word: combining, lexCost: 1.0)])
        }
    }

    @Test("maxSurfaceLen aşımı sessizce atılmaz, reddedilir (I1)")
    func tooLong() {
        let long = String(repeating: "a", count: 50)
        #expect(throws: FormTrieBuilder.BuildError.self) {
            _ = try FormTrieBuilder().build(
                entries: [FormTrieBuilder.Entry(word: long, lexCost: 1.0)], maxSurfaceLen: 40)
        }
    }

    @Test("Boş girdi reddedilir")
    func emptyInput() {
        #expect(throws: FormTrieBuilder.BuildError.self) {
            _ = try FormTrieBuilder.lexCosts(fromCounts: [:])
        }
        #expect(throws: FormTrieBuilder.BuildError.self) {
            _ = try FormTrieBuilder().build(entries: [])
        }
    }
}

@Suite("Paket okuma — yapısal doğrulama")
struct TrieStructureTests {

    /// Checksum'ı geçerli **ama yapısı bozuk** paket üretir. Sıcak yol erişimleri
    /// init'in doğrulamasına güvendiği için bu invariantlar init'te yakalanmalı;
    /// aksi halde dizi taşması veya sonsuz döngü oluşur.
    private func corruptedPack(_ transform: (inout [UInt8]) -> Void) throws -> [UInt8] {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: ["ab": 10, "ac": 5, "b": 3])
        var (bytes, _) = try FormTrieBuilder().build(entries: entries)
        transform(&bytes)
        // Checksum'ı yeniden hesapla ki sınanan şey yapısal kontrol olsun.
        let h = FNV1a.hash(bytes[FormTrieFormat.container.headerSize...])
        for i in 0..<8 { bytes[24 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        return bytes
    }

    private func arcOffsetBase(_ bytes: [UInt8]) throws -> Int {
        let alphabetSize = Int(try ByteReader(bytes).u16(16))
        return FormTrieFormat.container.headerSize + alphabetSize * 4
    }

    @Test("Monoton olmayan arcOffset reddedilir")
    func nonMonotoneOffsets() throws {
        let base = try arcOffsetBase(
            try FormTrieBuilder().build(
                entries: try FormTrieBuilder.lexCosts(fromCounts: ["ab": 10, "ac": 5, "b": 3])).bytes)
        let bytes = try corruptedPack { b in
            // arcOffset[1] = 0xFFFF
            b[base + 4] = 0xFF; b[base + 5] = 0xFF; b[base + 6] = 0; b[base + 7] = 0
        }
        #expect(throws: (any Error).self) { _ = try FormTrie(bytes: bytes) }
    }

    @Test("Sınır dışı sembol reddedilir")
    func symbolOutOfRange() throws {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: ["ab": 10, "ac": 5, "b": 3])
        let built = try FormTrieBuilder().build(entries: entries)
        let r = ByteReader(built.bytes)
        let alphabetSize = Int(try r.u16(16))
        let nodeCount = Int(try r.u32(8))
        let offArcSymbol = FormTrieFormat.container.headerSize + alphabetSize * 4 + (nodeCount + 1) * 4
        let bytes = try corruptedPack { b in
            b[offArcSymbol] = 0xFF; b[offArcSymbol + 1] = 0xFF   // sembol = 65535
        }
        #expect(throws: (any Error).self) { _ = try FormTrie(bytes: bytes) }
    }

    @Test("Bozuk checksum reddedilir")
    func badChecksum() throws {
        let entries = try FormTrieBuilder.lexCosts(fromCounts: ["ab": 10, "ac": 5])
        var (bytes, _) = try FormTrieBuilder().build(entries: entries)
        bytes[FormTrieFormat.container.headerSize + 4] ^= 0xFF
        #expect(throws: (any Error).self) { _ = try FormTrie(bytes: bytes) }
    }

    @Test("Sağlam paket açılır ve invariantları geçer")
    func healthy() throws {
        let (trie, _) = try TestLexicon.trie()
        #expect(trie.nodeCount > 0)
        #expect(trie.lookup("kalem") != nil)
        // Yapısal invariant: her ark hedefi kaynaktan ileride (çevrim yok → I1).
        for node in 0..<UInt32(trie.nodeCount) {
            for arc in trie.arcRange(node) {
                #expect(trie.arcTarget(arc) > node)
            }
        }
    }
}
