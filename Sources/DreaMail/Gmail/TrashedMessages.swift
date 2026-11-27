import Foundation
import GRDB

/// Which messages of a conversation are shown and counted. As in Gmail, a
/// conversation that is not in the trash shows only its messages outside
/// the trash: messages deleted earlier stay deleted when new mail brings
/// the conversation back, and a message deleted from a live conversation
/// leaves it. A conversation in the trash shows all of its messages.
enum TrashedMessages {
    static func isTrashed(_ message: Message) -> Bool {
        SyncEngine.labelIdsContain(message.labelIds, "TRASH")
    }

    /// `messages` as shown for a thread whose row has `threadInTrash`.
    /// Never empty for a non-empty input (a lone trashed row shows itself).
    static func shown(_ messages: [Message], threadInTrash: Bool) -> [Message] {
        guard !threadInTrash else { return messages }
        let live = messages.filter { !isTrashed($0) }
        return live.isEmpty ? messages : live
    }

    /// `messages` as the Trash view shows them: a conversation in the trash
    /// shows all; a live one with trashed messages shows only those.
    static func inTrashView(_ messages: [Message], threadInTrash: Bool) -> [Message] {
        guard !threadInTrash else { return messages }
        // As counted and restored (`trashedIds`): no discarded drafts.
        let trashed = messages.filter { isTrashed($0) && !isDraft($0) }
        return trashed.isEmpty ? messages : trashed
    }

    /// The Trash view's row for a live conversation with trashed messages:
    /// derived from those messages only (`messages` newest first), so it
    /// shows their sender, snippet and date. Nil when none is trashed.
    static func trashViewRow(_ thread: MailThread, messages: [Message]) -> MailThread? {
        let trashed = messages.filter { isTrashed($0) && !SyncEngine.labelIdsContain($0.labelIds, "DRAFT") }
        guard !trashed.isEmpty,
              var row = SyncEngine.deriveThread(
                threadKey: thread.id, gmailThreadId: thread.gmailThreadId,
                accountId: thread.accountId, messages: trashed, existing: thread)
        else { return nil }
        row.inTrash = true
        return row
    }

    /// The Trash view's rows: a live conversation's row is replaced by
    /// `trashViewRow`; `projected` names those rows (their stored row is
    /// live). Order is kept, so the page cursor (from the stored rows) stays
    /// valid.
    static func projectTrashView(_ rows: [MailThread], db: Database) throws
        -> (rows: [MailThread], projected: Set<String>) {
        var out: [MailThread] = []
        var projected = Set<String>()
        out.reserveCapacity(rows.count)
        for row in rows {
            guard !row.inTrash else { out.append(row); continue }
            let messages = try Message.filter(Column("threadId") == row.id)
                .order(Column("date").desc).fetchAll(db)
            if let shown = trashViewRow(row, messages: messages) {
                out.append(shown)
                projected.insert(row.id)
            } else {
                out.append(row)
            }
        }
        return (out, projected)
    }

    static func isDraft(_ message: Message) -> Bool {
        SyncEngine.labelIdsContain(message.labelIds, "DRAFT")
    }

    /// Gmail ids of `messages` outside the trash (what a trash reaches).
    /// Drafts are left out: a draft's message id changes on every save, and
    /// one unknown id can fail a whole `messages.batchModify`.
    static func liveIds(_ messages: [Message]) -> [String] {
        messages.filter { !isTrashed($0) && !isDraft($0) }.map(\.gmailId)
    }

    /// Per thread, its messages split for `ThreadUndo.undoTrashRemote`:
    /// one query for every thread (in chunks), drafts left out.
    static func trashStates(_ db: Database, threadIds: [String]) throws
        -> [String: ThreadUndo.TrashState] {
        // Only the three columns needed, not whole message rows.
        var byThread: [String: [(gmailId: String, labelIds: String)]] = [:]
        for start in stride(from: 0, to: threadIds.count, by: 500) {
            let chunk = Array(threadIds[start..<min(start + 500, threadIds.count)])
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadId, gmailId, labelIds FROM message
                WHERE threadId IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                ORDER BY rowid
                """, arguments: StatementArguments(chunk))
            for row in rows {
                byThread[row["threadId"], default: []].append((row["gmailId"], row["labelIds"]))
            }
        }
        var out: [String: ThreadUndo.TrashState] = [:]
        for id in threadIds {
            var live: [String] = []
            var trashed: [String] = []
            for m in byThread[id] ?? [] {
                guard !SyncEngine.labelIdsContain(m.labelIds, "DRAFT") else { continue }
                if SyncEngine.labelIdsContain(m.labelIds, "TRASH") {
                    trashed.append(m.gmailId)
                } else {
                    live.append(m.gmailId)
                }
            }
            out[id] = ThreadUndo.TrashState(liveIds: live, trashedIds: trashed)
        }
        return out
    }

    /// A Trash view restore: the stored (live) row and the ids to restore.
    struct RestoreTarget: Sendable {
        var row: MailThread
        var trashedIds: [String]
    }

    /// A restore from the Trash, as stored locally before Gmail answers:
    /// the named messages take the label change (TRASH off), and the thread
    /// row is derived again from its messages. Call inside one write.
    static func applyRestore(_ db: Database, accountId: String, threadId: String,
                             ids: [String], add: [String], remove: [String]) throws {
        try relabel(db, accountId: accountId, ids: ids, add: add, remove: remove)
        // shortcut: the re-derive starts from the message rows, so a thread
        // edit not yet in them (archive, star, read made just before, still
        // unsynced or queued) shows its message-row state until the next
        // sync. Gmail gets the edit either way.
        try SyncEngine.deriveThreads(db, for: [threadId], accountId: accountId)
    }

    /// An action on some messages of a conversation (star, delete, mark
    /// unread from the message's header), as stored locally before Gmail
    /// answers. The thread row can hold a thread-level edit its message
    /// rows do not have yet (read on open, archive, star from the list);
    /// Gmail applies such an edit to every message of the thread, so it is
    /// first written to the shown messages, then `applyRestore` relabels
    /// `ids` and derives the row again. Without this, starring a message
    /// right after opening an unread conversation showed it unread again.
    /// The thread row is read again here, inside the write: a reply a sync
    /// stored since `thread` was read must not be marked read. `thread`
    /// stands in only when the row is gone. Call inside one write.
    static func applyMessageEdit(_ db: Database, thread captured: MailThread,
                                 ids: [String], add: [String], remove: [String]) throws {
        let thread = try MailThread.fetchOne(db, key: captured.id) ?? captured
        let messages = try Message.filter(Column("threadId") == thread.id).fetchAll(db)
        let visible = Self.shown(messages, threadInTrash: thread.inTrash)
        for (label, flag) in [("UNREAD", thread.isUnread), ("STARRED", thread.isStarred),
                              ("INBOX", thread.inInbox)] {
            let holders = visible.filter { SyncEngine.labelIdsContain($0.labelIds, label) }
            if !flag, !holders.isEmpty {
                try relabel(db, accountId: thread.accountId, ids: holders.map(\.gmailId),
                            add: [], remove: [label])
            } else if flag, holders.isEmpty {
                try relabel(db, accountId: thread.accountId, ids: visible.map(\.gmailId),
                            add: [label], remove: [])
            }
        }
        try applyRestore(db, accountId: thread.accountId, threadId: thread.id,
                         ids: ids, add: add, remove: remove)
    }

    /// The per-message edits `change` had stored on the message rows
    /// (`applyRestore`): a Trash restore, or an action on one message of an
    /// open conversation (star, delete, mark unread, and their undo). These
    /// are its `modifyMessages` steps, except the re-trash step of a trash
    /// undo (`ThreadUndo.undoTrashRemote`): it adds TRASH right after the
    /// thread-level un-trash and only ever reached the thread row.
    /// shortcut: a message delete queued offline right after the undo of a
    /// conversation trash has the same shape, so a refusal of that delete
    /// leaves the message trashed locally until the next sync of its labels.
    /// Pure — tested.
    static func storedRestores(in change: RemoteThreadChange)
        -> [(ids: [String], add: [String], remove: [String])] {
        let steps: [RemoteThreadChange]
        if case .sequence(let inner) = change { steps = inner } else { steps = [change] }
        var out: [(ids: [String], add: [String], remove: [String])] = []
        for (index, step) in steps.enumerated() {
            switch step {
            case .modifyMessages(let ids, let add, let remove):
                if add.contains("TRASH"), index > 0,
                   case .modify(_, let before) = steps[index - 1], before.contains("TRASH") {
                    continue
                }
                out.append((ids: ids, add: add, remove: remove))
            case .sequence:
                out += storedRestores(in: step)
            default:
                continue
            }
        }
        return out
    }

    /// Gmail refused `change`, or its queued copy was dropped: the edits
    /// it had stored locally (`storedRestores`) are undone on exactly their
    /// messages. For a restore: TRASH back, the restore's labels off, so the
    /// re-derive that follows lists
    /// the conversation in the Trash again instead of showing the messages
    /// live while Gmail keeps them in its trash. A label the message
    /// already had before the restore is taken off too; the message is in
    /// the trash, where that label shows nowhere. Call inside the write
    /// that re-derives the thread. Returns whether a row changed.
    @discardableResult
    static func revertStoredRestores(_ db: Database, accountId: String,
                                     change: RemoteThreadChange) throws -> Bool {
        let restores = storedRestores(in: change)
        for r in restores {
            try relabel(db, accountId: accountId, ids: r.ids, add: r.remove, remove: r.add)
        }
        return !restores.isEmpty
    }

    private static func relabel(_ db: Database, accountId: String, ids: [String],
                                add: [String], remove: [String]) throws {
        for id in ids {
            let key = "\(accountId):\(id)"
            guard let message = try Message.fetchOne(db, key: key) else { continue }
            let labels = SyncEngine.applyLabelDelta(labelIds: message.labelIds, add: add, remove: remove)
            try db.execute(sql: "UPDATE message SET labelIds = ?, isUnread = ? WHERE id = ?",
                           arguments: [labels, SyncEngine.labelIdsContain(labels, "UNREAD"), key])
        }
    }

    /// The stored rows of `threadIds` that still have trashed messages.
    static func restoreTargets(_ db: Database, threadIds: [String]) throws -> [RestoreTarget] {
        try threadIds.compactMap { id in
            guard let row = try MailThread.fetchOne(db, key: id) else { return nil }
            let ids = trashedIds(try Message.filter(Column("threadId") == id).fetchAll(db))
            return ids.isEmpty ? nil : RestoreTarget(row: row, trashedIds: ids)
        }
    }

    /// Gmail ids of the trashed non-draft messages (what "Move out of
    /// Trash" restores in a live conversation).
    static func trashedIds(_ messages: [Message]) -> [String] {
        messages.filter { isTrashed($0) && !SyncEngine.labelIdsContain($0.labelIds, "DRAFT") }
            .map(\.gmailId)
    }

    /// The Trash view's filter: a conversation in the trash, or one with a
    /// trashed non-draft message. The label union prefilter keeps the
    /// per-thread EXISTS to threads that have TRASH somewhere.
    static func inTrashViewSQL(thread: String = "thread") -> String {
        """
        (\(thread).inTrash = 1 OR ((' ' || \(thread).labelIds || ' ') LIKE '% TRASH %' AND EXISTS (
            SELECT 1 FROM message AS trashed_message
            WHERE trashed_message.threadId = \(thread).id
              AND (' ' || trashed_message.labelIds || ' ') LIKE '% TRASH %'
              AND (' ' || trashed_message.labelIds || ' ') NOT LIKE '% DRAFT %')))
        """
    }

    /// SQL for the same rule, for queries joining `message` to a thread
    /// row aliased `thread`.
    static func shownSQL(thread: String = "thread", message: String = "message") -> String {
        "(\(thread).inTrash = 1 OR (' ' || \(message).labelIds || ' ') NOT LIKE '% TRASH %')"
    }
}
