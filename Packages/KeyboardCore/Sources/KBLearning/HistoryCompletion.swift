import Foundation

extension PersonalHistory {
    /// Explicit completion; component reuse is distinguished from full recall.
    /// A composed address is a typing aid, not a claim that the address exists.
    public struct Completion: Equatable, Sendable {
        public enum Source: String, Sendable { case observed, emailDomain, urlHost, urlPath, port }
        public let prefix: String
        public let surface: String
        public let before: String
        public let after: String
        public let source: Source
        public let rightToken: String
        public let closingWrapper: String
        public var cursorAdvanceCount: Int { rightToken.count + closingWrapper.count }
        /// UIKit cursor offsets use UTF-16 units; slicing above remains grapheme-based.
        public var cursorAdvanceUTF16Count: Int { rightToken.utf16.count + closingWrapper.utf16.count }
        public var literalSurface: String { prefix + rightToken }
        /// Keep the existing right-hand fragment in the document exactly once.
        public var replacementBeforeCursor: String { String(surface.dropLast(rightToken.count)) }
        public func matches(before: String?, after: String?, selected: String?) -> Bool {
            selected == nil && before == self.before && after == self.after
        }
    }

    public func completions(before: String?, after: String?, selected: String?, limit: Int = 3) -> [Completion] {
        guard selected == nil, let before, let after, limit > 0 else { return [] }
        guard let span = TechnicalTextSpan.atCursor(before: before, after: after) else { return [] }
        let prefix = span.prefix, right = span.right
        // Exact suffix matching below preserves the host's complete Unicode tail.
        // Native cursor movement uses its UTF-16 length rather than restricting
        // candidates to single-unit ASCII characters.
        guard before.hasSuffix(prefix) else { return [] }
        func applicable(_ surface: String) -> Bool {
            surface != prefix + right && (right.isEmpty ||
                (surface.count >= prefix.count + right.count && surface.hasSuffix(right)))
        }
        if span.phone, let normalized = TechnicalTextSpan.phonePrefixKey(prefix), normalized.count >= 3 {
            return tokens.values.filter {
                TechnicalTokenKind.classify($0.surface) == .phone && applicable($0.surface) &&
                TechnicalTokenKind.normalizedPhone($0.surface)?.hasPrefix(normalized) == true
            }.sorted { ($0.count, $0.seq, $0.surface) > ($1.count, $1.seq, $1.surface) }
                .prefix(limit).map {
                    Completion(prefix: prefix, surface: $0.surface, before: before, after: after, source: .observed, rightToken: right, closingWrapper: span.closingWrapper)
                }
        }
        var results = recall(prefix: prefix, limit: Self.tokenCapacity).filter(applicable).prefix(limit).map {
            Completion(prefix: prefix, surface: $0, before: before, after: after, source: .observed, rightToken: right, closingWrapper: span.closingWrapper)
        }
        guard results.count < limit, prefix.contains("@") || prefix.contains(".") || prefix.contains(":") else { return results }
        let ranked = tokens.values.sorted { ($0.count, $0.seq, $0.surface) > ($1.count, $1.seq, $1.surface) }
        var seen = Set(results.map(\.surface))
        for token in ranked {
            guard let component = Self.componentCompletion(prefix: prefix, observed: token.surface),
                  applicable(component.0), Self.admissible(component.0), seen.insert(component.0).inserted else { continue }
            results.append(Completion(prefix: prefix, surface: component.0, before: before, after: after, source: component.1, rightToken: right, closingWrapper: span.closingWrapper))
            if results.count == limit { break }
        }
        return results
    }

    private static func componentCompletion(prefix: String, observed: String) -> (String, Completion.Source)? {
        // Reject unrelated paths before URL parsing. A full history often has
        // thousands of paths under one host; parsing every one per key is costly.
        if let scheme = prefix.range(of: "://"),
           let slash = prefix[scheme.upperBound...].firstIndex(of: "/") {
            guard let knownScheme = observed.range(of: "://"),
                  let knownSlash = observed[knownScheme.upperBound...].firstIndex(of: "/"),
                  observed[knownSlash...].hasPrefix(prefix[slash...]) else { return nil }
        }
        let email = prefix.split(separator: "@", omittingEmptySubsequences: false)
        if email.count == 2, !email[0].isEmpty,
           !prefix.contains(where: { "/\\:<>".contains($0) }),
           TechnicalTokenKind.classify(observed) == .email {
            let domain = String(observed.split(separator: "@").last ?? "")
            guard validHost(domain), domain.lowercased().hasPrefix(email[1].lowercased()) else { return nil }
            return (prefix + domain.dropFirst(email[1].count), .emailDomain)
        }
        if !prefix.contains("://"), let colon = prefix.lastIndex(of: ":"),
           let observedColon = observed.lastIndex(of: ":") {
            let host = String(prefix[..<colon])
            let portPrefix = prefix[prefix.index(after: colon)...]
            let port = observed[observed.index(after: observedColon)...]
            let hostKind = TechnicalTokenKind.classify(host)
            let observedKind = TechnicalTokenKind.classify(observed)
            let observedHost = String(observed[..<observedColon])
            let observedHostKind = TechnicalTokenKind.classify(observedHost)
            if !host.contains("/"), !observedHost.contains("/"),
               (hostKind == .ipv4 || (hostKind == .ipv6 && host.hasPrefix("[") && host.hasSuffix("]"))),
               (observedHostKind == .ipv4 || (observedHostKind == .ipv6 && observedHost.hasPrefix("[") && observedHost.hasSuffix("]"))),
               (observedKind == .ipv4 || observedKind == .ipv6),
               !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
               Int(port).map({ (1...65535).contains($0) }) == true,
               portPrefix.allSatisfy({ $0.isASCII && $0.isNumber }), port.hasPrefix(portPrefix) {
                return (prefix + port.dropFirst(portPrefix.count), .port)
            }
        }
        if !prefix.contains(where: { "/:@?#".contains($0) }), prefix.contains("."),
           prefix.count >= 3, let url = URLComponents(string: observed),
           ["http", "https", "ftp", "ssh"].contains(url.scheme?.lowercased() ?? ""),
           url.user == nil, url.password == nil, let host = url.host,
           validHost(host), host.lowercased().hasPrefix(prefix.lowercased()) {
            return (prefix + host.dropFirst(prefix.count), .urlHost)
        }
        // Reuse a known path only under the exact same authority. Preserve the
        // user's scheme; query parameters and credentials never transfer.
        if let typed = URLComponents(string: prefix),
           let known = URLComponents(string: observed),
           ["http", "https", "ftp", "ssh"].contains(typed.scheme?.lowercased() ?? ""),
           ["http", "https", "ftp", "ssh"].contains(known.scheme?.lowercased() ?? ""),
           typed.user == nil, typed.password == nil, known.user == nil, known.password == nil,
           typed.host?.lowercased() == known.host?.lowercased(), typed.host != nil,
           typed.port == known.port, typed.query == nil, typed.fragment == nil,
           !typed.percentEncodedPath.isEmpty,
           known.percentEncodedPath.hasPrefix(typed.percentEncodedPath) {
            return (prefix + known.percentEncodedPath.dropFirst(typed.percentEncodedPath.count), .urlPath)
        }
        guard let schemeEnd = prefix.range(of: "://"),
              ["http", "https", "ftp", "ssh"].contains(prefix[..<schemeEnd.lowerBound].lowercased()) else { return nil }
        let hostPrefix = prefix[schemeEnd.upperBound...]
        guard hostPrefix.count >= 2, !hostPrefix.contains(where: { "/:@?#".contains($0) }),
              let url = URLComponents(string: observed),
              ["http", "https", "ftp", "ssh"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host,
              validHost(host), host.lowercased().hasPrefix(hostPrefix.lowercased()) else { return nil }
        // Preserve the typed scheme and host spelling; never copy paths, query,
        // ports or credentials from another address into a constructed URL.
        return (prefix + host.dropFirst(hostPrefix.count), .urlHost)
    }

    private static func validHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy {
            !$0.isEmpty && $0.first != "-" && $0.last != "-" && $0.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            }
        }
    }
}
