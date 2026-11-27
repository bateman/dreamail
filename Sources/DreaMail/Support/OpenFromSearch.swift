import Foundation

/// Pure helpers for opening a thread from the `/` search panel.
///
/// The reading pane resolves the open conversation with
/// `threads.first { $0.id == selectedThreadId }` — so selecting an id that
/// is not yet in `threads` (async reload still in flight, or a typeahead hit
/// outside the current mailbox page) leaves the detail blank. These helpers
/// keep the chosen thread visible across that gap.
enum OpenFromSearch {
    /// What a completed `reloadThreads` should do with a pending open pin.
    enum PinDecision: Equatable {
        /// Merge `threadId` into the reloaded list, then clear the pin.
        case apply(threadId: String)
        /// Drop the pin without merging (superseded reload, or selection moved).
        case clear
        /// No pin was pending.
        case ignore
    }

    /// Insert `opening` at the front of `threads` when it is not already present.
    static func ensuringVisible(opening: MailThread, in threads: [MailThread]) -> [MailThread] {
        if threads.contains(where: { $0.id == opening.id }) { return threads }
        return [opening] + threads
    }

    /// After an async list reload, re-attach a still-selected thread that the
    /// new filter omitted so the reading pane does not go blank mid-open.
    static func mergingPinned(
        selectedId: String?,
        previous: [MailThread],
        reloaded: [MailThread],
        projectedBefore: Set<String> = [],
        projectedAfter: Set<String> = []
    ) -> [MailThread] {
        guard let selectedId,
              !reloaded.contains(where: { $0.id == selectedId }),
              let pin = previous.first(where: { $0.id == selectedId }),
              // A Trash copy of a live conversation is never carried into a
              // list that does not show it that way.
              !(projectedBefore.contains(selectedId) && !projectedAfter.contains(selectedId))
        else { return reloaded }
        return [pin] + reloaded
    }

    /// Opening a conversation from a link, a search pick or Ask AI shows it
    /// as it is live: a Trash copy of it in the list gives way to `stored`
    /// (its stored row), and it leaves the projected set, so the pane loads
    /// the live reader. Pure — tested.
    static func openingLive(_ stored: MailThread, in list: [MailThread],
                            projected: Set<String>) -> (list: [MailThread], projected: Set<String>) {
        guard projected.contains(stored.id) else { return (list, projected) }
        var nextList = list
        if let index = nextList.firstIndex(where: { $0.id == stored.id }) {
            nextList[index] = stored
        }
        var nextProjected = projected
        nextProjected.remove(stored.id)
        return (nextList, nextProjected)
    }

    /// Whether the reading pane shows the open thread from its trashed
    /// messages only; part of the pane's identity, so a change remounts it.
    static func showsTrashReader(openedId: String?, projected: Set<String>) -> Bool {
        openedId.map(projected.contains) ?? false
    }

    /// Decide whether a completed reload may consume an `openThread` pin.
    ///
    /// The pin is bound to a specific `threadReloadGeneration` (the in-flight
    /// `commitSearch` reload when the user picked a hit). A later generation
    /// means that reload was superseded (new query, view switch, …) — do not
    /// pin the old hit into the new list. Selection must still be the pinned
    /// thread so j/k or a click away cancels the pin.
    static func pinDecision(
        pendingThreadId: String?,
        pendingGeneration: Int?,
        completedGeneration: Int,
        currentSelectedId: String?
    ) -> PinDecision {
        guard let pendingThreadId, let pendingGeneration else { return .ignore }
        if completedGeneration == pendingGeneration,
           currentSelectedId == pendingThreadId {
            return .apply(threadId: pendingThreadId)
        }
        // Same epoch but selection moved, or a newer reload finished (the
        // open's reload was cancelled and never applied).
        if completedGeneration >= pendingGeneration {
            return .clear
        }
        // Older completion: generation guard in MailStore should prevent this.
        return .ignore
    }
}
