import KBDecoder
import KBFoundation
import KBLearning

/// A host-verified word offer spanning recording token boundaries. Symbol-plane
/// letters and proper-name apostrophes split composition evidence. These offers
/// never enter the beam or automatic correction. Applying them uses the ordinary recorded text edits.
public struct WholeWordSuggestion: Equatable, Sendable {
    public let original: String
    public let surfaces: [String]
    private let before: String
    private let after: String?

    init(original: String, surfaces: [String], before: String, after: String?) {
        self.original = original; self.surfaces = surfaces
        self.before = before; self.after = after
    }

    public func matches(before: String?, after: String?, selected: String?) -> Bool {
        selected == nil && before == self.before && after == self.after
    }

    /// Preserve an existing right boundary, including closing punctuation. Only
    /// append the normal typing separator when the visible caret is at the end.
    public func replacement(for surface: String) -> String? {
        guard surfaces.contains(surface) else { return nil }
        return surface + (after?.isEmpty == false ? "" : " ")
    }

    static func isOpening(_ ch: Character) -> Bool {
        "\"'’".contains(ch) || ch.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .openPunctuation ||
            $0.properties.generalCategory == .initialPunctuation
        }
    }

    static func isClosing(_ ch: Character) -> Bool {
        "\"'.,!?;:…>".contains(ch) || ch.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .closePunctuation ||
            $0.properties.generalCategory == .finalPunctuation
        }
    }

    /// A single repeated letter can be removed on either side of a proper-name
    /// apostrophe. Keep the exact apostrophe/casing and require dictionary proof
    /// of both the repaired root and its complete inflection.
    static func apostropheDuplicateRepairs(_ word: String, channel: LiteralChannel) -> [String] {
        let letters = Array(word)
        guard letters.filter({ $0 == "'" || $0 == "’" }).count == 1,
              letters.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
              !channel.score(TurkishText.key(String(letters.filter(\.isLetter)))).isInVocabulary else { return [] }
        var repairs: [String] = []
        for index in 1..<letters.count where letters[index].isLetter && letters[index] == letters[index - 1] {
            var candidate = letters
            candidate.remove(at: index)
            let surface = String(candidate)
            let parts = surface.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "'" || $0 == "’" })
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  channel.hasProperLexicalSurface(TurkishText.key(String(parts[0]))),
                  channel.score(TurkishText.key(parts.joined())).isInVocabulary,
                  !repairs.contains(surface) else { continue }
            repairs.append(surface)
            if repairs.count == 2 { break }
        }
        return repairs
    }

    static func hasRightBoundary(_ after: String?) -> Bool {
        guard let after else { return true }
        // Inspect the whole adjoining punctuation run: a dot alone is prose,
        // but .com, :443, ?q=1 and apostrophe suffixes continue the token.
        let adjacent = after.prefix(32).prefix(while: { !$0.isWhitespace })
        return adjacent.count < 32 && adjacent.allSatisfy(isClosing)
    }
}

extension InputCoordinator {
    /// Physical letter tokens already have their own offers. This path recovers
    /// the complete visible word for symbol-plane letters or proper apostrophes.
    public func wholeWordSuggestion(before: String?, after: String?, selected: String?) -> WholeWordSuggestion? {
        guard !fieldIsSecure, selected == nil, let before, let engine,
              WholeWordSuggestion.hasRightBoundary(after) else { return nil }
        let scanLimit = WordBoundaryRepair.maximumInputLength + 9
        let token = String(before.reversed().prefix(scanLimit)
            .prefix(while: { !$0.isWhitespace }).reversed())
        // Up to eight opening wrappers; never accept the clipped tail of a
        // longer token as a complete word.
        guard token.count < scanLimit else { return nil }
        let opening = token.prefix(while: WholeWordSuggestion.isOpening)
        guard opening.count <= 8 else { return nil }
        let word = String(token.dropFirst(opening.count))
        guard (1...WordBoundaryRepair.maximumInputLength).contains(word.count) else { return nil }
        // Offer removal of one stray ASCII space only when the joined word
        // has dictionary evidence and at least one fragment is unknown. Never
        // automatically merge valid phrases, sentence boundaries or identifiers.
        if opening.isEmpty, word.count >= 2, word.allSatisfy(\.isLetter) {
            let prefix = before.dropLast(word.count)
            if prefix.last == " ", prefix.dropLast().last?.isWhitespace == false {
                let leftToken = String(prefix.dropLast().reversed().prefix(scanLimit)
                    .prefix(while: { !$0.isWhitespace }).reversed())
                let leftOpening = leftToken.prefix(while: WholeWordSuggestion.isOpening)
                let left = String(leftToken.dropFirst(leftOpening.count))
                let joined = left + word
                let rightKey = TurkishText.key(word)
                let leftKey = TurkishText.key(left)
                let bothKnown = (engine.literalChannel.score(leftKey).isInVocabulary || isKnownPersonalInflection(leftKey))
                    && (engine.literalChannel.score(rightKey).isInVocabulary || isKnownPersonalInflection(rightKey))
                if leftToken.count < scanLimit, leftOpening.count <= 8,
                   left.count >= 2, left.allSatisfy(\.isLetter),
                   joined.count <= LexiconLimits.maxSurfaceLength,
                   (word == TurkishText.lowercased(word) || joined == TurkishText.uppercased(joined)),
                   !bothKnown, engine.literalChannel.score(TurkishText.key(joined)).isInVocabulary {
                    let original = left + " " + word
                    return .init(original: original, surfaces: [original, joined], before: before, after: after)
                }
            }
        }
        if word.contains("'") || word.contains("’") {
            let repairs = WholeWordSuggestion.apostropheDuplicateRepairs(word, channel: engine.literalChannel)
            guard !repairs.isEmpty else { return nil }
            return .init(original: word, surfaces: [word] + repairs, before: before, after: after)
        }
        guard word.allSatisfy(\.isLetter),
              TurkishText.key(word).contains(where: { "âîû".contains($0) }) else { return nil }
        let repairs = WordBoundaryRepair.suggestions(for: word, channel: engine.literalChannel,
            personalCost: { isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
        return .init(original: word, surfaces: [word] + repairs, before: before, after: after)
    }

    /// Confirm a verified complete word after the caller's visible edit.
    /// Existing-text confirmation can seed one weak spelling, but cannot
    /// increase its evidence without an independently typed occurrence.
    public mutating func confirmWholeWord(_ word: String) {
        acceptPersonalSurface(word)
    }
}
