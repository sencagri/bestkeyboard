import Foundation
import Network

/// Syntax classification for bounded history admission, independent of Turkish
/// spelling normalization. Parsing an address performs no network operation.
public enum TechnicalTokenKind: String, Sendable {
    case ipv4, ipv6, phone, email, url, path, identifier

    public static func classify(_ surface: String) -> Self? {
        if let phone = normalizedPhone(surface),
           (phone.hasPrefix("+") ? (7...15).contains(phone.count - 1) : phone.count == 11) { return .phone }
        if let components = URLComponents(string: surface),
           let scheme = components.scheme, ["http", "https", "ftp", "ssh"].contains(scheme.lowercased()),
           components.host?.isEmpty == false { return .url }
        let parts = surface.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count <= 2, let address = parts.first {
            if address.contains(":"), IPv6Address(String(address)) != nil,
               parts.count == 1 || validDecimal(parts[1], maximum: 128) { return .ipv6 }
            if isDottedIPv4(String(address)),
               parts.count == 1 || validDecimal(parts[1], maximum: 32) { return .ipv4 }
        }
        let portParts = surface.split(separator: ":", omittingEmptySubsequences: false)
        if portParts.count == 2, isDottedIPv4(String(portParts[0])),
           validDecimal(portParts[1], maximum: 65535) { return .ipv4 }
        if surface.hasPrefix("["), let bracket = surface.firstIndex(of: "]"),
           surface[surface.index(after: surface.startIndex)..<bracket].contains(":"),
           IPv6Address(String(surface[surface.index(after: surface.startIndex)..<bracket])) != nil {
            let tail = surface[surface.index(after: bracket)...]
            if tail.isEmpty || (tail.first == ":" && validDecimal(tail.dropFirst(), maximum: 65535)) { return .ipv6 }
        }
        if let at = surface.lastIndex(of: "@") {
            let local = surface[..<at]
            let domain = surface[surface.index(after: at)...]
            let literalDomain = domain.contains("[") || domain.contains("]")
            let validDomain: Bool
            if literalDomain {
                let bracketed = domain.hasPrefix("[") && domain.hasSuffix("]")
                let interior = bracketed ? String(domain.dropFirst().dropLast()) : ""
                validDomain = bracketed && (interior.lowercased().hasPrefix("ipv6:")
                    ? IPv6Address(String(interior.dropFirst(5))) != nil
                    : isDottedIPv4(interior))
            } else { validDomain = domain.contains(".") }
            if !local.isEmpty, validDomain, !domain.contains(where: { $0.isWhitespace || $0 == "@" }),
               (!local.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "\"" }) || validQuotedLocal(String(local))) {
                return .email
            }
        }
        if surface.contains("/") || surface.contains("\\") || surface.hasPrefix(".") { return .path }
        if surface.contains("_") || surface.hasPrefix("--") { return .identifier }
        return nil
    }

    private static func validQuotedLocal(_ local: String) -> Bool {
        guard local.count >= 2, local.first == "\"", local.last == "\"" else { return false }
        var escaped = false
        for ch in local.dropFirst().dropLast() {
            guard !ch.isNewline else { return false }
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true }
            else if ch == "\"" { return false }
        }
        return !escaped
    }

    /// Formatting is not part of phone identity. Domestic admission is limited
    /// to Turkish 0 + geographic/mobile prefixes, not arbitrary digit groups.
    public static func normalizedPhone(_ surface: String) -> String? {
        guard surface.count <= 40 else { return nil }
        let international = surface.hasPrefix("+")
        guard international || surface.hasPrefix("0") || surface.hasPrefix("(0") else { return nil }
        var digits = international ? "+" : ""
        var parentheses = 0
        for ch in (international ? surface.dropFirst() : surface[...]) {
            if ch.isASCII && ch.isNumber { digits.append(ch) }
            else if ch == "(" { parentheses += 1; if parentheses > 1 { return nil } }
            else if ch == ")" { parentheses -= 1; if parentheses < 0 { return nil } }
            else if !" -. ".contains(ch) { return nil }
        }
        guard parentheses == 0, digits.count > 1 else { return nil }
        if international {
            guard digits.dropFirst().first != "0" else { return nil }
        } else {
            guard digits.count <= 11, digits.first == "0",
                  let prefix = digits.dropFirst().first, "2345".contains(prefix) else { return nil }
        }
        return digits
    }

    private static func isDottedIPv4(_ address: String) -> Bool {
        // Network accepts legacy numeric address forms. History must not turn a
        // long card/identifier into an address exception through that parser.
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber }
                && Int($0).map { (0...255).contains($0) } == true
        } && IPv4Address(address) != nil
    }

    private static func validDecimal(_ text: Substring, maximum: Int) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
            && Int(text).map { (0...maximum).contains($0) } == true
    }
}
