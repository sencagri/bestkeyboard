import Foundation

/// Deduplicates repeated boundary callbacks within a host document. Visible
/// context is not a global offset; document changes explicitly reset this state.
public struct HistoryObservation: Sendable {
    public struct Occurrence: Sendable {
        public let id: UUID
        public let token: String
        public let previous: String?
        init(token: String, previous: String?, id: UUID = UUID()) {
            self.id = id; self.token = token; self.previous = previous
        }
    }
    public struct Event: Sendable {
        public let id: UUID
        public let token: String
        public let previous: String?
        public let replacing: String?
        public let retracting: [Occurrence]
        init(token: String, previous: String?, replacing: String? = nil, retracting: [Occurrence] = [], id: UUID) {
            self.id = id
            self.token = token; self.previous = previous
            self.replacing = replacing; self.retracting = retracting
        }
    }
    // Bounded, document-local evidence only. A completed quoted mailbox may
    // reveal that earlier whitespace was internal, not a word boundary.
    private var recent: [(body: String, occurrence: Occurrence)] = []
    private var cancelledOccurrences: [Occurrence] = []
    private var provisional: (body: String, occurrence: Occurrence)?
    private var documentID: UUID?
    private var lastCompletedContext: String?
    private var previousVisibleContext: String?
    private var previousVisibleDocument: String?
    private var consumedSelections: [UUID] = []
    private var explicitTechnicalReceipts: [UUID] = []
    private var observedStart = false
    /// Selecting and confirming existing text is not a new occurrence. Keep
    /// the full visible document witness until an actual text change occurs.
    private var unchangedSelectionDocument: String?
    private var reopenedOccurrence: (body: String, occurrence: Occurrence)?
    private var expectedContinuation: (before: String, after: String?, expected: String, occurrence: Occurrence)?
    private var expectedDeletion: (before: String, after: String?, expected: String)?
    private struct PendingReplacement: Sendable {
        var before: String
        var after: String?
        var deleted: String
        var expected: String
        var occurrences: [Occurrence]
        func matchesPath(_ snapshot: String) -> Bool {
            (before.hasPrefix(snapshot) && snapshot.hasPrefix(deleted))
                || (expected.hasPrefix(snapshot) && snapshot.hasPrefix(deleted))
        }
    }
    private var expectedReplacement: PendingReplacement?
    public init() {}

    /// Observe intermediate edits too: deleting a completed occurrence and
    /// typing it again is new evidence, unlike another separator callback.
    /// Register an actual keyboard delete command before sending it to the host.
    /// A later matching before/after snapshot confirms it; unknown host edits
    /// never inherit this trust. Repeated commands tolerate a stale proxy read.
    public mutating func expectBackwardDeletion(before: String, after: String?, documentID: UUID) {
        if self.documentID == documentID, let pending = expectedDeletion,
           pending.before.hasPrefix(before), before.hasPrefix(pending.expected),
           pending.after == after, !pending.expected.isEmpty {
            expectedDeletion = (pending.before, after, String(pending.expected.dropLast()))
            return
        }
        changed(before: before, documentID: documentID, after: after)
        guard !before.isEmpty else { expectedDeletion = nil; return }
        expectedDeletion = (before, after, String(before.dropLast()))
    }

    /// Only a witnessed insertion directly into a reopened word can supersede
    /// its old occurrence, including punctuation that can extend a technical
    /// token or a Turkish suffix. Completion records the resulting token once,
    /// even when punctuation leaves its normalized spelling unchanged.
    /// Merely restoring whitespace keeps the old evidence.
    public mutating func expectInsertion(_ text: String, before: String, after: String?, documentID: UUID) {
        // A replacement can issue every delete and the insertion before the
        // host acknowledges any intermediate text. Keep the combined result,
        // rather than discarding the delete witness when the new text arrives.
        if self.documentID == documentID, var pending = expectedReplacement,
           pending.after == after, pending.matchesPath(before) {
            guard pending.expected.count - pending.deleted.count + text.count <= 256 else {
                expectedReplacement = nil
                return
            }
            pending.expected += text
            expectedReplacement = pending
            return
        }
        if self.documentID == documentID, let deletion = expectedDeletion,
           deletion.after == after, deletion.before.hasPrefix(before), before.hasPrefix(deletion.expected),
           !text.isEmpty, text.count <= 256 {
            let occurrences = recent.filter { !deletion.expected.hasPrefix($0.body) }.map(\.occurrence)
            if !occurrences.isEmpty {
                expectedReplacement = PendingReplacement(before: deletion.before, after: after,
                    deleted: deletion.expected, expected: deletion.expected + text, occurrences: occurrences)
                expectedDeletion = nil
                expectedContinuation = nil
                reopenedOccurrence = nil
                return
            }
        }
        // Consecutive commands may observe the same stale host proxy. Keep the
        // complete expected insertion, just as repeated deletions do; only a
        // matching later snapshot authorizes retracting the old occurrence.
        if self.documentID == documentID, let pending = expectedContinuation,
           before.hasPrefix(pending.before), pending.expected.hasPrefix(before), pending.after == after {
            guard pending.expected.count - pending.before.count + text.count <= PersonalHistory.maxTokenLength * 2 else {
                expectedContinuation = nil
                reopenedOccurrence = nil
                return
            }
            expectedContinuation = (pending.before, after, pending.expected + text, pending.occurrence)
            return
        }
        changed(before: before, documentID: documentID, after: after)
        guard let first = text.first, !first.isWhitespace,
              let reopenedOccurrence, reopenedOccurrence.body == before else {
            expectedContinuation = nil
            return
        }
        expectedContinuation = (before, after, before + text, reopenedOccurrence.occurrence)
    }

    /// Drain occurrences invalidated by a witnessed deletion or continuation
    /// after removing their boundary.
    /// Unobserved host changes and cursor movement never authorize retraction.
    public mutating func takeCancelledOccurrences() -> [Occurrence] {
        defer { cancelledOccurrences.removeAll() }
        return cancelledOccurrences
    }

    public mutating func cancelExpectedDeletion() {
        expectedDeletion = nil
        expectedReplacement = nil
    }

    public mutating func changed(before: String, documentID: UUID, after: String? = nil, selected: String? = nil) {
        let visibleDocument = before + (selected ?? "") + (after ?? "")
        // An explicit completion owns its occurrence even when the host field
        // predates observation. An unchanged full snapshot proves cursor-only
        // movement; it must not discard that receipt or imply an actual edit.
        let ownsExplicitOccurrence = recent.contains { explicitTechnicalReceipts.contains($0.occurrence.id) }
        let stableObservedDocument = self.documentID == documentID && (observedStart || ownsExplicitOccurrence)
            && previousVisibleDocument == visibleDocument
        if self.documentID != documentID {
            unchangedSelectionDocument = nil
            self.documentID = documentID
            lastCompletedContext = nil
            provisional = nil
            recent.removeAll()
            expectedDeletion = nil
            expectedContinuation = nil
            expectedReplacement = nil
            reopenedOccurrence = nil
            previousVisibleContext = nil
            previousVisibleDocument = nil
            consumedSelections.removeAll()
            explicitTechnicalReceipts.removeAll()
            observedStart = before.isEmpty
        }
        if unchangedSelectionDocument != visibleDocument { unchangedSelectionDocument = nil }
        if let selected, !selected.isEmpty, after != nil {
            unchangedSelectionDocument = visibleDocument
        }
        if let replacement = expectedReplacement {
            if selected?.isEmpty != false, replacement.after == after,
               replacement.expected == before, replacement.expected != replacement.before {
                cancelledOccurrences += replacement.occurrences
                let ids = Set(replacement.occurrences.map(\.id))
                recent.removeAll { ids.contains($0.occurrence.id) }
                if let provisional, ids.contains(provisional.occurrence.id) { self.provisional = nil }
                lastCompletedContext = nil
                expectedReplacement = nil
            } else if selected?.isEmpty == false || replacement.after != after || !replacement.matchesPath(before) {
                expectedReplacement = nil
            }
        }
        // A partial acknowledgement still proves the observed prefix of the
        // issued deletions. Keep the remaining command witness until completion.
        let matchesDeletionPath = selected?.isEmpty != false && (expectedDeletion.map {
            $0.before.hasPrefix(before) && before.hasPrefix($0.expected) && $0.after == after
        } ?? false)
        let confirmedDeletion = matchesDeletionPath && expectedDeletion?.before != before
        let pendingDeletion = matchesDeletionPath && expectedDeletion?.expected != before
        if !pendingDeletion { expectedDeletion = nil }
        if let continuation = expectedContinuation {
            if selected?.isEmpty != false && continuation.expected == before && continuation.after == after {
                cancelledOccurrences.append(continuation.occurrence)
                recent.removeAll { $0.occurrence.id == continuation.occurrence.id }
                if provisional?.occurrence.id == continuation.occurrence.id { provisional = nil }
                lastCompletedContext = nil
                reopenedOccurrence = nil
                expectedContinuation = nil
            } else if !before.hasPrefix(continuation.before) || !continuation.expected.hasPrefix(before)
                        || continuation.after != after || selected?.isEmpty == false {
                expectedContinuation = nil
            }
            // A host can acknowledge only part of the issued insertion first.
            // Retain the witness until the full expected result is observed.
        }
        if reopenedOccurrence?.body != before || selected?.isEmpty == false { reopenedOccurrence = nil }
        if confirmedDeletion && !stableObservedDocument {
            reopenedOccurrence = recent.last { $0.body == before }
        }
        if confirmedDeletion && !stableObservedDocument {
            cancelledOccurrences += recent.filter { !before.hasPrefix($0.body) }.map(\.occurrence)
            // Mirrors the bounded receipt lifetime even if a caller never drains.
            if cancelledOccurrences.count > PersonalHistory.maxTokenLength * 2 {
                cancelledOccurrences.removeFirst(cancelledOccurrences.count - PersonalHistory.maxTokenLength * 2)
            }
        }
        if before.isEmpty {
            observedStart = true
            if !stableObservedDocument { recent.removeAll() }
        }
        else if let previousVisibleContext, !before.hasPrefix(previousVisibleContext) {
            if !confirmedDeletion && !stableObservedDocument { observedStart = false }
            // Keep evidence for the unchanged prefix, even when later text was
            // edited. Occurrences whose own prefix disappeared are invalid.
            if !stableObservedDocument { recent.removeAll { !before.hasPrefix($0.body) } }
        }
        if !stableObservedDocument, let provisional, !before.hasPrefix(provisional.body) { self.provisional = nil }
        previousVisibleContext = before
        previousVisibleDocument = visibleDocument
        if let previous = lastCompletedContext, !before.hasPrefix(previous) {
            lastCompletedContext = nil
        }
    }

    public struct SelectionReplacement: Sendable {
        fileprivate let id: UUID
        fileprivate let documentID: UUID
        fileprivate let before: String
        fileprivate let selected: String
        fileprivate let after: String?
        fileprivate let anchored: Bool
        fileprivate let trailingPunctuation: String
        fileprivate let originalToken: String
        fileprivate let occurrences: [(body: String, occurrence: Occurrence)]
    }

    public mutating func selectionReplacement(before: String, selected: String, after: String?,
                                             documentID: UUID) -> SelectionReplacement? {
        changed(before: before, documentID: documentID, after: after, selected: selected)
        let word = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, PersonalHistory.isWord(word) else { return nil }
        // Inspect whole adjacent fragments. A dot before an extension or an
        // @ inside an email must never turn a selected component into a word.
        let left = selected.first?.isWhitespace == true ? "" : String(before.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        let right = selected.last?.isWhitespace == true ? "" : String((after ?? "").prefix(while: { !$0.isWhitespace }))
        let opening: Set<Character> = ["(", "«", "“", "\""]
        let closing: Set<Character> = [")", "»", "”", "\"", ",", ".", "!", "?", ";", ":", "…"]
        let singleQuoted = left == "'" && right == "'"
        let proseOpening = left.allSatisfy { character in
            opening.contains(character) || character.unicodeScalars.allSatisfy {
                $0.properties.generalCategory == .openPunctuation
                    || $0.properties.generalCategory == .initialPunctuation
            }
        }
        let proseClosing = right.allSatisfy { character in
            closing.contains(character) || character.unicodeScalars.allSatisfy {
                $0.properties.generalCategory == .closePunctuation
                    || $0.properties.generalCategory == .finalPunctuation
            }
        }
        guard singleQuoted || (proseOpening && proseClosing) else { return nil }
        let originalTokens = PersonalHistory.tokenize(left + word + right)
        guard originalTokens.count == 1, let originalToken = originalTokens.first else { return nil }
        return SelectionReplacement(id: UUID(), documentID: documentID, before: before,
            selected: selected, after: after, anchored: observedStart,
            trailingPunctuation: right, originalToken: originalToken, occurrences: recent)
    }

    /// Selection edits carry an immutable witness captured before the host edit.
    /// Old counts are removed only for occurrences anchored to the observed start.
    public mutating func completedSelection(_ witness: SelectionReplacement, inserted: String,
                                           resultingBefore: String, resultingAfter: String?, documentID: UUID) -> [Event] {
        guard self.documentID == documentID, witness.documentID == documentID,
              !consumedSelections.contains(witness.id), inserted.count <= 256,
              resultingBefore == witness.before + inserted, resultingAfter == witness.after else { return [] }
        let words = inserted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...8).contains(words.count), words.allSatisfy({ PersonalHistory.isWord($0) && $0.count <= PersonalHistory.maxTokenLength }) else { return [] }
        let oldWord = witness.originalToken
        // Confirming the same word is not another occurrence. A genuinely
        // different single-word correction needs the same owned-count and
        // incoming/outgoing pair reconciliation as a multiword repair.
        guard words.count != 1 || PersonalHistory.tokenize(words[0]).first != oldWord else { return [] }
        let oldBody = String((witness.before + witness.selected + witness.trailingPunctuation).reversed().drop(while: \.isWhitespace).reversed())
        let owned = witness.anchored ? witness.occurrences.first { $0.body == oldBody && $0.occurrence.token == oldWord } : nil
        var retired = owned.map { [$0.occurrence] } ?? []
        var outgoing: (body: String, occurrence: Occurrence)?
        if owned != nil, let rawAfter = witness.after {
            let after = String(rawAfter.dropFirst(witness.trailingPunctuation.count))
            let gap = String(after.prefix(while: \.isWhitespace))
            let next = String(after.dropFirst(gap.count).prefix(while: { !$0.isWhitespace }))
            // Keep the raw span for occurrence identity, but use the same
            // punctuation normalization as ordinary completed-word learning.
            let nextWords = PersonalHistory.tokenize(next)
            if !gap.contains(where: \.isNewline), !witness.selected.contains(where: \.isNewline),
               nextWords.count == 1, let nextWord = nextWords.first, PersonalHistory.isWord(nextWord) {
                let body = witness.before + witness.selected + witness.trailingPunctuation + gap + next
                if let prior = witness.occurrences.first(where: {
                    $0.body == body && $0.occurrence.previous == oldWord && $0.occurrence.token == nextWord
                }) {
                    retired.append(prior.occurrence)
                    let finalToken = PersonalHistory.tokenize(inserted + witness.trailingPunctuation).last
                    outgoing = (witness.before + inserted + witness.trailingPunctuation + gap + next, Occurrence(token: prior.occurrence.token, previous: finalToken))
                }
            }
        }
        consumedSelections.append(witness.id)
        if consumedSelections.count > 128 { consumedSelections.removeFirst() }
        let retiredIDs = Set(retired.map(\.id))
        let oldPrefix = witness.before + witness.selected
        let retained = witness.occurrences.filter { !retiredIDs.contains($0.occurrence.id) }.map { item in
            (body: item.body.hasPrefix(oldPrefix) ? witness.before + inserted + item.body.dropFirst(oldPrefix.count) : item.body,
             occurrence: item.occurrence)
        }
        recent.removeAll { retiredIDs.contains($0.occurrence.id) }
        var context = witness.before
        var events: [Event] = []
        var addedWord = false
        let completedText = inserted.last?.isWhitespace == true ? inserted : inserted + witness.trailingPunctuation + " "
        for character in completedText {
            context.append(character)
            if character.isWhitespace {
                if addedWord, let event = completed(before: context, documentID: documentID, after: resultingAfter) { events.append(event) }
                addedWord = false
            } else { addedWord = true }
        }
        if let first = events.first {
            events[0] = Event(token: first.token, previous: first.previous, retracting: retired + first.retracting, id: first.id)
        }
        let insertedOccurrences = recent
        changed(before: resultingBefore, documentID: documentID, after: resultingAfter)
        var seen: Set<UUID> = []
        recent = (retained + insertedOccurrences).filter { seen.insert($0.occurrence.id).inserted }
        if let outgoing {
            recent.append(outgoing)
            events.append(Event(token: outgoing.occurrence.token, previous: outgoing.occurrence.previous, id: outgoing.occurrence.id))
        }
        recent = Array(recent.suffix(128))
        observedStart = witness.anchored
        return events
    }

    public mutating func completed(before: String, documentID: UUID, after: String? = nil) -> Event? {
        completed(before: before, documentID: documentID, after: after, confirmedTechnicalToken: nil)
    }

    private mutating func completed(before: String, documentID: UUID, after: String?, confirmedTechnicalToken: String?) -> Event? {
        changed(before: before, documentID: documentID, after: after)
        let body = String(before.reversed().drop(while: \.isWhitespace).reversed())
        // Confirmation may leave the cursor directly after the selected value,
        // before its punctuation. Remember that unchanged prefix even without
        // a separator, so the next newline cannot count it again or retract
        // unrelated later receipts as though the value had just been typed.
        if !body.isEmpty, let after, unchangedSelectionDocument == before + after {
            // A confirmed substring can still have the rest of its word on
            // the right. A later inserted separator creates a genuinely new
            // boundary there and must remain eligible for learning.
            let rightFragment = after.prefix(while: { !$0.isWhitespace })
            if before.last?.isWhitespace == true
                || rightFragment.allSatisfy({ character in
                    ",.!?;:…'\"".contains(character)
                        || character.unicodeScalars.allSatisfy {
                            $0.properties.generalCategory == .closePunctuation
                                || $0.properties.generalCategory == .finalPunctuation
                        }
                }) {
                lastCompletedContext = body
            }
            return nil
        }
        guard before.last?.isWhitespace == true else { return nil }
        guard !body.isEmpty, body != lastCompletedContext else { return nil }
        // Cursor movement may clear the single-boundary cache, while the
        // anchored document or explicit choice still owns this exact occurrence. Real edits
        // invalidate incompatible receipts in changed(before:...), and another
        // occurrence has a different full prefix even if its word is identical.
        if recent.contains(where: { $0.body == body && (observedStart || explicitTechnicalReceipts.contains($0.occurrence.id)) }) {
            lastCompletedContext = body
            return nil
        }
        // Pair evidence is confined to the line on which this token was typed.
        let line = String(body.split(whereSeparator: \.isNewline).last ?? "")
        // Prose punctuation finalizes the number but is not part of its
        // identity. Try the intact span first so balanced phone parentheses
        // retain their meaning; then peel only trailing punctuation.
        var phoneLine = line
        var trailingPunctuation = 0
        var candidate = TechnicalTextSpan.phoneSuffix(in: phoneLine)
        while candidate == nil, phoneLine.last?.isPunctuation == true {
            phoneLine.removeLast()
            trailingPunctuation += 1
            candidate = TechnicalTextSpan.phoneSuffix(in: phoneLine)
        }
        if let candidate {
            let phone = String(candidate.reversed().drop(while: { ".-".contains($0) }).reversed())
            // Short domestic/international groups are pending, not independent
            // numeric entries. A growing valid phone supersedes one occurrence.
            guard TechnicalTokenKind.classify(phone) == .phone else { return nil }
            let start = String(body.dropLast(candidate.count + trailingPunctuation))
            guard observedStart || !start.isEmpty || confirmedTechnicalToken == phone else { return nil }
            let replaced = provisional.flatMap { prior -> Occurrence? in
                guard body.hasPrefix(prior.body),
                      String(prior.body.dropLast(prior.occurrence.token.count)) == start else { return nil }
                return prior.occurrence
            }
            if let replaced { recent.removeAll { $0.occurrence.id == replaced.id } }
            recent.removeAll { body.count - $0.body.count > PersonalHistory.maxTokenLength }
            let occurrence = Occurrence(token: phone, previous: PersonalHistory.tokenize(start).last)
            recent.append((body, occurrence))
            // Only the current boundary finalizes this occurrence. Newlines
            // earlier in the message must not disable later phone extensions.
            let boundaryEndsLine = before.reversed().prefix(while: \.isWhitespace).contains(where: \.isNewline)
            provisional = candidate == phone && trailingPunctuation == 0 && !boundaryEndsLine ? (body, occurrence) : nil
            lastCompletedContext = body
            return Event(token: phone, previous: occurrence.previous, replacing: replaced?.token,
                         retracting: replaced.map { [$0] } ?? [], id: occurrence.id)
        }
        provisional = nil
        // A separate closing quote/punctuation fragment is not another word
        // occurrence. Grouped phone handling above still owns its formatting.
        let lastPiece = String(line.split(whereSeparator: \.isWhitespace).last ?? "")
        guard !PersonalHistory.tokenize(lastPiece).isEmpty else {
            lastCompletedContext = body
            return nil
        }
        let words = PersonalHistory.tokenize(line)
        guard let token = words.last else { return nil }
        // A lone address at the left edge may be only the visible suffix of a
        // longer host token. Require an observed start or a preceding token.
        if words.count == 1, PersonalHistory.isRecallable(token), !observedStart, confirmedTechnicalToken != token { return nil }
        let previous = words.count >= 2 ? words[words.count - 2] : nil
        var retracting: [Occurrence] = []
        if token.hasPrefix("\""), TechnicalTokenKind.classify(token) == .email,
           let range = body.range(of: token, options: .backwards) {
            let openingContext = String(body[..<range.lowerBound]) + "\""
            retracting = recent.filter { $0.body.hasPrefix(openingContext) }.map(\.occurrence)
            recent.removeAll { $0.body.hasPrefix(openingContext) }
        }
        recent.removeAll { body.count - $0.body.count > PersonalHistory.maxTokenLength }
        let occurrence = Occurrence(token: token, previous: previous)
        recent.append((body, occurrence))
        lastCompletedContext = body
        return Event(token: token, previous: previous, retracting: retracting, id: occurrence.id)
    }

    /// A keyboard-owned phrase replacement, verified against both host snapshots.
    /// Only the inserted span is replayed; existing host words are never relearned.
    /// Selection edits use different cursor semantics and must not enter this API.
    public mutating func completedReplacement(before: String, after: String?,
                                              resultingBefore: String, resultingAfter: String?,
                                              replacing: String, inserted: String,
                                              documentID: UUID) -> [Event] {
        guard self.documentID == documentID, !replacing.isEmpty,
              !replacing.contains(where: \.isWhitespace), before.hasSuffix(replacing),
              after == resultingAfter, inserted.count <= 256,
              inserted.last?.isWhitespace == true else { return [] }
        let prefix = String(before.dropLast(replacing.count))
        guard prefix.isEmpty || prefix.last?.isWhitespace == true,
              resultingBefore == prefix + inserted else { return [] }
        let words = inserted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...8).contains(words.count), words.allSatisfy({
            $0.count <= PersonalHistory.maxTokenLength && PersonalHistory.isWord($0)
        }) else { return [] }
        let finalBody = String(resultingBefore.reversed().drop(while: \.isWhitespace).reversed())
        guard lastCompletedContext != finalBody else { return [] }
        // Reopening a completed typo and explicitly repairing it replaces only
        // that document occurrence; unrelated typed/imported evidence survives.
        let replaced = recent.filter { $0.body == before }.map(\.occurrence)
        recent.removeAll { $0.body == before }
        var context = prefix
        var events: [Event] = []
        for character in inserted {
            context.append(character)
            if character.isWhitespace,
               let event = completed(before: context, documentID: documentID, after: resultingAfter) {
                events.append(event)
            }
        }
        if let first = events.first, !replaced.isEmpty {
            events[0] = Event(token: first.token, previous: first.previous,
                              retracting: replaced + first.retracting, id: first.id)
        }
        changed(before: resultingBefore, documentID: documentID, after: resultingAfter)
        return events
    }

    /// Preserve transient observations while the UI replaces an observed
    /// technical prefix through individual delete commands.
    public struct TechnicalReplacement: Sendable {
        fileprivate let id = UUID()
        fileprivate let before: String
        fileprivate let after: String?
        fileprivate let replacing: String
        fileprivate let documentID: UUID
        fileprivate let observation: HistoryObservation
        fileprivate let closingWrapper: String
    }

    public func technicalReplacement(before: String, after: String?, replacing: String,
                                     documentID: UUID) -> TechnicalReplacement? {
        guard self.documentID == documentID, !replacing.isEmpty,
              previousVisibleContext == before,
              previousVisibleDocument == before + (after ?? ""),
              before.hasSuffix(replacing), replacing.count <= PersonalHistory.maxTokenLength else { return nil }
        let span = TechnicalTextSpan.atCursor(before: before, after: after ?? "")
        let closing = span?.prefix == replacing ? span?.closingWrapper ?? "" : ""
        return TechnicalReplacement(before: before, after: after, replacing: replacing,
                                    documentID: documentID, observation: self, closingWrapper: closing)
    }

    public mutating func completedTechnicalReplacement(_ witness: TechnicalReplacement,
                                                       inserted: String, rightToken: String = "", resultingBefore: String,
                                                       resultingAfter: String?, documentID: UUID) -> Event? {
        let completedValue = inserted + rightToken
        let retainedRight = rightToken + witness.closingWrapper
        let remainingAfter = resultingAfter.map { String($0.dropFirst(retainedRight.count)) }
        // Recall folds only scheme/host/domain components and canonical Unicode.
        // Acceptance must use that same identity, keeping mailbox/path case exact.
        let matchingPrefix = PersonalHistory.technicalSearchKey(inserted)
            .hasPrefix(PersonalHistory.technicalSearchKey(witness.replacing))
        let reformattedPhone = TechnicalTokenKind.classify(completedValue) == .phone
            && TechnicalTextSpan.phonePrefixKey(witness.replacing).map { prefix in
                // The retained right token may contain the closing parenthesis.
                // Validate the complete phone above and compare cursor prefixes
                // with the same partial-parenthesis rules as the offer provider.
                prefix.count >= 3 && TechnicalTextSpan.phonePrefixKey(inserted)?.hasPrefix(prefix) == true
            } == true
        guard self.documentID == documentID, witness.documentID == documentID,
              !consumedSelections.contains(witness.id),
              (resultingAfter ?? "").hasPrefix(retainedRight), remainingAfter?.first?.isWhitespace != false,
              resultingAfter == witness.after, matchingPrefix || reformattedPhone,
              PersonalHistory.isRecallable(completedValue), completedValue.count <= PersonalHistory.maxTokenLength,
              resultingBefore == witness.before.dropLast(witness.replacing.count) + inserted else { return nil }
        // A repeated acceptance sees an already-owned final occurrence.
        let completedBefore = resultingBefore + retainedRight
        let body = String(completedBefore.reversed().drop(while: \.isWhitespace).reversed())
        guard !recent.contains(where: { $0.body == body }) else { return nil }
        var restored = witness.observation
        var retired: [Occurrence] = []
        if !inserted.hasPrefix(witness.replacing) {
            let start = String(witness.before.dropLast(witness.replacing.count))
            // A formatting change invalidates textual-prefix matching. Retire
            // only the provisional receipt at this exact replacement start.
            if reformattedPhone, let prior = restored.provisional,
               witness.before.hasPrefix(prior.body),
               String(prior.body.dropLast(prior.occurrence.token.count)) == start {
                retired = [prior.occurrence]
                restored.recent.removeAll { $0.occurrence.id == prior.occurrence.id }
                restored.provisional = nil
            }
            // The verified replacement preserves the document's start witness.
            restored.previousVisibleContext = completedBefore
            restored.previousVisibleDocument = completedBefore + (remainingAfter ?? "")
        }
        // Only this exact, host-verified inserted token has an explicit choice
        // witness. It does not establish the start of the surrounding document.
        var event = restored.completed(before: completedBefore + " ", documentID: documentID, after: remainingAfter, confirmedTechnicalToken: completedValue)
        if let completed = event, !retired.isEmpty {
            event = Event(token: completed.token, previous: completed.previous,
                          replacing: completed.replacing, retracting: retired + completed.retracting, id: completed.id)
        }
        if let event {
            restored.explicitTechnicalReceipts = Array((restored.explicitTechnicalReceipts + [event.id]).suffix(128))
        }
        let completedOccurrences = restored.recent
        restored.changed(before: resultingBefore, documentID: documentID, after: resultingAfter)
        restored.recent = completedOccurrences
        restored.observedStart = witness.observation.observedStart
        restored.consumedSelections = Array((consumedSelections + [witness.id]).suffix(128))
        self = restored
        return event
    }

    public mutating func reset() {
        previousVisibleDocument = nil
        consumedSelections.removeAll()
        explicitTechnicalReceipts.removeAll()
        expectedDeletion = nil
        provisional = nil
        recent.removeAll()
        lastCompletedContext = nil; documentID = nil
        previousVisibleContext = nil; observedStart = false
    }
}
