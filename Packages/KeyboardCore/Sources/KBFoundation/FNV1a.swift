/// FNV-1a 64 — paket/depo checksum'ları, belge özeti ve layout parmak izi
/// **aynı** algoritmayı buradan kullanıyor. Kriptografik dirence ihtiyaç yok;
/// `CryptoKit` bağımlılığı olmaması çekirdeği platformdan bağımsız tutuyor.
///
/// Sabitler değişirse bütün kayıtlı dosyaların checksum'ı tutmaz.
public enum FNV1a {
    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01B3

    @inlinable @inline(__always)
    public static func step(_ h: UInt64, _ byte: UInt8) -> UInt64 { (h ^ UInt64(byte)) &* prime }

    /// Bayt yerine **sembol** karıştıran adım — morfoloji yüzey kimliğinin
    /// rolling hash'i (`LexiconSet.advanceSurfaceId`). Sabitler ortak.
    @inlinable @inline(__always)
    public static func step(_ h: UInt64, symbol: UInt16) -> UInt64 { (h ^ UInt64(symbol)) &* prime }

    @inlinable
    public static func hash<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var h = offsetBasis
        for b in bytes { h = step(h, b) }
        return h
    }
}
