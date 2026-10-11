import Foundation

/// Visible host state captured when a suggestion is presented. Document identity
/// matters even when two fields happen to contain identical text.
public struct SuggestionContext: Equatable, Sendable {
    public let documentID: UUID
    public let before: String?
    public let selected: String?
    public let after: String?

    public init(documentID: UUID, before: String?, selected: String?, after: String?) {
        self.documentID = documentID
        self.before = before
        self.selected = selected
        self.after = after
    }
}
