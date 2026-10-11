import KBFoundation
import KBLearning

/// A host-verified word offer spanning recording token boundaries. Symbol-plane
/// letters carry no letter-touch evidence, so these offers never enter the beam
/// or automatic correction. Applying them uses the ordinary recorded text edits.
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
    /// the complete visible word only when it contains a symbol-plane letter.
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
        guard (1...WordBoundaryRepair.maximumInputLength).contains(word.count),
              word.allSatisfy(\.isLetter),
              TurkishText.key(word).contains(where: { "âîû".contains($0) }) else { return nil }
        let repairs = WordBoundaryRepair.suggestions(for: word, channel: engine.literalChannel,
            personalCost: { isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
        return .init(original: word, surfaces: [word] + repairs, before: before, after: after)
    }

    /// Explicit acceptance of a verified complete word, never an automatic or
    /// weak observation. The caller performs the visible text edit first.
    public mutating func confirmWholeWord(_ word: String) {
        acceptPersonalSurface(word)
    }
}
