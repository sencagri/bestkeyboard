import Foundation

extension TurkishMorphotactics {
    /// Audited continuation families. These rules keep conditional, causative,
    /// converb and derived nominal stages separate instead of returning to an
    /// unrestricted root state. IDs are metadata; nodes use dense indices.
    static let coverageSuffixes: [Suffix] = {
        var result: [Suffix] = []
        var next: UInt16 = 1000
        func pieces(_ pattern: String) -> [Suffix.Piece] {
            pattern.map {
                switch $0 {
                case "A": return .archiA
                case "I": return .archiI
                case "D": return .archiD
                case "C": return .archiC
                case "Y": return .bufferIfVowel("y")
                default: return .literal($0)
                }
            }
        }
        func add(_ name: String, _ pattern: String, from: Continuation, to: Continuation,
                 cost: Double = 1.8, vowel: Bool? = nil, alternation: Phonology.Alternation? = nil) {
            result.append(Suffix(id: next, name: name, pieces: pieces(pattern), from: from, to: to,
                                 cost: cost, finalAlternation: alternation, startsWithVowelSound: vowel))
            next += 1
        }
        func copy(_ suffix: Suffix, from: Continuation, removeLexicalClass: Bool = false) {
            result.append(Suffix(id: next, name: suffix.name + "·" + String(describing: from),
                                 pieces: suffix.pieces, from: from, to: suffix.to, cost: suffix.cost,
                                 finalAlternation: suffix.finalAlternation,
                                 startsWithVowelSound: suffix.startsWithVowelSoundOverride,
                                 requiresAorist: removeLexicalClass ? nil : suffix.requiresAorist,
                                 requiresCausative: suffix.requiresCausative, isProgressive: suffix.isProgressive))
            next += 1
        }
        // Conditional takes short person endings, then compound tense only
        // before a person has already been selected.
        for suffix in nominalSuffixes where (80...84).contains(suffix.id) { copy(suffix, from: .afterConditional) }
        add("conditional-past", "YDI", from: .afterConditional, to: .afterPastTense, vowel: false)
        add("conditional-evidential", "YmIş", from: .afterConditional, to: .afterTense, vowel: false)

        add("optative-1sg", "YAyIm", from: .verbRoot, to: .terminal)
        add("converb-dikce", "DIkCA", from: .verbRoot, to: .terminal)
        add("converb-meksizin", "mAksIzIn", from: .verbRoot, to: .terminal)
        for state: Continuation in [.afterTense, .afterNegativeAorist] {
            add("converb-ken", "ken", from: state, to: .terminal, vowel: false)
        }
        // -ince can take the bounded -ye continuation: gelinceye kadar.
        add("converb-inceye", "YIncAyA", from: .verbRoot, to: .terminal)
        let negativeIDs: Set<UInt16> = [100, 101, 102, 103, 104, 110, 121, 122, 132, 135, 136, 137]
        for suffix in verbalSuffixes + converbSuffixes + participleSuffixes where negativeIDs.contains(suffix.id) {
            copy(suffix, from: .afterNegation)
        }
        add("negative-optative-1sg", "YAyIm", from: .afterNegation, to: .terminal)
        add("negative-converb-dikce", "DIkCA", from: .afterNegation, to: .terminal)
        add("negative-converb-inceye", "YIncAyA", from: .afterNegation, to: .terminal)

        let nominalStates: [Continuation] = [.nounRoot, .afterPlural, .afterPossessive, .afterPossessive3,
                                             .afterLocative, .afterGenitive, .afterNominalCase]
        for state in nominalStates {
            add("comitative", "YlA", from: state, to: .afterConverb, vowel: false)
            add("equative", "CA", from: state, to: .afterConverb, vowel: false)
            add("assertive", "DIr", from: state, to: .terminal, vowel: false)
            for suffix in nominalSuffixes where [70, 71, 72, 74].contains(suffix.id) { copy(suffix, from: state) }
        }
        for state: Continuation in [.afterTense, .afterPerson, .afterNegativeAorist] {
            add("assertive", "DIr", from: state, to: .terminal, vowel: false)
        }
        for suffix in copulaSuffixes where suffix.from == .nounRoot { copy(suffix, from: .afterConverb) }
        // One nominal derivation stage. Inflection remains productive after it,
        // but derivation cannot recursively feed itself or a verb/root cycle.
        for (name, pattern, alt) in [("with", "lI", Optional<Phonology.Alternation>.none),
                                     ("without", "sIz", nil), ("occupation", "CI", nil), ("nominalization", "lIk", .kToĞ),
                                     ("diminutive", "CIk", .kToĞ)] {
            add(name, pattern, from: .nounRoot, to: .afterDerivedNominal, cost: 2.8,
                vowel: false, alternation: alt)
        }
        let nominalRules = nominalSuffixes + copulaSuffixes + result
        for suffix in nominalRules where suffix.from == .nounRoot && suffix.to != .afterDerivedNominal {
            copy(suffix, from: .afterDerivedNominal)
        }
        // The new passive stem inherits the audited added verb inflections.
        let additions = result.filter { $0.from == .verbRoot }
        for suffix in additions + negativeAbilityForms { copy(suffix, from: .afterPassive) }
        for suffix in verbalSuffixes where suffix.id == 90 { copy(suffix, from: .afterPassive, removeLexicalClass: true) }
        // A causative stem has its own -Ir aorist. It cannot accidentally reuse
        // the original root's -Ar class or repeat an unbounded causative chain.
        let verbRules = nominalSuffixes + verbalSuffixes + converbSuffixes + participleSuffixes
            + negativeAbilityForms + voiceSuffixes + additions
        for suffix in verbRules where suffix.from == .verbRoot && suffix.to != .afterCausative
            && suffix.requiresAorist != .ar && suffix.requiresCausative == nil {
            copy(suffix, from: .afterCausative, removeLexicalClass: true)
        }
        // -(y)Iver: linker harmony belongs to the original verb, while the
        // fixed auxiliary ver determines subsequent harmony and -Ir aorist.
        // Keep a distinct stage so this cannot recurse into repeated -iver
        // or reopen voice derivation. Add it after the other stage copies.
        let hastiveInflections = nominalSuffixes + verbalSuffixes + converbSuffixes
            + participleSuffixes + negativeAbilityForms + result
        add("hastive", "YIver", from: .verbRoot, to: .afterHastive, cost: 2.8)
        for suffix in hastiveInflections where suffix.from == .verbRoot
            && suffix.to != .afterCausative && suffix.to != .afterPassive
            && suffix.requiresAorist != .ar && suffix.requiresCausative == nil {
            copy(suffix, from: .afterHastive, removeLexicalClass: true)
        }
        return result
    }()
}
