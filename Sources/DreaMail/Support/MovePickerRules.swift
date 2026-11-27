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
/// - "Move to" lists Inbox first as a destination when any conversation it
///   covers can move there (`InboxMove.movable`: not in the Inbox, not spam,
///   not a lone draft; a trashed one leaves the Trash).
/// - "Label as" never lists Inbox on its own: typing a name that matches it
///   offers "Move to inbox", after the matching labels, when the
///   conversation offers it (`InboxMove.offered`).
/// - No "Create" row for a name Gmail reserves (`ReservedLabelNames`).
enum LabelPickerInboxRow {
    enum Placement: Equatable { case first, last }

    /// The name the row shows in "Move to" and matches against; "Label as"
    /// shows it as `InboxMove.title`.
    static let name = "Inbox"

    /// `moveTargets`: in "Move to", every conversation the move covers; the
    /// row is listed when any of them can move to the Inbox (only those
    /// move, `InboxMove.Plan`). "Label as" looks at `thread` alone.
    static func placement(moveMode: Bool, thread: MailThread, moveTargets: [MailThread] = [],
                          query: String) -> Placement? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if moveMode {
            let targets = moveTargets.isEmpty ? [thread] : moveTargets
            guard targets.contains(where: InboxMove.movable),
                  q.isEmpty || LabelSearch.matches(name, query: q)
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

/// "Label as" over several conversations, after Gmail's label menu: a label
/// on every target shows checked, on some a dash, on none empty; a click
/// adds it to all unless all have it, then removes it from all. Pure;
/// `MailStore.toggleLabel(ids:labelId:accountId:)` writes a `Plan`, and the
/// picker draws its boxes from the same `targets`.
enum BulkLabel {
    enum State: Equatable { case all, some, none }

    static func state(_ labelId: String, in targets: [MailThread]) -> State {
        let n = targets.filter { $0.labels.contains(labelId) }.count
        if n == 0 { return .none }
        return n == targets.count ? .all : .some
    }

    static func adds(_ labelId: String, to targets: [MailThread]) -> Bool {
        state(labelId, in: targets) != .all
    }

    /// The conversations a bulk label edit acts on, in pick order: the ids
    /// still in the list, on `accountId` (labels belong to one account),
    /// without Trash copies of live conversations (DEC-081). The boxes and
    /// the click both read this one answer.
    static func targets(ids: [String], in threads: [MailThread], accountId: String,
                        isPartlyTrashed: (MailThread) -> Bool) -> [MailThread] {
        ThreadRowMenu.liveTargets(ids: ids, in: threads)
            .filter { $0.accountId == accountId && !isPartlyTrashed($0) }
    }

    /// Picked ids still in the list that belong to another account.
    static func otherAccountCount(ids: [String], in threads: [MailThread],
                                  accountId: String) -> Int {
        ThreadRowMenu.liveTargets(ids: ids, in: threads).filter { $0.accountId != accountId }.count
    }

    /// One click on a label over `targets`.
    struct Plan {
        let labelId: String
        let adds: Bool
        /// The targets whose state the click changes: only these are
        /// written and sent, and only these are given back by the undo.
        let changing: [MailThread]

        init(labelId: String, targets: [MailThread]) {
            let adds = BulkLabel.adds(labelId, to: targets)
            self.labelId = labelId
            self.adds = adds
            changing = targets.filter { $0.labels.contains(labelId) != adds }
        }

        var remote: RemoteThreadChange {
            adds ? .modify(add: [labelId]) : .modify(remove: [labelId])
        }

        var undoRemote: RemoteThreadChange {
            adds ? .modify(remove: [labelId]) : .modify(add: [labelId])
        }

        func apply(_ t: inout MailThread) {
            if adds { t.applyLabelMutation(add: [labelId]) } else { t.applyLabelMutation(remove: [labelId]) }
        }

        func restore(_ t: inout MailThread) {
            if adds { t.applyLabelMutation(remove: [labelId]) } else { t.applyLabelMutation(add: [labelId]) }
        }

        func undoLabel() -> String {
            let n = changing.count
            let noun = n == 1 ? "1 conversation" : "\(n) conversations"
            return adds ? "Label added to \(noun)" : "Label removed from \(noun)"
        }
    }

    /// `l` over checked rows labels all of them, as Gmail; with none
    /// checked, nil: the focused conversation's picker.
    static func keyTargets(checkedInOrder: [String]) -> [String]? {
        checkedInOrder.isEmpty ? nil : checkedInOrder
    }
}
