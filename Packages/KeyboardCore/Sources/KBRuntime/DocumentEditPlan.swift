/// A visible host snapshot, not a claim about global document offsets.
/// Nil context remains unknown and is never treated as an empty document.
struct DocumentSnapshot: Equatable {
    let before: String?
    let selected: String?
    let after: String?

    init(_ editor: DocumentEditor) {
        before = editor.contextBeforeInput
        selected = editor.selectedText
        after = editor.contextAfterInput
    }
}

/// All replacement preconditions are checked before the first destructive edit.
/// The host offers no atomic compare-and-swap; this is a local validation gate.
struct DocumentEditPlan {
    enum Target {
        case selection(String)
        case suffix(String)
    }
    let snapshot: DocumentSnapshot
    let target: Target
    let replacement: String

    @discardableResult
    func apply(to editor: DocumentEditor) -> Bool {
        guard DocumentSnapshot(editor) == snapshot else { return false }
        switch target {
        case .selection(let expected):
            guard !expected.isEmpty, snapshot.selected == expected else { return false }
            // Also consumes an unchanged selection, leaving the caret after it.
            editor.insertText(replacement)
        case .suffix(let expected):
            guard !expected.isEmpty, snapshot.selected == nil,
                  snapshot.before?.hasSuffix(expected) == true else { return false }
            for _ in expected { editor.deleteBackward() }
            editor.insertText(replacement)
        }
        return true
    }
}
