import Foundation

/// Tracks an observed empty right side through keyboard-owned edits. A missing
/// proxy suffix alone never proves that the cursor is at the document end.
public struct DocumentEndWitness: Sendable {
    private var context: SuggestionContext?
    public init() {}
    public mutating func invalidate() { context = nil }

    public mutating func observe(_ current: SuggestionContext?, hasText: Bool) -> Bool {
        guard let current, current.selected == nil else { context = nil; return false }
        if current.after == "" || (!hasText && (current.before ?? "").isEmpty && current.after == nil) {
            context = current
        } else if context != current { context = nil }
        return context != nil
    }

    /// Call only after an insertion/deletion batch that began at a proven end.
    /// Explicit cursor moves must invalidate the witness separately.
    public mutating func didEdit(from previous: SuggestionContext?, to current: SuggestionContext?, wasAtEnd: Bool) {
        guard wasAtEnd, let previous, let current,
              previous.documentID == current.documentID, current.selected == nil,
              current.after == nil || current.after == "", current.before != nil else {
            context = nil; return
        }
        context = current
    }
}
