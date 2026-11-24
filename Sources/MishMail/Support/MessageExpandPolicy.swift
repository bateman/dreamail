import Foundation

/// How many message cards may keep a live body open at once.
///
/// The normal reading pane is single-active so HTML-heavy threads do not
/// accumulate WKWebViews. Side-by-side compose opens every sent card so the
/// draft can reference the full conversation (quoted trails still collapse
/// behind each card's "…" pill).
///
/// A conversation with exactly one sent message is shown open under either
/// policy and cannot be collapsed, as in Gmail on the web: a lone message
/// card has nothing to make room for, so collapsing it only hides the mail.
enum MessageExpandPolicy: Equatable {
    /// At most one sent card expanded (default reading pane).
    case single
    /// Any number of cards expanded (side-by-side compose).
    case multiple

    /// Toggle `id` open/closed under this policy. Callers skip the toggle for
    /// a card that is not `isCollapsible`.
    func applyingToggle(id: String, currently: Set<String>) -> Set<String> {
        let isOpen = currently.contains(id)
        switch self {
        case .single:
            return isOpen ? [] : [id]
        case .multiple:
            var next = currently
            if isOpen { next.remove(id) } else { next.insert(id) }
            return next
        }
    }

    /// Force-open `id` without collapsing siblings when multiple is allowed.
    func applyingExpand(id: String, currently: Set<String>) -> Set<String> {
        switch self {
        case .single:
            return [id]
        case .multiple:
            var next = currently
            next.insert(id)
            return next
        }
    }

    /// Default open set when a conversation first paints.
    /// - single: newest sent message only
    /// - multiple: every non-draft message id (drafts use `DraftMessageCard`)
    static func initialExpandedIds(
        policy: MessageExpandPolicy,
        nonDraftIds: [String],
        lastNonDraftId: String?
    ) -> Set<String> {
        switch policy {
        case .single:
            return lastNonDraftId.map { [$0] } ?? []
        case .multiple:
            return Set(nonDraftIds)
        }
    }

    /// The one sent message of a conversation that has exactly one, else nil.
    /// Drafts render as `DraftMessageCard` and never count.
    static func soleCardId(nonDraftIds: [String]) -> String? {
        nonDraftIds.count == 1 ? nonDraftIds[0] : nil
    }

    /// False for the sole card of a one-message conversation: it is always
    /// shown open (no chevron, the header click does nothing).
    static func isCollapsible(id: String, nonDraftIds: [String]) -> Bool {
        soleCardId(nonDraftIds: nonDraftIds) != id
    }

    /// Open set after a background refresh: drop ids that left the thread
    /// (send/discard renumber) and keep a manual collapse, except that a
    /// one-message conversation always shows its message.
    static func reconciledAfterRefresh(
        current: Set<String>,
        nonDraftIds: [String]
    ) -> Set<String> {
        var next = current.intersection(nonDraftIds)
        if let sole = soleCardId(nonDraftIds: nonDraftIds) {
            next.insert(sole)
        }
        return next
    }

    /// Open set for the first frame of a pane seeded with `messages` (the
    /// warm mirror). Same as the load's default, so the load does not change
    /// what the first frame showed.
    static func firstFrameExpandedIds(
        messages: [Message],
        policy: MessageExpandPolicy
    ) -> Set<String> {
        let roles = ThreadMessageRoles(messages: messages)
        return initialExpandedIds(
            policy: policy,
            nonDraftIds: roles.nonDraftIds,
            lastNonDraftId: roles.lastNonDraftId)
    }
}
