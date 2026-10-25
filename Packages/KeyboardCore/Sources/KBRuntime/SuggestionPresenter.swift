import Foundation
import KBLexicon
import KBDecoder
import KBLearning
import KBFoundation

/// Öneri çubuğunun **içeriği** — decoder adaylarından ve genişletmelerden
/// kullanıcının gördüğü listeyi kuran saf kural.
///
/// Koordinatörün durumuna bakmıyor: adayları, yazılan yüzeyi ve genişletme
/// haritasını alıp listeyi döndürüyor. Kural tek yerde, çünkü listeyi iki
/// tüketici okuyor — UI (dokunulacak yüzeyler) ve kayıt (gösterilenlerin
/// anlık görüntüsü) — ve ikisi farklı listeye bakarsa kayıt kullanıcının
/// görmediği bir şeyi "gösterildi" diye yazar.
struct SuggestionPresenter {

    /// Kazanandan bu kadar geride kalan aday gösterilmez — **UI politikası**,
    /// skor sözleşmesinin parçası değil.
    var window: Double

    static func withoutCircumflex(_ word: String) -> String {
        word.replacingOccurrences(of: "â", with: "a")
            .replacingOccurrences(of: "î", with: "i")
            .replacingOccurrences(of: "û", with: "u")
            .replacingOccurrences(of: "Â", with: "A")
            .replacingOccurrences(of: "Î", with: "İ")
            .replacingOccurrences(of: "Û", with: "U")
    }

    /// A single accidental repeat has an exact, local explanation. Look at
    /// the full shown set before spare slots are consumed by phrase repairs.
    static func removesDuplicate(_ candidate: String, from typed: String) -> Bool {
        let input = Array(TurkishText.key(typed))
        let output = Array(TurkishText.key(candidate))
        guard input.count == output.count + 1, input.count >= 2 else { return false }
        for index in 1..<input.count where input[index] == input[index - 1] {
            if (Array(input[..<index]) + input[(index + 1)...]).elementsEqual(output) {
                return true
            }
        }
        return false
    }

    /// A whole-word candidate may precede a one-boundary repair only when
    /// it is itself within one letter edit (including an adjacent swap).
    static func isSingleEdit(_ candidate: String, to typed: String) -> Bool {
        let input = Array(TurkishText.key(typed))
        let output = Array(TurkishText.key(candidate))
        guard abs(input.count - output.count) <= 1 else { return false }
        let common = min(input.count, output.count)
        guard let i = (0..<common).first(where: { input[$0] != output[$0] }) else {
            return true
        }
        if input.count == output.count {
            if input.dropFirst(i + 1).elementsEqual(output.dropFirst(i + 1)) { return true }
            return i + 1 < common && input[i] == output[i + 1]
                && input[i + 1] == output[i]
                && input.dropFirst(i + 2).elementsEqual(output.dropFirst(i + 2))
        }
        if input.count > output.count {
            return input.dropFirst(i + 1).elementsEqual(output.dropFirst(i))
        }
        return input.dropFirst(i).elementsEqual(output.dropFirst(i + 1))
    }

    /// A credible split must not leave unrelated generated roots in spare
    /// slots. Allow a few letter errors, including nearby inflections.
    static func isNearby(_ candidate: String, to typed: String) -> Bool {
        let input = Array(TurkishText.key(typed))
        let output = Array(TurkishText.key(candidate))
        let budget = max(2, input.count / 4)
        guard abs(input.count - output.count) <= budget else { return false }
        var previous = Array(0...output.count)
        for (i, letter) in input.enumerated() {
            var row = [i + 1]
            for (j, other) in output.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1,
                               previous[j] + (letter == other ? 0 : 1)))
            }
            guard row.min()! <= budget else { return false }
            previous = row
        }
        return previous[output.count] <= budget
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    func shown(_ candidates: [DecodeResult]) -> [DecodeResult] {
        guard let best = candidates.first else { return [] }
        return candidates.filter { $0.cost - best.cost <= window }
    }

    /// Öneri çubuğunda gösterilecek **yüzeyler** — adaylar + genişletmeler.
    ///
    /// Genişletmeler (§4.D) listenin **sonuna** eklenir ve maliyet
    /// karşılaştırmasına girmez: onlar bir sıralama adayı değil, ayrı bir
    /// teklif. `slm` yazan kullanıcıya `selam` gösterilir ama `slm` kazanan
    /// olarak kalır.
    ///
    /// Otomatik uygulanmaları **imkânsız**: düzeltme kararı yalnız decoder
    /// adaylarına bakıyor ve `slm` gayrıresmî sözlükte olduğu için zaten
    /// `θ = ∞` alıyor (§8 bilinen kelime koruması). Yani kural iki bağımsız
    /// yerde tutuluyor.
    ///
    /// - Parameter typed: kullanıcının **yazdığı** yüzey. Genişletme oradan
    ///   aranır — düzeltilmiş adaydan değil. `slm` yazıp `selam` görmek
    ///   isteniyor; decoder'ın ürettiği bir şeyin açılımı değil.
    func surfaces(shown: [DecodeResult], typed: String,
                  expansions: ExpansionMap?, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var decoded = shown.map(\.word)
        // When both spellings are already available, follow an unaccented
        // input's spelling preference. Keep real candidates and their scores;
        // this only changes display order, never automatic correction.
        if !typed.isEmpty, !TurkishText.key(typed).contains(where: { "âîû".contains($0) }) {
            for index in decoded.indices {
                let plain = Self.withoutCircumflex(decoded[index])
                if plain != decoded[index],
                   let later = decoded.indices.dropFirst(index + 1).first(where: { decoded[$0] == plain }) {
                    decoded.insert(decoded.remove(at: later), at: index)
                }
            }
        }
        guard !typed.isEmpty else { return Array(decoded.prefix(limit)) }
        // İlk yuva daima yazılan yüzeyindir; sözlük/beam üyeliği gerekmez.
        let alternatives = decoded.filter { $0 != typed }
        let extras = (expansions?.expansions(of: typed) ?? [])
            .filter { $0 != typed && !alternatives.contains($0) }
        let remaining = limit - 1
        let reserved = min(extras.count, max(0, remaining - (alternatives.isEmpty ? 0 : 1)))
        return [typed] + Array(alternatives.prefix(remaining - reserved))
            + Array(extras.prefix(reserved))
    }

    /// Yüzeyleri **kimlik ve kaynaklarıyla** sınıflandırır.
    ///
    /// Yazılan yüzey açık onay; kalan yüzeyler decoder adayı veya genişletmedir.
    func suggestions(surfaces: [String], shown: [DecodeResult],
                     typed: String) -> [InputCoordinator.Suggestion] {
        let byWord = Dictionary(shown.map { ($0.word, $0) },
                                uniquingKeysWith: { a, _ in a })
        return surfaces.map { surface in
            if surface == typed {
                return .init(surface: surface, origin: .literal, id: "literal:" + surface)
            }
            if let c = byWord[surface] {
                let id = InputCoordinator.candidateID(word: c.word, source: c.source)
                return .init(surface: surface, origin: .candidate(id: id), id: id)
            }
            return .init(surface: surface, origin: .expansion(trigger: typed),
                         id: InputCoordinator.expansionID(surface: surface))
        }
    }
}

// MARK: - Koordinatörün öneri yüzeyi

extension InputCoordinator {

    /// Gösterilen bir öneri — **kimliği ve kaynağıyla**.
    ///
    /// `suggestionSurfaces` yalnız `[String]` veriyordu ve UI dokunulan yüzey
    /// için `id = surface`, `origin = .candidate` **uyduruyordu**. Oysa ayrım
    /// motorun içinde zaten yapılıyor: `slm` yazıp `selam`'a dokunulduğunda
    /// gerçek olgu `id = "expansion:selam"`, origin genişletme ve tetikleyici
    /// `slm`. Kayıt bunun yerine aday kimliği yazıyordu ve metin doğru olduğu
    /// için hiçbir test görmüyordu.
    ///
    /// İki yerde sınıflandırmak zaten aynı hatanın ikinci kopyasıydı; tek
    /// kaynak `SuggestionPresenter`.
    public struct Suggestion: Equatable, Sendable {
        public let surface: String
        public let origin: SuggestionOrigin
        /// Kayda giren kimlik. Aday için `word#source`, genişletme için
        /// `expansion:<yüzey>` — `CandidateSnapshot.id` ile aynı üretim.
        public let id: String

        public init(surface: String, origin: SuggestionOrigin, id: String) {
            self.surface = surface; self.origin = origin; self.id = id
        }
    }

    /// Aday kimliğinin **tek** üretimi.
    public static func candidateID(word: String, source: UInt8) -> String {
        "\(word)#\(source)"
    }

    /// Genişletme kimliğinin **tek** üretimi.
    public static func expansionID(surface: String) -> String {
        "expansion:\(surface)"
    }

    var presenter: SuggestionPresenter { SuggestionPresenter(window: suggestionWindow) }

    public func candidates(topK: Int = 3) -> [DecodeResult] {
        guard let inc = incremental, !session.touches.isEmpty else { return [] }
        return inc.results(topK: topK)
    }

    func boundaryRepairs() -> [String] {
        guard !session.isDetached, let engine else { return [] }
        return WordBoundaryRepair.suggestions(for: session.literalSuggestionSurface,
                                               channel: engine.literalChannel,
                                               personalCost: { isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
    }

    /// Exact local repairs can fall out of the spatial beam. Recover only
    /// vocabulary-backed single-repeat removals as explicit offers; never
    /// invent decoder scores or promote them to automatic winners.
    func lexicalDuplicateRepairs(includeGeneratedLiteral: Bool = false) -> [String] {
        guard !session.isDetached, let channel = engine?.literalChannel else { return [] }
        let surface = session.literalSuggestionSurface
        let word = TurkishText.key(surface)
        let letters = Array(word)
        guard (3...LexiconLimits.maxSurfaceLength + 1).contains(letters.count),
              letters.allSatisfy(\.isLetter),
              (!channel.score(word).isInVocabulary
                || (includeGeneratedLiteral && !channel.hasListedSurface(word))),
              !isKnownPersonalInflection(word) else { return [] }
        var repairs: [(String, Double)] = []
        for index in 1..<letters.count where letters[index] == letters[index - 1] {
            // Preserve expressive runs such as çoook rather than treating
            // their middle letter as an accidental double tap.
            if index > 1 && letters[index - 2] == letters[index] { continue }
            if index + 1 < letters.count && letters[index + 1] == letters[index] { continue }
            let candidate = String(letters[..<index] + letters[(index + 1)...])
            let score = channel.score(candidate)
            guard score.isInVocabulary else { continue }
            repairs.append((candidate, score.lexCost))
        }
        return repairs.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map {
            TurkishText.applying(TurkishText.casing(of: surface), to: $0.0)
        }
    }

    private func presentedSurfaces(shown: [DecodeResult], limit: Int) -> [String] {
        var surfaces = presenter.surfaces(shown: shown, typed: session.literalSuggestionSurface,
                                          expansions: engine?.expansions, limit: limit)
        if limit >= 2 {
            let repairs = boundaryRepairs().filter { $0 != session.literalSuggestionSurface }.prefix(limit - 1)
            let literal = session.literalSuggestionSurface
            if engine?.literalChannel.score(session.literal).isInVocabulary == false,
               let duplicate = shown.first(where: {
                SuggestionPresenter.removesDuplicate($0.word, from: literal)
            })?.word ?? lexicalDuplicateRepairs().first {
                // A duplicate repair and a missing space can explain the same
                // repeated pair (annemmi → annemi / annem mi). Keep that genuine
                // ambiguity, but do not fill a slot by splitting elsewhere or
                // deleting another letter (gereğin inn / başvurunuz un).
                let selectedRepairs = Array(repairs.filter { repair in
                    let parts = repair.split(separator: " ")
                    guard parts.count == 2 else { return false }
                    let sameBoundary = parts.joined() == literal
                        && parts[0].last == parts[1].first
                    // The sole supported single-letter word is the pronoun o.
                    // Preserve ozzaman → o zaman: an extra z beside the intended
                    // space still has an independently meaningful boundary.
                    let pronounBoundary = parts.contains { TurkishText.key(String($0)) == "o" }
                        && TurkishText.key(parts.joined()) == TurkishText.key(duplicate)
                    guard sameBoundary || pronounBoundary else { return false }
                    guard let channel = engine?.literalChannel else { return false }
                    // Structural agreement alone also admits corpus fragments
                    // (saygılarım mla, bağlantısın nı). Require joint lexical
                    // support within a bounded margin of the single-word fix.
                    // Eight cost units retain the ordinary question-particle
                    // controls while rejecting the audited fragment pairs.
                    // This only filters explicit offers, never autocorrection.
                    let lexicalCost = parts.reduce(0.0) { total, part in
                        let word = TurkishText.key(String(part))
                        return total + (isKnownPersonalInflection(word)
                            ? PersonalLexicon.lexCost : channel.score(word).lexCost)
                    }
                    return lexicalCost <= channel.score(TurkishText.key(duplicate)).lexCost + 8.0
                }.prefix(max(0, limit - 2)))
                let remaining = surfaces.filter { candidate in
                    guard candidate != literal && candidate != duplicate,
                          !selectedRepairs.contains(candidate) else { return false }
                    // Once deleting a repeated key gives a known word, do not
                    // fill a spare slot by growing a purely generated form
                    // (gelemeyeceğimm → gelemeyeceğimim). Longer listed or
                    // personal alternatives remain meaningful evidence
                    // (başlatt → başlattı, kannı → kanını). Recognition and
                    // automatic correction are deliberately unaffected.
                    // Generated spare forms must also stay one edit from the
                    // exact repeat repair, retaining randevunuzu beside
                    // randevumuzu without inventing hatırlatışçıları.
                    // Compare length with the repaired word: inserting a different
                    // letter (markettten → marketsten) is not repeat evidence.
                    return (candidate.count <= duplicate.count
                            && SuggestionPresenter.isSingleEdit(candidate, to: duplicate))
                        || engine?.literalChannel.hasListedSurface(TurkishText.key(candidate)) == true
                        || isKnownPersonalInflection(TurkishText.key(candidate))
                }
                return [literal, duplicate] + selectedRepairs
                    + remaining.prefix(max(0, limit - 2 - selectedRepairs.count))
            }
            // A generated inflection may also be a double tap of a common
            // listed word (markettin → marketin) or fixed lexical root
            // (pıttır → pıtır). An exact repeat repair also
            // deserves priority over merely adding a circumflex to that
            // generated literal (ihtilallin → ihtilalin / ihtilâllin).
            // A generated repair with stronger lexical support also deserves
            // a slot: yetkilendirilmemmiş has an infinitive/possessive analysis,
            // but dropping the repeated m yields the cheaper ordinary negative
            // participle yetkilendirilmemiş. Listed literals remain protected by
            // lexicalDuplicateRepairs; keep the literal and automatic scoring.
            if let channel = engine?.literalChannel,
               channel.score(TurkishText.key(literal)).isInVocabulary,
               let duplicate = lexicalDuplicateRepairs(includeGeneratedLiteral: true)
                .first(where: { candidate in
                    channel.hasListedSurface(TurkishText.key(candidate))
                        || channel.hasFixedLexicalSurface(TurkishText.key(candidate))
                        || channel.score(TurkishText.key(candidate)).lexCost
                            < channel.score(TurkishText.key(literal)).lexCost
                        || surfaces.contains { $0 != literal && SuggestionPresenter.withoutCircumflex($0) == literal }
                }) {
                return [literal, duplicate]
                    + surfaces.filter { $0 != literal && $0 != duplicate }.prefix(limit - 2)
            }
            if !repairs.isEmpty {
                // Prefer a known two-word boundary to a generated inflection
                // of an unrelated root (senibseviyorum → webinarcıydım).
                // Keep a dictionary-backed winner ahead only when it is
                // within one letter edit, like the boundary repair itself.
                // Keep both plausible boundaries (seni+n vs senin) when room
                // permits. This is presentation, not autocorrection scoring.
                let literal = session.literalSuggestionSurface
                let relevant = shown.filter { candidate in
                    // Being listed does not make a distant word relevant to
                    // an exact boundary repair (börtübböcek → görünmek).
                    if engine?.decoder.lexicon.sources[Int(candidate.source)].formTrie != nil {
                        return SuggestionPresenter.isNearby(candidate.word, to: literal)
                    }
                    // An unlisted generated form needs equally local evidence
                    // as the boundary repair, not several unrelated changes
                    // (helezkonuşak → helezonmuşsak).
                    return SuggestionPresenter.isSingleEdit(candidate.word, to: literal)
                }
                let alternatives = presenter.surfaces(shown: relevant, typed: literal,
                    expansions: engine?.expansions, limit: limit)
                    .filter { $0 != literal && !repairs.contains($0) }
                let slots = limit - 1 - repairs.count
                let dictionaryWinner = shown.first.map { candidate in
                    engine?.decoder.lexicon.sources[Int(candidate.source)].formTrie != nil
                } ?? false
                if dictionaryWinner, let best = alternatives.first, slots > 0,
                   SuggestionPresenter.isSingleEdit(best, to: literal) {
                    surfaces = [literal, best] + repairs + alternatives.dropFirst().prefix(slots - 1)
                } else {
                    surfaces = [literal] + repairs + alternatives.prefix(slots)
                }
            }
        }
        return surfaces
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    public func shownCandidates() -> [DecodeResult] {
        let literal = session.literalSuggestionSurface
        let letters = Array(TurkishText.key(literal))
        let repeated = zip(letters, letters.dropFirst()).contains { $0 == $1 }
        let ranked = candidates(topK: repeated ? Int.max : 3)
        let shown = presenter.shown(ranked)
        var selected = Array(shown.prefix(3))
        // Keep the normal window for general alternatives. An exact removal
        // of one repeated key is a local repair: retain it from the completed
        // beam even when touch geometry puts it outside the normal window.
        // results already scores/sorts the entire bounded terminal frontier;
        // requesting it does not widen the beam or launch another search.
        // Preserve its real identity and score; this
        // does not promote it to the automatic correction winner.
        if repeated, let duplicate = ranked.first(where: {
            SuggestionPresenter.removesDuplicate($0.word, from: literal)
        }), !selected.contains(where: { $0.word == duplicate.word }) {
            selected.append(duplicate)
        }
        return selected
    }

    /// Öneri çubuğunda gösterilecek yüzeyler — `SuggestionPresenter.surfaces`.
    public func suggestionSurfaces(limit: Int = 3) -> [String] {
        presentedSurfaces(shown: shownCandidates(), limit: limit)
    }

    /// Gösterilen öneriler, kimlik ve kaynaklarıyla.
    public func suggestions(limit: Int = 3) -> [Suggestion] {
        let shown = shownCandidates()
        let surfaces = presentedSurfaces(shown: shown, limit: limit)
        return presenter.suggestions(surfaces: surfaces, shown: shown,
                                     typed: session.literalSuggestionSurface)
    }
}
