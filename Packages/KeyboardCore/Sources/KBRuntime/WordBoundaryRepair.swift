import KBDecoder
import KBFoundation

/// Explicit two-word offers. These never participate in autocorrection scoring.
/// Bounded by input length and candidate count; both sides must be known words.
enum WordBoundaryRepair {
    // Two supported words plus one accidental space-adjacent letter.
    static let maximumInputLength = 2 * LexiconLimits.maxSurfaceLength + 1
    static func suggestions(for surface: String, channel: LiteralChannel, limit: Int = 2,
                            personalCost: (String) -> Double? = { _ in nil }) -> [String] {
        // Compose before Turkic case folding: decomposed uppercase I +
        // circumflex must become i-circumflex, not dotless i + circumflex.
        let word = TurkishText.key(surface)
        guard limit > 0, (3...maximumInputLength).contains(word.count), word.allSatisfy(\.isLetter),
              !channel.score(word).isInVocabulary, personalCost(word) == nil else { return [] }
        let chars = Array(word)
        var scored: [(String, Double)] = []
        var costs: [String: Double] = [:]
        var unknown: Set<String> = []
        func cost(_ part: String) -> Double? {
            // Single-letter dictionary entries also include letter names and
            // technical symbols. Only the ordinary Turkish pronoun is a word
            // boundary candidate on its own.
            guard part.count <= LexiconLimits.maxSurfaceLength,
                  part.count > 1 || part == "o" else { return nil }
            if let cached = costs[part] { return cached }
            if unknown.contains(part) { return nil }
            let score = channel.score(part)
            if let value = score.isInVocabulary ? score.lexCost : personalCost(part) {
                costs[part] = value
                return value
            }
            unknown.insert(part)
            return nil
        }
        for index in 1..<chars.count {
            let left = String(chars[..<index])
            guard let leftCost = cost(left) else { continue }
            let right = String(chars[index...])
            if let rightCost = cost(right) {
                scored.append((left + " " + right, leftCost + rightCost))
            }
            // Turkish Q bottom-row keys next to the space bar. A substituted
            // letter is proposed only when deleting it yields two known words.
            if index + 1 < chars.count, "zxcvbnmçö".contains(chars[index]) {
                let afterMistap = String(chars[(index + 1)...])
                if let rightCost = cost(afterMistap) {
                    scored.append((left + " " + afterMistap,
                                   leftCost + rightCost + 1))
                }
            }
        }
        var seen: Set<String> = []
        return scored.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0).filter { seen.insert($0).inserted }
            .prefix(limit).map { TurkishText.applying(TurkishText.casing(of: surface), to: $0) }
    }
}
