import Testing
import Foundation
@testable import KBMorphology

/// `MAX_SURFACE_LEN = 40` yeterli mi — §9'un açık sorusu, ölçülüyor.
///
/// ## Soru neden önemli
///
/// Sınır yalnız paket kurma anında değil **kod çözme anında** da bağlıyor
/// (`Decoder`: `emitCount < lexicon.maxSurfaceLen`). Sınırı aşan bir yüzey
/// pakete girmiyorsa reddediliyor (I1, `BuildError.tooLong`); morfolojiden
/// türetiliyorsa hiç üretilemiyor. İkisi de "kullanıcı bu kelimeyi yazamıyor"
/// demek, ve ikincisi sessiz.
///
/// ## Ne ölçülüyor
///
/// İki bağımsız üst sınır:
///
/// 1. **Liste yüzeyleri** — depodaki form listelerinin gerçek dağılımı.
/// 2. **Türetilmiş yüzeyler** — en uzun kök + morfotaktik grafın izin verdiği
///    en uzun ek zinciri. Bu bir örneklem değil **yapısal** sınır: graf
///    çevrimsizse daha uzunu üretilemez.
///
/// ## Testin asıl işi ileride
///
/// Bugünkü graf bilinçli olarak dar (`TurkishMorphotactics` kapsam matrisi:
/// tam graf ~200 morfem, Faz 4). Yani bugünkü "evet" **tam Türkçe hakkında
/// kanıt değil**. Test tam da bu yüzden yazıldı: graf büyüdüğünde tekrar
/// koşacak ve sınır aşılırsa kırılacak. Açık soruyu kapatan şey bir cevap
/// değil, cevabın bayatladığını haber veren bir bekçi.
@Suite("Yüzey uzunluk sınırı (§9)")
struct SurfaceLengthBoundTests {

    private static var packRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // KeyboardCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // KeyboardCore
            .deletingLastPathComponent()          // Packages
            .deletingLastPathComponent()          // repo kökü
            .appendingPathComponent("LanguagePacks")
    }

    /// TSV'nin ilk sütunundaki en uzun yüzey — NFC normalize, **skalar** sayımı.
    ///
    /// Sayım birimi `FormTrieBuilder`'ınkiyle aynı olmalı: `Character`
    /// (grapheme cluster) ile saymak birleşik `i̇` gibi dizileri tek karakter
    /// sayar ve trie'nin reddedeceği bir yüzeyi geçmiş gösterirdi.
    private func longestSurface(in file: URL) throws -> (length: Int, word: String,
                                                         count: Int)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var best = (length: 0, word: "", count: 0)
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            guard let w = line.split(separator: "\t").first, !w.isEmpty else { continue }
            let n = String(w).precomposedStringWithCanonicalMapping.unicodeScalars.count
            best.count += 1
            if n > best.length { best.length = n; best.word = String(w) }
        }
        return best.count > 0 ? best : nil
    }

    /// Depodaki form listeleri ve kök sözlüğü sınırın **çok** altında.
    ///
    /// Ölçüm (2026-08-01): tr 70 009 form → en uzun 22 (`gerçekleştirilmektedir`),
    /// en 60 000 form → 21, tr 30 041 kök → 21 (`erkanıharbiyeiumumiye`).
    @Test("Liste yüzeyleri sınırın altında")
    func listedSurfacesFitUnderTheLimit() throws {
        let files = ["tr-TR/wordlist.tsv", "en-US/wordlist.tsv", "tr-TR/roots.tsv"]
        var measured = 0
        for name in files {
            let url = Self.packRoot.appendingPathComponent(name)
            // Paket ağacı yoksa test **atlanıyor**: dosyanın yokluğu bir ölçüm
            // sonucu değil. `0` kabul etmek sınırı sınamadan geçmek olurdu.
            guard let r = try longestSurface(in: url) else { continue }
            measured += 1
            #expect(r.length <= TurkishMorphotactics.maxSurfaceLen,
                    "\(name): \(r.word) (\(r.length)) sınırı aşıyor")
        }
        #expect(measured > 0, "hiçbir liste okunamadı — ölçüm yapılmadı")
    }

    /// Morfotaktik graf **çevrimli** — ve bu doğru olan.
    ///
    /// ## Bu test tersine döndü
    ///
    /// Eskiden "graf çevrimsiz olmalı" diyordu ve `-ki` eklenince kırıldı.
    /// Kırılma bir regresyon değil, **beklenen olay**: eski hâli bunu zaten
    /// haber veriyordu ("Faz 4'ün türetim ekleri tam da çevrim adayı").
    ///
    /// Çevrim Türkçe'nin kendisinde: `evde → evdeki → evdekiler →
    /// evdekilerin → evdekilerinki → …` ilkece sınırsız. TRmorph da `-ki`
    /// yinelemesi yüzünden Türkçe kelime uzunluğunun ilkece sınırsız
    /// olduğunu kaydediyor.
    ///
    /// Test şimdi çevrimin **var olduğunu** sabitliyor. Sebebi ters yönde bir
    /// koruma: çevrim kazara kaybolursa (`-ki`'nin hedefi bir gün yanlışlıkla
    /// terminal bir duruma çevrilirse) `evdekiler` sessizce üretilemez hâle
    /// gelir ve kimse fark etmez.
    @Test("Morfotaktik graf çevrimli — ilgi eki yinelenebiliyor")
    func morphotacticGraphIsCyclicByDesign() {
        let c = Self.cycle(from: .nounRoot)
        #expect(c != nil, """
            isim tarafında çevrim kalmamış. `-ki` bir yere bağlanmayı bıraktıysa \
            `evdekiler` üretilemez — §8.12 yeniden okunmalı.
            """)
        // Fiil tarafı da çevrimli: yeterlilik, ettirgen ve edilgen yeni bir
        // **fiil gövdesi** üretiyor (`çalış → çalıştır → çalıştırıl`), yani
        // `verbRoot`'a dönüyorlar. Türkçe burada da gerçekten çevrimli —
        // `yaptırttır` dilbilgisel.
        #expect(Self.cycle(from: .verbRoot) != nil, """
            fiil tarafında çevrim kalmamış. Çatı ekleri `verbRoot`'a dönmüyorsa \
            `çalıştırabilmiş` üretilemez.
            """)
    }

    /// `maxSurfaceLen` artık **dilbilgisel değil, bütçe**.
    ///
    /// ## Anlamı neden değişti
    ///
    /// Eski test "en uzun kök + grafın izin verdiği en uzun ek zinciri" diye
    /// yapısal bir üst sınır kuruyordu. O hesap çevrimsizliğe dayanıyordu ve
    /// çevrim gerçek olunca **tanımsızlaştı**: `evdekilerinkiler…` istediğin
    /// kadar uzayabiliyor.
    ///
    /// Sınır kalkmadı, anlamı değişti: artık decoder'ın emisyon bütçesi
    /// (`emitCount < maxSurfaceLen`). Dilbilgisi değil, bellek ve beam koruması.
    /// Bütçeyi aşan form üretilemez — bu bir eksiklik değil bilinçli kapak, ve
    /// listede duran her yüzeyin altında kalması **hâlâ** zorunlu (aşağıdaki
    /// liste testi onu sınıyor).
    ///
    /// Burada sınanan: bütçenin gerçekten bağlayıcı olduğu ve dilin en uzun
    /// *gerçekçi* formlarına yer bıraktığı. Ölçülen en uzun liste yüzeyi 22
    /// (`gerçekleştirilmektedir`), en uzun kök 21 — ikisi de 40'ın altında.
    @Test("Uzunluk bütçesi bağlayıcı ve gerçekçi formlara yer bırakıyor")
    func lengthBudgetIsBindingAndRoomy() throws {
        let roots = Self.packRoot.appendingPathComponent("tr-TR/roots.tsv")
        guard let longestRoot = try longestSurface(in: roots) else { return }

        #expect(longestRoot.length < TurkishMorphotactics.maxSurfaceLen,
                "en uzun kök (\(longestRoot.word)) bütçeye sığmıyor")

        // Bütçe, en uzun kökün üstüne **anlamlı** bir ek zinciri payı
        // bırakmalı. Sayı dilbilgisinden değil gözlemden: üretim listesindeki
        // en uzun yüzey 22 karakter ve tipik uzun çekimler (`kalemlerimizden`)
        // kökün üstüne 8-10 karakter ekliyor.
        let headroom = TurkishMorphotactics.maxSurfaceLen - longestRoot.length
        #expect(headroom >= 12, """
            uzun kök (\(longestRoot.word), \(longestRoot.length)) için ek payı \
            yalnız \(headroom) karakter. Bütçe ya da kök listesi değiştiyse \
            §8.12 yeniden okunmalı.
            """)
    }

    // MARK: - Graf yürüyüşü

    private static var graph: [Continuation: [Suffix]] {
        Dictionary(grouping: TurkishMorphotactics.suffixes, by: \.from)
    }

    /// Bir durumdan ulaşılabilen çevrim; yoksa `nil`.
    private static func cycle(from start: Continuation) -> [Continuation]? {
        let g = graph
        var onPath: [Continuation] = []
        var settled: Set<Continuation> = []

        func walk(_ u: Continuation) -> [Continuation]? {
            if let i = onPath.firstIndex(of: u) { return Array(onPath[i...]) + [u] }
            if settled.contains(u) { return nil }
            onPath.append(u)
            defer { onPath.removeLast(); settled.insert(u) }
            for s in g[u] ?? [] {
                if let c = walk(s.to) { return c }
            }
            return nil
        }
        return walk(start)
    }

    /// Bir durumdan üretilebilecek **en uzun** ek zincirinin karakter sayısı.
    ///
    /// Çevrimsizlik `morphotacticGraphIsAcyclic` ile ayrıca sınanıyor; burada
    /// `settled` yalnız tekrar hesabı önlüyor.
    private static func longestChain(from start: Continuation) -> Int {
        let g = graph
        var memo: [Continuation: Int] = [:]

        func best(_ u: Continuation) -> Int {
            if let m = memo[u] { return m }
            memo[u] = 0                     // çevrim olsa bile sonlanır
            var b = 0
            for s in g[u] ?? [] {
                b = max(b, s.pieces.count + best(s.to))
            }
            memo[u] = b
            return b
        }
        return best(start)
    }
}
