import Foundation

/// Sözlük dışı token'lar için karakter n-gram modeli — skor sözleşmesi §0'daki
/// **açık-vocabulary literal kanalı**.
///
/// ## Neden var
///
/// Commit kararı `Δ = cost(literal) − cost(bestCandidate)`. Literal hiçbir
/// otomatta kabul edilmiyorsa `cost(literal)` tanımsız kalır ve karar **tam da
/// en çok önemli olduğu yerde** — bilinmeyen kelimede, kod parçasında, yeni bir
/// isimde — anlamsızlaşır. Sözleşmenin kuralı:
///
/// ```
/// w ∈ V  →  F_lex(w) = kanonik leksikal maliyet
/// w ∉ V  →  F_lex(w) = w_unk + F_char-ngram(w | OOV)
/// ```
///
/// Aynı yüzey **asla iki kanaldan birden** maliyet almaz (tek sahiplik).
///
/// ## Neden yoğun tablo, hash değil
///
/// Türkçe alfabesi 29 harf; sınır ve alfabe-dışı sembolleriyle birlikte 31.
/// Üçlü tablo `31³ = 29 791` giriş, girişi 2 bayt → **58 KB**. Bu boyutta
/// minimal perfect hash kurmak (§6'da kelime bigramı için gerekli) hem gereksiz
/// hem daha yavaş: burada arama tek bir dizi indekslemesi.
///
/// Geri çekilme (backoff) **çalışma anında yok**: interpolasyon paket
/// üretiminde yapılıp nihai `−log P` tabloya yazılıyor. Çalışma anında yapılan
/// tek iş çarpma-toplama-indeksleme.
///
/// ## Ne üzerinde eğitiliyor
///
/// Kelime listesinin **tipleri** üzerinde, sıklıkla ağırlıklandırmadan.
/// Modellediğimiz şey "görülmemiş bir token neye benzer" — görülmemiş token'lar
/// tip dağılımından gelir, token dağılımından değil. Sıklıkla ağırlıklandırmak
/// modeli en sık birkaç yüz kelimenin şekline büker.
public struct CharNGram: Sendable {

    /// Alfabe karakterleri (kod noktası sırasında).
    public let alphabet: [Unicode.Scalar]
    /// Kuantize `−log P(c | h₁, h₂)`, `S³` giriş; `S = alphabet.count + 2`.
    private let table: [UInt16]
    private let symbolOf: [UInt32: UInt16]

    /// Alfabe dışı karakter başına sabit maliyet (§0 `w_oov-char`).
    public let wOovChar: Double
    /// Uzunluk sınırından sonraki karakter başına sabit maliyet (§0 `w_tail`).
    public let wTail: Double
    /// Bu uzunluğa kadar n-gram ile skorlanır; ötesi `w_tail` ve token
    /// **literal korumaya** düşer (`θ = ∞`).
    public let maxScoredLength: Int

    /// `−log P` kuantizasyon ölçeği. 1024 → çözünürlük ~0.001 nat, tavan 64 nat.
    /// Gerçek değerler tekdüze geri çekilme tabanı yüzünden ~15 natın altında.
    static let quantScale: Double = 1024

    /// Sınır (BOS/EOS) sembolü.
    var boundarySymbol: UInt16 { UInt16(alphabet.count) }
    /// Alfabe dışı karakterlerin ortak sembolü.
    var oovSymbol: UInt16 { UInt16(alphabet.count + 1) }
    /// Alfabe + sınır + OOV. Tablo `S³` giriş.
    public var symbolCount: Int { alphabet.count + 2 }

    init(alphabet: [Unicode.Scalar], table: [UInt16],
         wOovChar: Double, wTail: Double, maxScoredLength: Int) {
        self.alphabet = alphabet
        self.table = table
        self.wOovChar = wOovChar
        self.wTail = wTail
        self.maxScoredLength = maxScoredLength
        var m = [UInt32: UInt16](minimumCapacity: alphabet.count * 2)
        for (i, s) in alphabet.enumerated() { m[s.value] = UInt16(i) }
        self.symbolOf = m
    }

    // MARK: - Skorlama

    public struct Score: Equatable, Sendable {
        /// `F_char-ngram(w | OOV)` — `w_unk` **dahil değil**, onu çağıran ekler.
        public var cost: Double
        /// Token uzunluk sınırını aştı: `θ = ∞` uygulanmalı (§0 taşma kuralı).
        public var overflowed: Bool
    }

    /// Token'ın karakter maliyeti.
    ///
    /// **Her sonlu Unicode token'ı sonlu maliyet alır** — alfabe dışı karakter,
    /// emoji, kontrol karakteri, sınırı aşan uzunluk dahil. Bu bir test kapısı:
    /// sonsuz dönen tek bir yol commit kararını kilitler.
    public func score(_ token: String) -> Score {
        guard !token.isEmpty else { return Score(cost: 0, overflowed: false) }

        var h1 = boundarySymbol
        var h2 = boundarySymbol
        var cost = 0.0
        var n = 0

        for ch in token {
            n += 1
            if n > maxScoredLength { cost += wTail; continue }

            guard let scalar = ch.unicodeScalars.first,
                  ch.unicodeScalars.count == 1,
                  let sym = symbolOf[scalar.value] else {
                // Alfabe dışı: sabit maliyet, bağlam OOV sembolüne kayar.
                // Bağlamı sıfırlamamak önemli — `a😀b`'deki `b` kelime başı
                // gibi puanlanmamalı.
                cost += wOovChar
                h1 = h2; h2 = oovSymbol
                continue
            }
            cost += negLogP(sym, h1, h2)
            h1 = h2; h2 = sym
        }

        if n <= maxScoredLength { cost += negLogP(boundarySymbol, h1, h2) }
        return Score(cost: cost, overflowed: n > maxScoredLength)
    }

    func negLogP(_ c: UInt16, _ h1: UInt16, _ h2: UInt16) -> Double {
        let S = symbolCount
        let idx = (Int(h1) * S + Int(h2)) * S + Int(c)
        return Double(table[idx]) / Self.quantScale
    }

    /// Paket yazımı için ham kuantize giriş.
    func rawTableEntry(_ index: Int) -> UInt16 { table[index] }
}

// MARK: - Eğitim

public enum CharNGramBuilder {

    /// Kelime tiplerinden interpolasyonlu üçlü model kurar.
    ///
    /// Witten–Bell interpolasyonu: `λ = c(h) / (c(h) + u(h))`, `u(h)` = `h`
    /// bağlamında görülen farklı devam sayısı. Sabit `c(h)` için **çok** farklı
    /// devamı olan bağlam `λ`'yı düşürür, yani geri çekilmeye daha çok ağırlık
    /// verir: çeşitlilik "bir sonraki karakter yine yeni olabilir" demektir.
    /// Katsayı ayarlaması gerektirmediği için paket üretiminde güvenli.
    ///
    /// - Parameter words: kelime **tipleri**; sıklık kasıtlı olarak kullanılmaz.
    /// - Throws: boş eğitim kümesinde `BuildError.emptyTrainingSet`,
    ///   kuantizasyon taşmasında `BuildError.quantizationOverflow`.
    ///   Bellek modeli ile paket okuyucunun **aynı** şeyi reddetmesi şart:
    ///   yoksa builder çalışan bir model üretip paket onu reddediyordu.
    public enum BuildError: Error, CustomStringConvertible {
        case emptyTrainingSet
        case quantizationOverflow(maxNats: Double)

        public var description: String {
            switch self {
            case .emptyTrainingSet:
                return "eğitim kümesi boş (ya da yalnız boş dizeler)"
            case let .quantizationOverflow(m):
                return "kuantizasyon taşması: \(m) nat, tavan 64 nat"
            }
        }
    }

    public static func build(words: [String],
                             wOovChar: Double = 12.0,
                             wTail: Double = 6.0,
                             maxScoredLength: Int = 40) throws -> CharNGram {

        var scalars = Set<UInt32>()
        for w in words {
            for ch in w where ch.unicodeScalars.count == 1 {
                scalars.insert(ch.unicodeScalars.first!.value)
            }
        }
        let alphabet = scalars.sorted().compactMap(Unicode.Scalar.init)
        guard !alphabet.isEmpty else { throw BuildError.emptyTrainingSet }
        let N = alphabet.count
        let S = N + 2
        let boundary = UInt16(N)
        var symbolOf = [UInt32: UInt16](minimumCapacity: N * 2)
        for (i, s) in alphabet.enumerated() { symbolOf[s.value] = UInt16(i) }

        // Sayaçlar — yoğun diziler; S küçük olduğu için sözlükten hızlı.
        var c3 = [Double](repeating: 0, count: S * S * S)
        var c2 = [Double](repeating: 0, count: S * S)
        var c1 = [Double](repeating: 0, count: S)
        var total = 0.0

        for w in words {
            var h1 = boundary, h2 = boundary
            for ch in w {
                let sym: UInt16
                if ch.unicodeScalars.count == 1,
                   let s = symbolOf[ch.unicodeScalars.first!.value] { sym = s }
                else { sym = UInt16(N + 1) }
                c3[(Int(h1) * S + Int(h2)) * S + Int(sym)] += 1
                c2[Int(h2) * S + Int(sym)] += 1
                c1[Int(sym)] += 1
                total += 1
                h1 = h2; h2 = sym
            }
            c3[(Int(h1) * S + Int(h2)) * S + Int(boundary)] += 1
            c2[Int(h2) * S + Int(boundary)] += 1
            c1[Int(boundary)] += 1
            total += 1
        }

        // Bağlam toplamları ve farklı-devam sayıları.
        var ctx2 = [Double](repeating: 0, count: S * S)   // c(h₁,h₂)
        var uniq2 = [Double](repeating: 0, count: S * S)  // u(h₁,h₂)
        for h in 0..<(S * S) {
            var sum = 0.0, uniq = 0.0
            for c in 0..<S where c3[h * S + c] > 0 { sum += c3[h * S + c]; uniq += 1 }
            ctx2[h] = sum; uniq2[h] = uniq
        }
        var ctx1 = [Double](repeating: 0, count: S)
        var uniq1 = [Double](repeating: 0, count: S)
        for h in 0..<S {
            var sum = 0.0, uniq = 0.0
            for c in 0..<S where c2[h * S + c] > 0 { sum += c2[h * S + c]; uniq += 1 }
            ctx1[h] = sum; uniq1[h] = uniq
        }
        let uniq0 = Double(c1.filter { $0 > 0 }.count)

        // P₁ — tekdüzeye interpolasyon. Tabanın SIFIRDAN büyük olması, sonlu
        // maliyet garantisinin dayandığı yer: hiç görülmemiş bir karakter bile
        // `1/S`'lik kütle alır.
        let uniform = 1.0 / Double(S)
        let l1 = total > 0 ? total / (total + max(uniq0, 1)) : 0
        var p1 = [Double](repeating: 0, count: S)
        for c in 0..<S {
            let ml = total > 0 ? c1[c] / total : 0
            p1[c] = l1 * ml + (1 - l1) * uniform
        }

        var p2 = [Double](repeating: 0, count: S * S)
        for h in 0..<S {
            let denom = ctx1[h] + max(uniq1[h], 1)
            let l2 = denom > 0 ? ctx1[h] / denom : 0
            for c in 0..<S {
                let ml = ctx1[h] > 0 ? c2[h * S + c] / ctx1[h] : 0
                p2[h * S + c] = l2 * ml + (1 - l2) * p1[c]
            }
        }

        var table = [UInt16](repeating: 0, count: S * S * S)
        var maxNats = 0.0
        for h in 0..<(S * S) {
            let denom = ctx2[h] + max(uniq2[h], 1)
            let l3 = denom > 0 ? ctx2[h] / denom : 0
            let h2 = h % S
            for c in 0..<S {
                let ml = ctx2[h] > 0 ? c3[h * S + c] / ctx2[h] : 0
                let p = l3 * ml + (1 - l3) * p2[h2 * S + c]
                let cost = -log(max(p, 1e-300))
                maxNats = max(maxNats, cost)
                let q = (cost * CharNGram.quantScale).rounded()
                // Sessiz saturation farklı olasılıkları aynı maliyete çevirir;
                // model ayrım gücünü kaybeder ama hiçbir yerde belli olmaz.
                guard q <= 65535 else {
                    throw BuildError.quantizationOverflow(maxNats: cost)
                }
                table[h * S + c] = UInt16(max(q, 0))
            }
        }

        return CharNGram(alphabet: alphabet, table: table,
                         wOovChar: wOovChar, wTail: wTail,
                         maxScoredLength: maxScoredLength)
    }
}
