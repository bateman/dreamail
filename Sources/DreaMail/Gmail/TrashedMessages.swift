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
        try SyncEngine.deriveThreads(db, for: [threadId], accountId: accountId)
    }

    /// The restores `change` had stored on the message rows
    /// (`applyRestore`): its `modifyMessages` steps that take TRASH off.
    /// An undo's re-trash step adds TRASH and only ever reached the thread
    /// row, so it is not one. Pure — tested.
    static func storedRestores(in change: RemoteThreadChange)
        -> [(ids: [String], add: [String], remove: [String])] {
        switch change {
        case .modifyMessages(let ids, let add, let remove) where remove.contains("TRASH"):
            return [(ids: ids, add: add, remove: remove)]
        case .sequence(let steps):
            return steps.flatMap(storedRestores(in:))
        default:
            return []
        }
    }

    /// Gmail refused `change`, or its queued copy was dropped: the restores
    /// it had stored locally are undone on exactly their messages (TRASH
    /// back, the restore's labels off), so the re-derive that follows lists
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
