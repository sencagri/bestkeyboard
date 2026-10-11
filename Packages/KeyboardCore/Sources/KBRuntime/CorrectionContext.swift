import KBFoundation

/// One immutable view of the visible host suffix at a correction boundary.
/// Composition may contain only `graphql` while the host contains `feature/graphql`.
/// This context is protection evidence, never permission to delete the wider span.
struct CorrectionContext: Equatable {
    let surface: String
    let hostAgrees: Bool
    let protectsLiteral: Bool

    init(display: String, before: String?) {
        guard !display.isEmpty, let before, before.hasSuffix(display) else {
            surface = display
            hostAgrees = false
            protectsLiteral = true
            return
        }
        hostAgrees = true
        let visible = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        surface = visible
        // Surrounding quotation marks do not turn ordinary prose into code.
        let token = visible.drop(while: { "\"'’“‘([{«".contains($0) })
        let hasSyntax = token.contains { $0.isNumber || "_./\\:@#-=+~$%&|<>".contains($0) }
        let apostropheSuffix = token.contains("'") || token.contains("’")
        // Initial capitalization is ordinary prose. Internal capitals and short
        // acronyms are intentional syntax; inspect the actual display, not keys.
        let internalCapital = token.dropFirst().contains { $0.isUppercase }
            && token.contains { $0.isLowercase }
        let acronym = token.count <= 4 && token.contains { $0.isUppercase }
            && !token.contains { $0.isLowercase }
        protectsLiteral = String(token) != display || hasSyntax || apostropheSuffix || internalCapital || acronym
    }
}
