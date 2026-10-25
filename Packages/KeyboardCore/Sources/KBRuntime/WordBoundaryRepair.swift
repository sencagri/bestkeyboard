import KBDecoder
import KBFoundation

/// Explicit two-word offers. These never participate in autocorrection scoring.
/// Bounded by input length and candidate count; both sides must be known words.
enum WordBoundaryRepair {
    // Two supported words plus one accidental space-adjacent letter.
    static let maximumInputLength = 2 * LexiconLimits.maxSurfaceLength + 1
    // Short corpus fragments need stronger joint evidence than arbitrary known
    // tokens. This UI cutoff rejects ls+lem and pats+tes while retaining the
    // short Turkish/English phrase controls (including sql+aç). It is not an
    // autocorrection threshold or a claim of grammatical plausibility.
    static let maximumShortPairLexicalCost = 23.0
    static let shortPairAlternativeWindow = 2.0
    // Reviewed lexical pairs, not a productive rule for arbitrary short roots.
    // Provenance and negative controls: docs/keyboard-architecture-review.md,
    // "Short fixed-root batch discovery". Both words still require recognition
    // and at least one component must be an explicitly fixed lexical root.
    private static let shortFixedPairs: Set<String> = [
        "zart zurt", "zırt pırt", "vırt zırt", "çer çöp", "çör çöp", "fasa fiso", "sıkı fıkı",
        "garç gurç", "şaka maka"
    ]
    // Dictionary-attested short phrases whose components need not be fixed
    // roots. Both sides still pass cost() vocabulary recognition below.
    // TDK: https://sozluk.gov.tr/gts?ara=besi (besi suyu).
    private static let shortDictionaryPairs: Set<String> = ["besi suyu"]
    static func suggestions(for surface: String, channel: LiteralChannel, limit: Int = 2,
                            personalCost: (String) -> Double? = { _ in nil }) -> [String] {
        // Compose before Turkic case folding: decomposed uppercase I +
        // circumflex must become i-circumflex, not dotless i + circumflex.
        let word = TurkishText.key(surface)
        guard limit > 0, (3...maximumInputLength).contains(word.count), word.allSatisfy(\.isLetter),
              personalCost(word) == nil else { return [] }
        if channel.score(word).isInVocabulary {
            // Generated possessive/case paths can coincide with an omitted
            // space before a question particle (bellimi → belli mi). Offer
            // that exact, vowel-harmonized split without changing the literal
            // or opening arbitrary splits of known dictionary words.
            guard !channel.hasListedSurface(word), word.count > 3 else { return [] }
            let stem = String(word.dropLast(2)), particle = String(word.suffix(2))
            guard channel.hasListedSurface(stem), channel.score(particle).isInVocabulary,
                  let vowel = stem.last(where: { "aeıioöuü".contains($0) }) else { return [] }
            let expected: String
            switch vowel {
            case "a", "ı": expected = "mı"
            case "e", "i": expected = "mi"
            case "o", "u": expected = "mu"
            default: expected = "mü"
            }
            guard particle == expected else { return [] }
            return [TurkishText.applying(TurkishText.casing(of: surface), to: stem + " " + particle)]
        }
        let chars = Array(word)
        var scored: [(surface: String, rank: Double, lexical: Double, short: Bool, personal: Bool, mistap: Bool, listed: Bool, repeatedBoundary: Bool)] = []
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
        func append(_ left: String, _ right: String, cost: Double, mistap: Bool, repeatedBoundary: Bool = false) {
            // A fixed-root repetition (zonk zonk), or a reviewed fixed pair,
            // supplies evidence beyond the weak unigram floor for fragments.
            let fixedPhrase = shortDictionaryPairs.contains(left + " " + right)
                || (left == right && channel.hasFixedLexicalSurface(left))
                || (shortFixedPairs.contains(left + " " + right)
                    && (channel.hasFixedLexicalSurface(left) || channel.hasFixedLexicalSurface(right)))
            if !fixedPhrase, left.count <= 4, right.count <= 4,
               cost > maximumShortPairLexicalCost,
               personalCost(left) == nil, personalCost(right) == nil { return }
            scored.append((left + " " + right, cost + (mistap ? 1 : 0), cost,
                           !fixedPhrase && left.count <= 4 && right.count <= 4,
                           personalCost(left) != nil || personalCost(right) != nil, mistap,
                           fixedPhrase || (channel.hasListedSurface(left) && channel.hasListedSurface(right)), repeatedBoundary))
        }
        for index in 1..<chars.count {
            let left = String(chars[..<index])
            guard let leftCost = cost(left) else { continue }
            let right = String(chars[index...])
            if let rightCost = cost(right) {
                append(left, right, cost: leftCost + rightCost, mistap: false)
            }
            // Turkish Q bottom-row keys next to the space bar. A substituted
            // letter is proposed only when deleting it yields two known words.
            if index + 1 < chars.count, "zxcvbnmçö".contains(chars[index]) {
                let afterMistap = String(chars[(index + 1)...])
                if let rightCost = cost(afterMistap) {
                    append(left, afterMistap, cost: leftCost + rightCost, mistap: true,
                           repeatedBoundary: chars[index - 1] == chars[index] || chars[index] == chars[index + 1])
                }
            }
        }
        var seen: Set<String> = []
        let ranked = scored.sorted { ($0.rank, $0.surface) < ($1.rank, $1.surface) }
        let best = ranked.first
        let bestListedExact = ranked.first { !$0.mistap && $0.listed }
        var eligible = ranked.filter { candidate in
            // If adding only a space already yields two listed words, do not
            // fill a spare slot by deleting a letter for a weaker generated
            // form (erişim reddedildi / erişi reddedildi). Genuine mistaps,
            // listed alternatives and personal vocabulary remain available.
            if candidate.mistap, !candidate.listed, !candidate.personal,
               let exact = bestListedExact, exact.rank < candidate.rank { return false }
            // A spare slot is not a reason to show a much weaker short split
            // (su iç / sub iç). Compare lexical evidence separately from the
            // one-letter space mistap penalty. Keep personal and long phrases.
            guard candidate.short, !candidate.personal, let best, best.short else { return true }
            return candidate.lexical <= best.lexical + shortPairAlternativeWindow
        }
        // Prefer adding only the missing space when both resulting words are
        // listed or the split is an explicitly verified fixed phrase.
        // Unigram frequency alone must not put a needless deletion
        // first (arzederim → ar ederim). Apply this after credibility filtering
        // so weak short splits cannot displace real mistaps (subiç → su iç).
        // Personal words and repeated boundary letters (ozzaman → o zaman)
        // provide stronger evidence for keeping the deletion winner.
        if let first = eligible.first, first.mistap, !first.personal, !first.repeatedBoundary,
           let exactIndex = eligible.firstIndex(where: { !$0.mistap && $0.listed }) {
            let exact = eligible.remove(at: exactIndex)
            eligible.insert(exact, at: 0)
        }
        return eligible.map(\.surface).filter { seen.insert($0).inserted }
            .prefix(limit).map { TurkishText.applying(TurkishText.casing(of: surface), to: $0) }
    }
}
