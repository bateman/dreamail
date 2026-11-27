import Foundation

/// The local and Gmail sides of the undoable triage actions, and of their
/// undo. Pure so the round trip is tested against the database.
///
/// Two constraints shape the undo:
/// - `OptimisticThreadWrite` persists only the columns that differ from its
///   base, so the undo must start from the post-action copy (`acted`). From
///   the pre-action snapshot no column differs and the row keeps the action.
/// - The undo restores INBOX only when the thread had it. A thread trashed
///   from All Mail, Sent or a search goes back where it was, not to the inbox.
enum ThreadUndo {
    enum Action: Equatable {
        case archive
        case trash
        case spam
        case notSpam
        case snooze(until: Date)
    }

    struct Plan {
        let acted: MailThread
        let actRemote: RemoteThreadChange
        let restored: MailThread
        let undoRemote: RemoteThreadChange
    }

    // MARK: - Action

    static func apply(_ action: Action, _ t: inout MailThread) {
        switch action {
        case .archive:
            // Archive always marks read: selection advance cancels the
            // reading-pane dwell timer, and Gmail treats the thread as seen.
            t.inInbox = false
            t.isUnread = false
        case .trash:
            // Keep labelIds and the denormalized flags coherent so search
            // filters on inTrash and labelIds-based UI agree.
            t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        case .spam:
            t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
        case .notSpam:
            t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
        case .snooze(let until):
            t.snoozeUntil = until
            t.inInbox = false
        }
    }

    /// Wake or unsnooze: back to the Inbox now. INBOX goes into `labelIds`
    /// too, not only the flag: a re-snooze before the next sync then still
    /// reads as "archive not confirmed yet", instead of a stale label set
    /// without INBOX that a sync would take for "moved back to Inbox" and
    /// clear the new date (`SyncEngine.preservedSnoozeUntil`).
    static func unsnooze(_ t: inout MailThread) {
        t.snoozeUntil = nil
        t.applyLabelMutation(add: ["INBOX"])
        t.endGmailSnoozeIfInboxed()
    }

    static func remote(_ action: Action) -> RemoteThreadChange {
        switch action {
        case .archive: return .modify(remove: ["INBOX", "UNREAD"])
        case .trash: return .trash
        case .spam: return .modify(add: ["SPAM"], remove: ["INBOX"])
        case .notSpam: return .modify(add: ["INBOX"], remove: ["SPAM"])
        case .snooze: return .modify(remove: ["INBOX"])
        }
    }

    // MARK: - Undo

    /// Local undo. `t` must be the post-action copy; `wasInInbox` comes from
    /// the pre-action snapshot.
    static func restore(_ action: Action, wasInInbox: Bool, _ t: inout MailThread) {
        let inbox: Set<String> = wasInInbox ? ["INBOX"] : []
        switch action {
        case .archive:
            // Undo restores the inbox only; the thread stays read (matches
            // Gmail's undo-archive).
            t.inInbox = wasInInbox
            t.isUnread = false
        case .trash:
            t.applyLabelMutation(add: inbox, remove: ["TRASH"])
        case .spam:
            t.applyLabelMutation(add: inbox, remove: ["SPAM"])
        case .notSpam:
            t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
        case .snooze:
            t.snoozeUntil = nil
            t.inInbox = wasInInbox
        }
    }

    /// A thread's messages just before a trash (Gmail ids, drafts left out).
    struct TrashState: Equatable, Sendable {
        var liveIds: [String]
        var trashedIds: [String]
    }

    /// Undo of a trash. `threads.trash` reaches every message Gmail holds,
    /// including ones this Mac does not store (pruned by date, or arrived
    /// after the last sync), so the undo always un-trashes the whole
    /// thread: no mail the trash reached can stay behind in Gmail's Trash.
    /// When the thread already had trashed messages, those are put back in
    /// the trash afterwards (deleted earlier: they stay deleted).
    /// - Nothing trashed before, or unknown state (nil): the thread-level
    ///   un-trash alone, as before.
    /// - A conversation entirely in the trash is never trashed again
    ///   (`MailStore.trash`), so there is no undo for it to get wrong.
    /// Queued with a trash not sent yet, the pair folds so the trash is
    /// never sent (`RemoteThreadChange.merged`).
    static func undoTrashRemote(wasInInbox: Bool, before: TrashState?) -> RemoteThreadChange {
        let untrash = undoRemote(.trash, wasInInbox: wasInInbox)
        guard let before, !before.trashedIds.isEmpty else { return untrash }
        let inbox = wasInInbox ? ["INBOX"] : []
        return .sequence([untrash, .modifyMessages(ids: before.trashedIds, add: ["TRASH"], remove: inbox)])
    }

    /// Gmail side of the undo. Can be empty (archive or snooze of a thread
    /// that had no INBOX): the caller must not send an empty modify.
    static func undoRemote(_ action: Action, wasInInbox: Bool) -> RemoteThreadChange {
        let inbox = wasInInbox ? ["INBOX"] : []
        switch action {
        case .archive, .snooze: return .modify(add: inbox)
        case .trash: return .modify(add: inbox, remove: ["TRASH"])
        case .spam: return .modify(add: inbox, remove: ["SPAM"])
        case .notSpam: return .modify(add: ["SPAM"], remove: ["INBOX"])
        }
    }

    /// Bulk undo: one group per pre-action inbox state, because one bulk
    /// mutation carries one Gmail change. `acted` are the post-action copies
    /// (the diff base); `originals` are the pre-action snapshots. List order
    /// is kept inside each group; empty groups are dropped.
    static func undoGroups(
        acted: [MailThread], originals: [MailThread]
    ) -> [(wasInInbox: Bool, threads: [MailThread])] {
        let inboxIds = Set(originals.lazy.filter(\.inInbox).map(\.id))
        let inInbox = acted.filter { inboxIds.contains($0.id) }
        let outside = acted.filter { !inboxIds.contains($0.id) }
        var groups: [(wasInInbox: Bool, threads: [MailThread])] = []
        if !inInbox.isEmpty { groups.append((true, inInbox)) }
        if !outside.isEmpty { groups.append((false, outside)) }
        return groups
    }

    /// The whole round trip for one thread.
    static func plan(_ action: Action, original: MailThread) -> Plan {
        var acted = original
        apply(action, &acted)
        var restored = acted
        restore(action, wasInInbox: original.inInbox, &restored)
        return Plan(acted: acted, actRemote: remote(action),
                    restored: restored,
                    undoRemote: undoRemote(action, wasInInbox: original.inInbox))
    }
}
