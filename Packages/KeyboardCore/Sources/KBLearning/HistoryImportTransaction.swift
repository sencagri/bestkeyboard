import Foundation
import CryptoKit

public enum HistoryArchiveRecovery {
    public enum Failure: Error { case archiveIsReadable }

    /// The caller must persist and verify a byte-exact backup before writing
    /// the live archive. Throwing from backup leaves the destination untouched.
    public static func recover(unreadable: Data, current: HistoryArchive,
                               backup: (Data) throws -> Void,
                               writeArchive: (HistoryArchive) throws -> Void) throws {
        guard (try? HistoryArchive.decode(unreadable)) == nil else { throw Failure.archiveIsReadable }
        try backup(unreadable)
        try writeArchive(current)
    }
}

/// Shared inbox: pending batches and the app's source catalog are committed together.
public struct HistoryImportInbox: Codable, Sendable {
    public static let maximumBatchReceipts = 10_000
    public static let maximumMessageReceipts = 50_000
    public enum ImportFailure: LocalizedError {
        case receiptCapacity
        public var errorDescription: String? {
            "Aktarım geçmişi sınırına ulaşıldı. Mevcut öğrenilenler ve bekleyen aktarımlar korunuyor."
        }
    }
    public struct Batch: Codable, Sendable {
        public let id: UUID
        public var history: PersonalHistory
        public let source: String?
        public init(history: PersonalHistory, id: UUID = UUID(), source: String? = nil) {
            self.id = id; self.history = history; self.source = source
        }
    }
    public var batches: [Batch] = []
    public var sources: [String: PersonalHistory] = [:]
    public var legacyCatalogMigrated = false
    public var receivedBatches: Set<UUID> = []
    public var receivedMessages: Set<UUID> = []
    public var removedSources: Set<String> = []
    public var cancelledBatches: Set<UUID> = []
    public var sourceGenerations: [String: UInt64] = [:]
    public init() {}

    @discardableResult
    public mutating func append(_ history: PersonalHistory, source: String, id: UUID = UUID()) -> Bool {
        guard receivedBatches.insert(id).inserted else { return false }
        batches.append(Batch(history: history, id: id, source: source))
        var previous = sources[source] ?? PersonalHistory()
        previous.merge(history)
        sources[source] = previous
        return true
    }

    /// Count stable export identities once even when two exports overlap.
    /// Unidentified messages retain batch-level deduplication only.
    @discardableResult
    public mutating func appendMessages(_ messages: [ChatExportParser.Message], source: String, sender: String) throws -> Int {
        let generation = sourceGenerations[source] ?? 0
        let receiptSource = generation == 0 ? source : source + "\u{0}" + String(generation)
        let batchID = try Self.contentID(source: receiptSource, sender: sender,
            messages: messages.map { ($0.identity ?? "") + "\u{0}" + $0.text })
        let legacyID = try Self.contentID(source: receiptSource, sender: sender, messages: messages.map(\.text))
        guard !receivedBatches.contains(batchID), !receivedBatches.contains(legacyID) else { return 0 }
        var fresh = PersonalHistory()
        var identities: Set<UUID> = []
        var count = 0
        for message in messages {
            if let identity = message.identity {
                let id = try Self.contentID(source: receiptSource, sender: "", messages: [identity])
                guard !receivedMessages.contains(id), identities.insert(id).inserted else { continue }
            }
            fresh.observe(text: message.text)
            count += 1
        }
        guard !fresh.tokens.isEmpty else { return 0 }
        // Never silently evict a receipt: that could count a retry twice.
        // Reject before mutating any state when the bounded ledger is full.
        guard receivedBatches.count < Self.maximumBatchReceipts,
              receivedMessages.count + identities.count <= Self.maximumMessageReceipts else {
            throw ImportFailure.receiptCapacity
        }
        receivedBatches.insert(batchID)
        receivedMessages.formUnion(identities)
        // Receipt and pending counts are persisted in one inbox write.
        batches.append(Batch(history: fresh, id: batchID, source: source))
        var previous = sources[source] ?? PersonalHistory()
        previous.merge(fresh)
        sources[source] = previous
        return count
    }

    public mutating func removeSource(_ source: String) {
        sources.removeValue(forKey: source)
        cancelledBatches.formUnion(batches.filter { $0.source == source }.map(\.id))
        batches.removeAll { $0.source == source }
        removedSources.insert(source)
        sourceGenerations[source, default: 0] += 1
    }

    private enum CodingKeys: String, CodingKey { case batches, sources, legacyCatalogMigrated, receivedBatches, receivedMessages, removedSources, cancelledBatches, sourceGenerations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        batches = try values.decode([Batch].self, forKey: .batches)
        sources = try values.decode([String: PersonalHistory].self, forKey: .sources)
        legacyCatalogMigrated = try values.decode(Bool.self, forKey: .legacyCatalogMigrated)
        receivedBatches = try values.decodeIfPresent(Set<UUID>.self, forKey: .receivedBatches) ?? Set(batches.map(\.id))
        receivedMessages = try values.decodeIfPresent(Set<UUID>.self, forKey: .receivedMessages) ?? []
        removedSources = try values.decodeIfPresent(Set<String>.self, forKey: .removedSources) ?? []
        cancelledBatches = try values.decodeIfPresent(Set<UUID>.self, forKey: .cancelledBatches) ?? []
        sourceGenerations = try values.decodeIfPresent([String: UInt64].self, forKey: .sourceGenerations) ?? [:]
    }

    /// Stable batch identity from source and exact selected message text. No
    /// message content is persisted in the receipt. Overlapping exports require
    /// per-message identities and are not claimed to be deduplicated here.
    public static func contentID(source: String, sender: String, messages: [String]) throws -> UUID {
        let data = try JSONEncoder().encode([source, sender] + messages)
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public mutating func forget(_ surface: String) {
        for index in batches.indices { batches[index].history.forget(surface) }
        for source in Array(sources.keys) { sources[source]?.forget(surface) }
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let inbox = try? decoder.decode(Self.self, from: data) { return inbox }
        // Old pending files contained a bare PersonalHistory. Caller must persist
        // this envelope before applying it, so retries reuse the generated ID.
        let history = try decoder.decode(PersonalHistory.self, from: data)
        var inbox = Self()
        inbox.batches = [Batch(history: history)]
        return inbox
    }
}

/// Receipts and history share a single atomic snapshot. A process dying after
/// this write but before inbox acknowledgement cannot apply the batch twice.
public struct HistoryArchive: Codable, Sendable {
    public private(set) var history: PersonalHistory
    private var unassignedHistory: PersonalHistory
    public private(set) var sourceHistories: [String: PersonalHistory] = [:]
    private var sequence: UInt32 = 0
    public var appliedSourceRemovals: [String: UInt64] = [:]
    public var appliedImports: Set<UUID>
    public var forgottenImports: Set<String> = []
    public init(history: PersonalHistory = PersonalHistory(), appliedImports: Set<UUID> = []) {
        self.history = history; self.appliedImports = appliedImports
        self.unassignedHistory = history
        self.sequence = history.sequence
    }
    private enum CodingKeys: String, CodingKey { case history, appliedImports, forgottenImports, unassignedHistory, sourceHistories, appliedSourceRemovals, sequence }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        history = try values.decode(PersonalHistory.self, forKey: .history)
        unassignedHistory = try values.decodeIfPresent(PersonalHistory.self, forKey: .unassignedHistory) ?? history
        sourceHistories = try values.decodeIfPresent([String: PersonalHistory].self, forKey: .sourceHistories) ?? [:]
        appliedSourceRemovals = try values.decodeIfPresent([String: UInt64].self, forKey: .appliedSourceRemovals) ?? [:]
        appliedImports = try values.decode(Set<UUID>.self, forKey: .appliedImports)
        forgottenImports = try values.decodeIfPresent(Set<String>.self, forKey: .forgottenImports) ?? []
        sequence = try values.decodeIfPresent(UInt32.self, forKey: .sequence)
            ?? ([history.sequence, unassignedHistory.sequence] + sourceHistories.values.map(\.sequence)).max() ?? 0
        rebuildHistory()
    }

    public mutating func forget(_ surface: String) {
        unassignedHistory.forget(surface)
        for source in sourceHistories.keys { sourceHistories[source]?.forget(surface) }
        rebuildHistory()
        forgottenImports.insert(surface)
    }

    public mutating func observe(token: String, previous: String?) {
        unassignedHistory.advanceSequence(to: sequence)
        unassignedHistory.observe(token: token, previous: previous)
        sequence = unassignedHistory.sequence
        rebuildHistory()
    }

    public mutating func observe(text: String) {
        unassignedHistory.advanceSequence(to: sequence)
        unassignedHistory.observe(text: text)
        sequence = unassignedHistory.sequence
        rebuildHistory()
    }

    public mutating func observe(_ event: HistoryObservation.Event) {
        unassignedHistory.advanceSequence(to: sequence)
        unassignedHistory.observe(event)
        sequence = unassignedHistory.sequence
        rebuildHistory()
    }

    @discardableResult
    public mutating func retract(_ occurrences: [HistoryObservation.Occurrence]) -> Bool {
        guard unassignedHistory.retract(occurrences) else { return false }
        rebuildHistory()
        return true
    }

    mutating func merge(_ imported: PersonalHistory, source: String?) {
        if let source {
            var contribution = sourceHistories[source] ?? PersonalHistory()
            contribution.advanceSequence(to: sequence)
            contribution.merge(imported)
            sequence = contribution.sequence
            sourceHistories[source] = contribution
        } else {
            unassignedHistory.advanceSequence(to: sequence)
            unassignedHistory.merge(imported)
            sequence = unassignedHistory.sequence
        }
        rebuildHistory()
    }

    public mutating func removeSource(_ source: String) {
        sourceHistories.removeValue(forKey: source)
        rebuildHistory()
    }

    private mutating func rebuildHistory() {
        guard !sourceHistories.isEmpty else { history = unassignedHistory; return }
        history = PersonalHistory.aggregate(Array(sourceHistories.values) + [unassignedHistory])
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(Self.self, from: data) { return archive }
        return Self(history: try decoder.decode(PersonalHistory.self, from: data))
    }
}

public enum HistoryImportTransaction {
    /// The caller holds the shared inbox lock for the entire operation. The live
    /// archive is authoritative, including typing not yet flushed to disk.
    /// Each write either succeeds atomically or throws. Failed acknowledgement
    /// leaves durable receipts for the next retry; failed archive write changes
    /// neither the live state nor the pending batches.
    public static func consume(
        _ archive: inout HistoryArchive,
        inbox: HistoryImportInbox,
        writeArchive: (HistoryArchive) throws -> Void,
        writeInbox: (HistoryImportInbox) throws -> Void
    ) throws {
        guard !inbox.batches.isEmpty || !inbox.removedSources.isEmpty || !inbox.cancelledBatches.isEmpty else { return }
        var next = archive
        for source in inbox.removedSources {
            let generation = inbox.sourceGenerations[source] ?? 0
            if next.appliedSourceRemovals[source].map({ $0 >= generation }) != true {
                next.removeSource(source)
                next.appliedSourceRemovals[source] = generation
            }
        }
        next.appliedImports.formUnion(inbox.cancelledBatches)
        for batch in inbox.batches where !next.appliedImports.contains(batch.id) {
            var imported = batch.history
            for word in next.forgottenImports { imported.forget(word) }
            next.merge(imported, source: batch.source)
            next.appliedImports.insert(batch.id)
        }
        try writeArchive(next)
        archive = next
        var acknowledged = inbox
        acknowledged.batches.removeAll()
        acknowledged.removedSources.removeAll()
        acknowledged.cancelledBatches.removeAll()
        for word in next.forgottenImports { acknowledged.forget(word) }
        try writeInbox(acknowledged)
        // Keep receipts: a stale inbox restored from a backup must remain safe.
        // Compaction needs an explicit generation/watermark protocol, not a cap.
    }
}
