import Foundation
import KBMorphology

/// Versioned, local protection vocabulary. Loaded once, with no network or disk
/// access per keystroke; it does not add uncalibrated decoder candidate scores.
enum TechnicalVocabulary {
    static let terms: Set<String> = {
        guard let url = Bundle.module.url(forResource: "technical-terms", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(whereSeparator: \.isNewline).map(String.init))
    }()

    private final class SuffixMatcher: @unchecked Sendable {
        let lock = NSLock()
        let model = MorphologyAutomaton(roots:
        ["a", "e", "u", "ü"].flatMap { vowel in
            ["", "t", "n"].map { ending in
                Root("x", pos: .noun, lexCost: 0, pronunciation: vowel + ending)
            }
        })
    }
    private static let suffixMatcher = SuffixMatcher()

    static func contains(_ surface: String) -> Bool {
        let normalized = surface.lowercased()
        if terms.contains(normalized) { return true }
        guard normalized.count <= 64 else { return false }
        // Foreign identifiers have several spoken readings. Protect an actual
        // typed nominal suffix under any regular harmony class; this does not
        // generate replacement candidates or assert a preferred spelling.
        let chars = Array(normalized)
        suffixMatcher.lock.lock()
        defer { suffixMatcher.lock.unlock() }
        let suffixModel = suffixMatcher.model
        guard chars.count > 3 else { return false }
        for end in 3..<chars.count where terms.contains(String(chars[..<end])) {
            var states = Set(suffixModel.startStates())
            for ch in "x" + String(chars[end...]) {
                states = Set(states.flatMap { suffixModel.arcs(from: $0)
                    .filter { $0.symbol == ch }.map(\.target) })
                if states.isEmpty || states.count > 256 { break }
            }
            if states.count <= 256 && states.contains(where: { suffixModel.isAccepting($0) }) { return true }
        }
        return false
    }
}
