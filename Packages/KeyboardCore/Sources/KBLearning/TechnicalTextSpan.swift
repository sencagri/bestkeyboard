import Foundation

/// Cursor-local structured token boundaries, shared by recall and observation.
/// Internal phone/quoted-mail spaces belong to the token; prose separators do not.
enum TechnicalTextSpan {
    struct Span {
        var prefix: String
        var right: String
        var phone: Bool
        var openingWrapper = ""
        var closingWrapper = ""
    }

    static func emailSeparator(in text: String) -> String.Index? {
        var quoted = false, escaped = false
        for index in text.indices {
            let ch = text[index]
            if escaped { escaped = false; continue }
            if quoted && ch == "\\" { escaped = true; continue }
            if ch == "\"" { quoted.toggle(); continue }
            if ch == "@" && !quoted { return index }
        }
        return nil
    }

    static func phonePrefixKey(_ value: String) -> String? {
        if let key = TechnicalTokenKind.normalizedPhone(value) { return key }
        // A cursor may be inside a single not-yet-closed area-code parenthesis.
        if value.filter({ $0 == "(" }).count == 1, !value.contains(")") {
            return TechnicalTokenKind.normalizedPhone(value + ")")
        }
        return nil
    }

    static func phoneSuffix(in before: String) -> String? {
        for start in before.suffix(40).indices where "+0(".contains(before[start]) {
            guard start == before.startIndex || before[before.index(before: start)].isWhitespace else { continue }
            let candidate = String(before[start...])
            if phonePrefixKey(candidate) != nil { return candidate }
        }
        return nil
    }

    static func atCursor(before: String, after: String) -> Span? {
        var wrapperBudget = 64
        return atCursor(before: before, after: after, wrapperDepth: 0, wrapperBudget: &wrapperBudget)
    }

    private static func atCursor(before: String, after: String, wrapperDepth: Int, wrapperBudget: inout Int) -> Span? {
        // Explicit paired wrappers are outside the address. Resolve them before
        // interpreting a right parenthesis as URL data. Incomplete inner syntax
        // may be supplied by the selected completion (for example f( -> f(x)).
        var sawPairedAddressWrapper = false
        do {
            let fragment = String(after.prefix(PersonalHistory.maxTokenLength + 16).prefix { !$0.isWhitespace })
            let withoutProse = String(fragment.reversed().drop(while: { ",.;:!?…".contains($0) }).reversed())
            let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "“": "”", "«": "»", "`": "`"]
            if let closing = withoutProse.last {
                for start in before.suffix(PersonalHistory.maxTokenLength + 8).indices {
                    guard pairs[before[start]] == closing,
                          start == before.startIndex || before[before.index(before: start)].isWhitespace else { continue }
                    let inner = String(before[before.index(after: start)...])
                    // Outer quote layers can hide the mailbox separator from
                    // the quote parser; recursive span validation owns syntax.
                    guard inner.contains("://") || inner.contains("@") else { continue }
                    sawPairedAddressWrapper = true
                    guard wrapperDepth < 8, wrapperBudget > 0 else { return nil }
                    wrapperBudget -= 1
                    let right = String(withoutProse.dropLast())
                    if var span = atCursor(before: inner, after: right, wrapperDepth: wrapperDepth + 1, wrapperBudget: &wrapperBudget),
                       inner == span.openingWrapper + span.prefix,
                       right == span.right + span.closingWrapper {
                        span.openingWrapper = String(before[start]) + span.openingWrapper
                        span.closingWrapper += String(fragment.dropFirst(right.count))
                        return span
                    }
                }
            }
        }

        // A recognized outer pair must never fall back to the generic token
        // parser: that would reinterpret its closing delimiter as URL data.
        guard !sawPairedAddressWrapper, wrapperBudget > 0 else { return nil }

        // Scan only the bounded active line. A closing quote is recognized by
        // the state machine, including escaped quotes and @ inside the mailbox.
        for start in before.suffix(PersonalHistory.maxTokenLength).indices where before[start] == "\"" {
            guard start == before.startIndex || before[before.index(before: start)].isWhitespace else { continue }
            let prefix = String(before[start...])
            let combined = prefix + after.prefix(PersonalHistory.maxTokenLength)
            var escaped = false, closed = false, hasAt = false
            var domainStarted = false, literalDomain = false, literalClosed = false
            var length = 0
            for ch in combined {
                if length == 0 { length += 1; continue }
                if !closed {
                    if ch.isNewline { break }
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { closed = true }
                } else if !hasAt {
                    if ch != "@" {
                        // Do not treat an attached domain after a missing @
                        // as prose outside the completion's replacement span.
                        length = 0
                        break
                    }
                    hasAt = true
                } else {
                    if !domainStarted {
                        domainStarted = true
                        literalDomain = ch == "["
                        if literalDomain { length += 1; continue }
                    }
                    if literalDomain {
                        if literalClosed {
                            // A completed literal cannot be followed by more
                            // address characters. Prose remains outside the span.
                            if !ch.isWhitespace && !",.;!?…\"'”’»)]}".contains(ch) { length = 0 }
                            break
                        }
                        if ch == "]" { literalClosed = true }
                        else if !(ch.isASCII && (ch.isLetter || ch.isNumber || ch == ":" || ch == ".")) {
                            // Inside an unclosed IP literal this is an invalid
                            // address fragment, never trailing prose.
                            length = 0
                            break
                        }
                    } else if !(ch == "." || ch == "-" || ch.unicodeScalars.allSatisfy({
                        CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                    })) {
                        // Only prose separators may end the address span.
                        // An attached technical tail must not disappear from
                        // the completion's right-context compatibility check.
                        if !ch.isWhitespace && !",;!?…\"'”’»)]}".contains(ch) { length = 0 }
                        break
                    }
                }
                length += 1
            }
            guard length >= prefix.count, !prefix.contains(where: \.isNewline) else { continue }
            let right = String(combined.dropFirst(prefix.count).prefix(length - prefix.count))
            return Span(prefix: prefix, right: right, phone: false)
        }
        if let prefix = phoneSuffix(in: before) {
            let candidateRight = String(after.prefix(40).prefix { $0.isASCII && ($0.isNumber || " ().-".contains($0)) || $0 == " " })
            if let boundary = after.dropFirst(candidateRight.count).first,
               !boundary.isWhitespace && !",.;:!?…\"'”’»)]}".contains(boundary),
               candidateRight.last?.isWhitespace != true {
                // A technical fragment attached to the number is not prose.
                // Do not complete only the prefix and duplicate the rest.
                return nil
            }
            let right = String(candidateRight.reversed().drop(while: { " .- ".contains($0) }).reversed())
            // A space/dot after a finished phone is prose, not part of a
            // deletion range. Inside a number the known right tail disambiguates.
            if let last = prefix.last, " .- ".contains(last), right.isEmpty { return nil }
            guard phonePrefixKey(prefix + right) != nil else { return nil }
            return Span(prefix: prefix, right: right, phone: true)
        }
        let raw = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        let prefix = String(raw.drop(while: { "(«“".contains($0) }))
        guard !prefix.isEmpty else { return nil }
        return Span(prefix: prefix, right: String(after.prefix { !$0.isWhitespace }), phone: false)
    }
}
