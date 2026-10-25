import Foundation
import KBLearning

/// Yazma geçmişinin deposu — uzantı sandbox'ı, JSON.
///
/// Uygulamadaki içe aktarma (WhatsApp, Telegram) ortak klasöre bir **bekleyen**
/// dosya bırakıyor; klavye geçmişe kalıcı yazdıktan sonra batch listesini onaylıyor. Tek
/// yazar yine klavye: kişisel sözlük ve kalibrasyonla aynı ilke.
enum PersonalHistoryStore {
    static var url: URL? { LocalStore.url(LocalStore.Name.history) }

    private static var unreadableArchive = false
    static var needsRecovery: Bool { unreadableArchive }

    /// User-triggered recovery preserves the unreadable bytes before allowing
    /// new learning to persist. A failed backup never unlocks overwriting.
    static func recover(with archive: HistoryArchive) -> Bool {
        guard unreadableArchive, let url else { return false }
        do {
            let original = try Data(contentsOf: url)
            try HistoryArchiveRecovery.recover(unreadable: original, current: archive,
                backup: { bytes in
                    let backup = url.appendingPathExtension("unreadable-" + UUID().uuidString)
                    try FileManager.default.copyItem(at: url, to: backup)
                    guard try Data(contentsOf: backup) == bytes else { throw CocoaError(.fileReadCorruptFile) }
                }, writeArchive: { value in
                    guard JSONFile.write(value, to: url, protected: true) else { throw CocoaError(.fileWriteUnknown) }
                })
            unreadableArchive = false
            publish(archive.history)
            return true
        } catch { return false }
    }

    static func load() -> HistoryArchive {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            unreadableArchive = false
            return HistoryArchive()
        }
        do {
            let value = try HistoryArchive.decode(Data(contentsOf: url))
            unreadableArchive = false
            return value
        } catch {
            // Never replace an existing unreadable snapshot with an empty one.
            unreadableArchive = true
            return HistoryArchive()
        }
    }

    @discardableResult
    static func save(_ archive: HistoryArchive) -> Bool {
        guard !unreadableArchive, JSONFile.write(archive, to: url, protected: true) else { return false }
        publish(archive.history)
        return true
    }

    /// Lock covers read, destination commit and acknowledgement. Never consume
    /// bytes before the history and its import receipts are durable.
    static func receiveImports(into archive: inout HistoryArchive) {
        guard KeyboardSettingsStore.sharingAllowed,
              let pendingURL = AppGroup.file(AppGroup.File.historyImport) else { return }
        _ = AppGroup.withLock(AppGroup.File.historyImport) {
            guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
            do {
                var inbox = try HistoryImportInbox.decode(Data(contentsOf: pendingURL))
                for word in archive.forgottenImports { inbox.forget(word) }
                // Also assigns a stable ID to legacy bare-history pending files.
                guard JSONFile.write(inbox, to: pendingURL, protected: true) else { return }
                guard !inbox.batches.isEmpty || !inbox.removedSources.isEmpty else { return }
                try HistoryImportTransaction.consume(&archive, inbox: inbox,
                    writeArchive: { value in
                        guard save(value) else { throw CocoaError(.fileWriteUnknown) }
                    }, writeInbox: { value in
                        guard JSONFile.write(value, to: pendingURL, protected: true) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    })
            } catch {
                // Pending bytes and/or receipts remain recoverable. Next refresh
                // retries; do not turn a failed write into a destructive claim.
            }
        }
    }

    static func publish(_ h: PersonalHistory) {
        guard KeyboardSettingsStore.sharingAllowed else { return }
        let entries = h.tokens.values.map {
            LearnedWordsSnapshot.Entry(word: $0.surface, count: $0.count)
        }.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
        LearnedWordsSnapshot.publish(entries, to: AppGroup.File.learnedHistory,
            note: unreadableArchive ? "Geçmiş kaydı okunamıyor. Klavyenin ayarlarındaki Geçmişi kurtar düğmesiyle eski kaydı yedekleyip yeni öğrenmeye devam edebilirsin." : nil)
    }


}

/// Yazma geçmişi (sonraki kelime, hatırlama) — gözlem, tahmin ve kayıt.
///
/// Kelime bitince son iki token öğreniliyor. Kaynak belge: düzeltme
/// uygulanmışsa son hâli öğreniliyor, kullanıcının yazdığı ham dokunmalar değil.
final class TypingHistory {
    /// Bu kadar gözlemde bir diske yazılıyor (her kelimede yazmak pahalı).
    private static let saveEvery = 20

    private lazy var archive = PersonalHistoryStore.load()
    private var history: PersonalHistory {
        get { archive.history }
    }
    private var observation = HistoryObservation()
    private var unsaved = 0

    var needsRecovery: Bool {
        _ = archive
        return PersonalHistoryStore.needsRecovery
    }

    func recover() -> (success: Bool, note: String) {
        if PersonalHistoryStore.recover(with: archive) {
            unsaved = 0
            refreshImports()
            return (true, "Okunamayan kayıt yedeklendi; yeni öğrenme kaydediliyor.")
        }
        return (false, "Yedekleme tamamlanamadı. Eski kayıt korunuyor; yeniden deneyebilirsin.")
    }

    /// Aynı klavye süreci yeniden görünse de uygulamadaki yeni aktarımı alır.
    func refreshImports() {
        PersonalHistoryStore.receiveImports(into: &archive)
        PersonalHistoryStore.publish(history)
    }

    private func applyCancelledObservations() {
        guard archive.retract(observation.takeCancelledOccurrences()) else { return }
        unsaved += 1
        if unsaved >= Self.saveEvery { flush() }
    }

    /// `before`: imleçten önceki metin; boşlukla bitmiyorsa kelime bitmemiş.
    func observe(before: String, after: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        guard let completed = observation.completed(before: before, documentID: documentID, after: after) else { return }
        archive.observe(completed)
        unsaved += 1
        if unsaved >= Self.saveEvery { flush() }
    }

    func contextChanged(before: String, after: String?, selected: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        observation.changed(before: before, documentID: documentID, after: after, selected: selected)
    }

    func selectionReplacement(before: String, selected: String, after: String?, documentID: UUID) -> HistoryObservation.SelectionReplacement? {
        defer { applyCancelledObservations() }
        return observation.selectionReplacement(before: before, selected: selected, after: after, documentID: documentID)
    }

    func observeSelection(_ witness: HistoryObservation.SelectionReplacement, inserted: String,
                          resultingBefore: String, resultingAfter: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        let events = observation.completedSelection(witness, inserted: inserted,
            resultingBefore: resultingBefore, resultingAfter: resultingAfter, documentID: documentID)
        for event in events { archive.observe(event) }
        unsaved += events.count
        if unsaved >= Self.saveEvery { flush() }
    }

    func observeReplacement(before: String, after: String?, resultingBefore: String,
                            resultingAfter: String?, replacing: String, inserted: String, documentID: UUID) {
        defer { applyCancelledObservations() }
        let events = observation.completedReplacement(before: before, after: after,
            resultingBefore: resultingBefore, resultingAfter: resultingAfter,
            replacing: replacing, inserted: inserted, documentID: documentID)
        for event in events { archive.observe(event) }
        unsaved += events.count
        if unsaved >= Self.saveEvery { flush() }
    }

    func technicalReplacement(before: String, after: String?, replacing: String,
                              documentID: UUID) -> HistoryObservation.TechnicalReplacement? {
        defer { applyCancelledObservations() }
        return observation.technicalReplacement(before: before, after: after, replacing: replacing, documentID: documentID)
    }

    func observeTechnicalReplacement(_ witness: HistoryObservation.TechnicalReplacement, inserted: String, rightToken: String,
                                     resultingBefore: String, resultingAfter: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        guard let event = observation.completedTechnicalReplacement(witness, inserted: inserted, rightToken: rightToken,
            resultingBefore: resultingBefore, resultingAfter: resultingAfter, documentID: documentID) else { return }
        archive.observe(event)
        unsaved += 1
        if unsaved >= Self.saveEvery { flush() }
    }

    func expectInsertion(_ text: String, before: String, after: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        observation.expectInsertion(text, before: before, after: after, documentID: documentID)
    }

    func expectBackwardDeletion(before: String, after: String?, documentID: UUID) {
        defer { applyCancelledObservations() }
        observation.expectBackwardDeletion(before: before, after: after, documentID: documentID)
    }

    func cancelExpectedDeletion() { observation.cancelExpectedDeletion() }

    /// Bir metnin tamamından öğrenir (alandan içe aktarma).
    func ingest(text: String) {
        archive.observe(text: text)
        unsaved += 1
        flush()
    }

    func forget(_ surface: String) {
        archive.forget(surface)
        unsaved += 1
        flush()
        // Durable tombstones also scrub pending batches and the source catalog
        // on every future refresh, including after an interrupted acknowledgement.
        if unsaved == 0 { refreshImports() }
    }

    func flush() {
        guard unsaved > 0 else { return }
        if PersonalHistoryStore.save(archive) { unsaved = 0 }
    }

    /// Boşlukla biten metinden sonra gelebilecek kelimeler.
    func nextWords(before: String) -> [String] {
        guard before.last == " ", let prev = PersonalHistory.tokenize(before).last,
              PersonalHistory.isWord(prev) else { return [] }
        return history.nextWords(after: prev)
    }

    func completions(before: String?, after: String?, selected: String?) -> [PersonalHistory.Completion] {
        history.completions(before: before, after: after, selected: selected)
    }

    /// Yazılan önekle başlayan, daha önce yazılmış tam token (IP, e-posta…).
    /// Önek geçmişin sakladığı biçimde: uç noktalama atılmış ("(192.16" → "192.16").
    func recall(lastToken raw: String) -> (prefix: String, full: String)? {
        guard let last = PersonalHistory.tokenize(raw).last, raw.hasSuffix(last),
              let full = history.recall(prefix: last).first else { return nil }
        return (last, full)
    }
}
