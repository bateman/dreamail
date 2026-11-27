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
    /// - single: `openIds` when given (a starred conversation,
    ///   `ConversationOpenTarget`), else the newest sent message only
    /// - multiple: every non-draft message id (drafts use `DraftMessageCard`)
    static func initialExpandedIds(
        policy: MessageExpandPolicy,
        nonDraftIds: [String],
        lastNonDraftId: String?,
        openIds: Set<String>? = nil
    ) -> Set<String> {
        switch policy {
        case .single:
            return openIds ?? lastNonDraftId.map { [$0] } ?? []
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

    // MARK: - Opening a conversation
    //
    // `ThreadDetailView` runs these in order: `init` seeds the default set
    // (`initialExpandedIds`) from the warm mirror so the first frame is
    // already open, the load task keeps it (`keptAtLoadStart`), and the
    // payload applies its default (`applyingPayload`). A one-message
    // conversation is open at every step.

    /// Open set when the load task starts. The set `init` seeded belongs to
    /// this conversation and stays (clearing it here collapsed the card for
    /// the whole load). A side-by-side column that switches conversation
    /// without a remount still holds the previous one's messages: start empty.
    static func keptAtLoadStart(
        current: Set<String>,
        messageThreadIds: [String],
        threadId: String
    ) -> Set<String> {
        messageThreadIds.allSatisfy { $0 == threadId } ? current : []
    }

    /// Open set once the payload is applied. Side-by-side opens every card.
    /// The reading pane keeps the cards already open that are still in the
    /// thread (the seeded newest, or one the user opened meanwhile), and
    /// otherwise opens the payload's newest.
    static func applyingPayload(
        current: Set<String>,
        policy: MessageExpandPolicy,
        nonDraftIds: [String],
        lastNonDraftId: String?,
        openIds: Set<String>? = nil
    ) -> Set<String> {
        let seed = initialExpandedIds(
            policy: policy, nonDraftIds: nonDraftIds, lastNonDraftId: lastNonDraftId,
            openIds: openIds)
        switch policy {
        case .multiple:
            return seed
        case .single:
            let live = current.intersection(nonDraftIds)
            return live.isEmpty ? seed : live
        }
    }

    /// The card that fills the pane while its body loads: the open card of
    /// the reading pane (with several open, as a starred conversation opens,
    /// only `scrollTargetId`), or the newest card in side-by-side (where
    /// every card is open and only the newest should claim the viewport).
    static func fillsPane(
        id: String,
        policy: MessageExpandPolicy,
        expanded: Set<String>,
        lastNonDraftId: String?,
        scrollTargetId: String? = nil
    ) -> Bool {
        switch policy {
        case .single:
            return expanded.contains(id) && (expanded.count == 1 || id == scrollTargetId)
        case .multiple:
            return id == lastNonDraftId
        }
    }
}
