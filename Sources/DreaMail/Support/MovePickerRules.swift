import Foundation

/// Which conversations Gmail's "Move to" acts on, and when a label created
/// from the picker may still be applied. Pure; `MailStore` holds the state.
enum MovePickerRules {
    /// The conversations fixed when the picker opens. The conversation
    /// toolbar passes its own conversation and wins; the key, menu and
    /// palette act on the checked rows, else the focused one.
    static func targetIds(toolbarThread: String?, checkedInOrder: [String],
                          focused: String?) -> [String] {
        if let toolbarThread { return [toolbarThread] }
        if !checkedInOrder.isEmpty { return checkedInOrder }
        return focused.map { [$0] } ?? []
    }

    /// A label created from the picker is applied only if the same picker
    /// session is still open in move mode when Gmail answers.
    static func appliesCreatedLabel(pickerOpen: Bool, moveMode: Bool,
                                    currentSession: UUID, requestSession: UUID) -> Bool {
        pickerOpen && moveMode && currentSession == requestSession
    }
}

/// Gmail's label picker keys: Return applies the highlighted label and
/// closes; Space and clicks toggle without closing. Pure.
enum LabelPickerKeyRules {
    /// Whether the picker closes after a label row was applied by a key.
    /// Move mode closes itself in `moveThreads`; label mode closes on Return.
    static func closesAfterApply(moveMode: Bool, closeKey: Bool) -> Bool {
        !moveMode && closeKey
    }

    /// Whether Return toggles the highlighted label. Once a box was changed in
    /// this opening (label mode), Return only closes: it must not undo the pick.
    /// An action row (Label as's "Move to inbox") always runs.
    static func returnTogglesLabel(moveMode: Bool, changed: Bool,
                                   actionRow: Bool = false) -> Bool {
        moveMode || actionRow || !changed
    }

    /// The footer's key hints for the highlighted row.
    static func footerHints(moveMode: Bool, onCreateRow: Bool) -> [String] {
        if onCreateRow { return ["↑↓ select", "↵ create", "esc close"] }
        return moveMode
            ? ["↑↓ select", "↵ move", "esc close"]
            : ["↑↓ select", "↵ apply and close", "space toggle", "esc close"]
    }
}

/// The picker's Inbox row and its "Create" row, as Gmail's pickers have
/// them. Pure; `MailStore.labelPickerLabels` / `labelPickerCreateName` use it.
/// - "Move to" lists Inbox first as a destination for a conversation that
///   can move there (`InboxMove.movable`: not in the Inbox, not spam, not a
///   lone draft; a trashed one leaves the Trash).
/// - "Label as" never lists Inbox on its own: typing a name that matches it
///   offers "Move to inbox", after the matching labels, when the
///   conversation offers it (`InboxMove.offered`).
/// - No "Create" row for a name Gmail reserves (`ReservedLabelNames`).
enum LabelPickerInboxRow {
    enum Placement: Equatable { case first, last }

    /// The name the row shows in "Move to" and matches against; "Label as"
    /// shows it as `InboxMove.title`.
    static let name = "Inbox"

    static func placement(moveMode: Bool, thread: MailThread, query: String) -> Placement? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if moveMode {
            guard InboxMove.movable(thread), q.isEmpty || LabelSearch.matches(name, query: q)
            else { return nil }
            return .first
        }
        guard InboxMove.offered(for: thread), !q.isEmpty, LabelSearch.matches(name, query: q)
        else { return nil }
        return .last
    }

    /// The "Create" row's name: the trimmed query, unless it is empty,
    /// reserved by Gmail, or already a label of the account.
    static func createName(query: String, existing: [String]) -> String? {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !ReservedLabelNames.isReserved(name) else { return nil }
        let exists = existing.contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return exists ? nil : name
    }

    /// What a pick on a row does. The Inbox row is a move in both modes.
    enum Commit: Equatable {
        case toggleLabel(String)
        /// `moveThreads` to this label (Move to), Inbox included.
        case move(String)
        /// Label as's "Move to inbox": the explicit action on the row's
        /// conversation.
        case moveToInbox
    }

    static func commit(moveMode: Bool, labelId: String) -> Commit {
        if moveMode { return .move(labelId) }
        return labelId == ConversationAction.inboxLabel ? .moveToInbox : .toggleLabel(labelId)
    }
}
