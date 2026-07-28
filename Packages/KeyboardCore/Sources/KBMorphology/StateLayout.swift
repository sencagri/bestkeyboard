import Foundation

/// Morfem sınırındaki alternasyon durumu.
///
/// Üç değerli **tek** bir alan. Önceki sürümde bu karar iki `Bool`
/// (`pendingSoften`, `softenedMorphemeEnd`) artı `suffixID == 255` gizli
/// işaretçisiyle kodlanıyordu; o temsil hem yasadışı kombinasyon üretiyor
/// hem de bit ölçümünü yanıltıyordu.
public enum BoundaryAlternation: UInt8, Sendable, CaseIterable {
    /// Kısıt yok.
    case none
    /// Yumuşamamış biçim emit edildi; alternasyonu olan bir morfem sonu.
    /// Sonraki ek **ünsüzle başlamalı** ya da kelime bitmeli.
    /// (`kitap` → `kitapta` ✓, `kitapı` ✗)
    case mustTakeConsonantOrEnd
    /// Yumuşamış biçim emit edildi (`kitab-`, `geleceğ-`).
    /// Sonraki ek **ünlüyle başlamalı**; kelime burada bitemez.
    case mustTakeVowelSuffix
    /// Ünlü düşürülmüş kök (`burn-`, `ağz-`).
    /// Sonraki ek **ünlüyle başlamalı**; kelime burada bitemez.
    case droppedVowelMustTakeVowel
}

/// Morfoloji **düğüm** şeması ve bit ölçümü.
///
/// > Bu, decoder'ın tam dedup anahtarı **değildir**. Sözleşme §4'teki anahtar
/// > ayrıca `automaton`, `language`, `surfaceId`, `touchIndex`,
/// > `lastSurfaceSymbol` ve `atWordStart` taşır. Buradaki ölçüm yalnız
/// > `node` alanına ne sığması gerektiğini söyler; tam anahtar genişliği
/// > `DecoderKeyLayout` ile ayrıca raporlanır.
public struct MorphologyNodeLayout: Sendable {
    public let rootCount: Int
    public let suffixCount: Int        // **yoğun** indeks sayısı (seyrek id değil)
    public let continuationCount: Int
    public let maxRootLen: Int
    public let maxSuffixPieces: Int

    public init(rootCount: Int, suffixCount: Int, continuationCount: Int,
                maxRootLen: Int, maxSuffixPieces: Int) {
        self.rootCount = rootCount
        self.suffixCount = suffixCount
        self.continuationCount = continuationCount
        self.maxRootLen = maxRootLen
        self.maxSuffixPieces = maxSuffixPieces
    }

    public static func width(forCount n: Int) -> Int {
        n <= 1 ? 1 : Int(ceil(log2(Double(n))))
    }

    // --- Ortak alanlar (her iki faz için de gerekli) ---
    public var phaseBits: Int { 1 }
    public var continuationBits: Int { Self.width(forCount: continuationCount) }
    /// isBack, isRounded, lastWasVowel, lastWasVoiceless
    public var phonologyBits: Int { 4 }
    public var alternationBits: Int { Self.width(forCount: BoundaryAlternation.allCases.count) }

    // --- Faza özgü yükler: **birbirini dışlar** ---
    public var rootPayloadBits: Int {
        Self.width(forCount: rootCount) + Self.width(forCount: maxRootLen + 1)
    }
    public var suffixPayloadBits: Int {
        Self.width(forCount: suffixCount) + Self.width(forCount: maxSuffixPieces + 1)
    }

    /// Etiketli birleşim (tagged union): düz toplam değil.
    /// Kök konumu ile ek konumu aynı anda anlamlı olamaz.
    public var total: Int {
        phaseBits + continuationBits + phonologyBits + alternationBits
            + max(rootPayloadBits, suffixPayloadBits)
    }

    public var fitsInUInt32: Bool { total <= 32 }

    public var breakdown: String {
        """
        faz \(phaseBits) · devam \(continuationBits) · fonoloji \(phonologyBits) · \
        alternasyon \(alternationBits) · yük max(kök \(rootPayloadBits), ek \(suffixPayloadBits)) \
        = \(total) bit
        """
    }

    /// Faz 4 hedef ölçeği.
    ///
    /// UYARI: bu sayılar **tahmindir**, repoda onları türeten korpus/paradigma
    /// envanteri henüz yok. Faz 4'te gerçek sözlük ve tamamlanmış morfotaktik
    /// graftan otomatik ölçülecek (§Doğrulanmalı).
    public static let productionEstimate = MorphologyNodeLayout(
        rootCount: 90_000, suffixCount: 200, continuationCount: 64,
        maxRootLen: 24, maxSuffixPieces: 8)
}

/// Decoder'ın **tam** dedup anahtarı genişliği (§4).
public enum DecoderKeyLayout {
    public static let automatonBits = 2      // formTrie | morphology | personal | domain
    public static let languageBits = 2       // en fazla 2 aktif dil + rezerv
    public static let surfaceIdBits = 32     // morfolojide rolling hash; trie'de node
    public static let touchIndexBits = 6     // 0..63 dokunma
    public static let lastSurfaceSymbolBits = 8
    public static let atWordStartBits = 1

    public static func total(nodeBits: Int) -> Int {
        automatonBits + languageBits + nodeBits + surfaceIdBits
            + touchIndexBits + lastSurfaceSymbolBits + atWordStartBits
    }
}

// MARK: - Gerçek paketleme
//
// Ölçüm tek başına kanıt değildir: "toplam < 32" aritmetiği, gerçek durumların
// çakışmadan kodlanabildiğini göstermez. Aşağıdaki pack/unpack, ölçümü
// **round-trip ve benzersizlik testiyle** kanıtlanabilir hale getirir.

public extension MorphologyNodeLayout {
    /// Alan konumları (LSB'den itibaren).
    var phaseShift: Int { 0 }
    var continuationShift: Int { phaseShift + phaseBits }
    var alternationShift: Int { continuationShift + continuationBits }
    var phonologyShift: Int { alternationShift + alternationBits }
    var payloadShift: Int { phonologyShift + phonologyBits }

    var payloadIndexBits: Int {
        max(Self.width(forCount: rootCount), Self.width(forCount: suffixCount))
    }
    var offsetFieldBits: Int {
        max(Self.width(forCount: maxRootLen + 1), Self.width(forCount: maxSuffixPieces + 1))
    }
}

public extension MorphologyAutomaton.State {
    /// Düğümü tek bir tam sayıya paketler. `layout.total > 64` ise `nil`.
    func packed(_ layout: MorphologyNodeLayout) -> UInt64? {
        guard layout.total <= 64 else { return nil }
        var v: UInt64 = 0
        var shift = 0
        func put(_ value: UInt64, _ bits: Int) {
            precondition(value < (1 << UInt64(bits)), "alan taşması: \(value) / \(bits) bit")
            v |= value << UInt64(shift)
            shift += bits
        }
        put(UInt64(phase.rawValue), layout.phaseBits)
        put(UInt64(continuation.rawValue), layout.continuationBits)
        put(UInt64(alternation.rawValue), layout.alternationBits)
        put((isBack ? 1 : 0) | (isRounded ? 2 : 0)
            | (lastWasVowel ? 4 : 0) | (lastWasVoiceless ? 8 : 0), layout.phonologyBits)
        put(UInt64(payloadIndex), layout.payloadIndexBits)
        put(UInt64(offset), layout.offsetFieldBits)
        return v
    }

    static func unpacked(_ v: UInt64, _ layout: MorphologyNodeLayout) -> Self? {
        var shift = 0
        func take(_ bits: Int) -> UInt64 {
            let mask: UInt64 = bits >= 64 ? .max : ((1 << UInt64(bits)) - 1)
            let out = (v >> UInt64(shift)) & mask
            shift += bits
            return out
        }
        guard let phase = Phase(rawValue: UInt8(take(layout.phaseBits))) else { return nil }
        guard let cont = Continuation(rawValue: UInt8(take(layout.continuationBits))) else { return nil }
        guard let alt = BoundaryAlternation(rawValue: UInt8(take(layout.alternationBits))) else { return nil }
        let ph = take(layout.phonologyBits)
        let payload = UInt32(take(layout.payloadIndexBits))
        let off = UInt8(take(layout.offsetFieldBits))
        return Self(phase: phase, payloadIndex: payload, offset: off,
                    continuation: cont, alternation: alt,
                    isBack: ph & 1 != 0, isRounded: ph & 2 != 0,
                    lastWasVowel: ph & 4 != 0, lastWasVoiceless: ph & 8 != 0)
    }
}

public extension MorphologyAutomaton {
    /// Bir kökten erişilebilen tüm durumlar — pack/unpack kanıtı için.
    func reachableStates(maxSurfaceLen: Int = 12) -> Set<State> {
        var seen = Set<State>()
        var stack = startStates()
        var depthOf = [State: Int]()
        for s in stack { depthOf[s] = 0 }
        while let s = stack.popLast() {
            if seen.contains(s) { continue }
            seen.insert(s)
            let d = depthOf[s] ?? 0
            guard d < maxSurfaceLen else { continue }
            for a in arcs(from: s) where !seen.contains(a.target) {
                depthOf[a.target] = d + 1
                stack.append(a.target)
            }
        }
        return seen
    }
}
