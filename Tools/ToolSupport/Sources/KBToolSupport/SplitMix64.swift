import Foundation

/// Deterministik, hızlı PRNG — `Math.random` yerine tohumlanabilir olması şart
/// (regresyon karşılaştırmaları aynı diziyi üretmeli).
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextDouble() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    /// Box-Muller.
    public mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-12)
        let u2 = nextDouble()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
