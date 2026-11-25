import Foundation

/// Gmail's keys inside an open conversation: `n` / `p` move to the next
/// (newer) / previous (older) message, `;` / `:` open / close every message.
/// Pure; `ThreadDetailView` applies the result to its open set and scrolls.
enum MessageNavigation {
    enum Action: Equatable {
        case next, previous, expandAll, collapseAll

        init?(_ command: ShortcutCommand) {
            switch command {
            case .nextMessage: self = .next
            case .previousMessage: self = .previous
            case .expandAll: self = .expandAll
            case .collapseAll: self = .collapseAll
            default: return nil
            }
        }
    }

    struct State: Equatable {
        /// Open message ids.
        var expanded: Set<String>
        /// The message `n` / `p` move from; nil until the first move.
        var cursor: String?
        /// `;` was pressed: every message stays open, `n` / `p` only scroll.
        var expandAll: Bool
    }

    /// The message the cursor sits on: the explicit cursor while it is still
    /// in the thread, else the open message (newest of several), else the
    /// newest message.
    static func current(_ state: State, ids: [String]) -> String? {
        if let cursor = state.cursor, ids.contains(cursor) { return cursor }
        if let open = ids.last(where: { state.expanded.contains($0) }) { return open }
        return ids.last
    }

    /// `ids`: the conversation's sent messages, oldest first (drafts are not
    /// part of the walk). Returns the new state and the message to scroll
    /// to (nil: stay where you are).
    static func apply(_ action: Action, to state: State, ids: [String],
                      policy: MessageExpandPolicy) -> (state: State, scrollTo: String?) {
        var next = state
        switch action {
        case .next, .previous:
            guard let from = current(state, ids: ids),
                  let index = ids.firstIndex(of: from) else { return (state, nil) }
            let target = index + (action == .next ? 1 : -1)
            guard ids.indices.contains(target) else { return (state, nil) }
            let id = ids[target]
            next.cursor = id
            // Gmail opens the message it moves to. With every message open
            // (`;`, or side-by-side compose) the others stay open.
            next.expanded = state.expandAll
                ? state.expanded.union([id])
                : policy.applyingExpand(id: id, currently: state.expanded)
            return (next, id)
        case .expandAll:
            next.expandAll = true
            next.expanded = Set(ids)
            return (next, nil)
        case .collapseAll:
            next.expandAll = false
            // A one-message conversation always shows its message.
            next.expanded = MessageExpandPolicy.soleCardId(nonDraftIds: ids).map { [$0] } ?? []
            return (next, nil)
        }
    }
}
