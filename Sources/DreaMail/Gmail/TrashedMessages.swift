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
        var byThread: [String: [Message]] = [:]
        for start in stride(from: 0, to: threadIds.count, by: 500) {
            let chunk = Array(threadIds[start..<min(start + 500, threadIds.count)])
            for message in try Message.filter(chunk.contains(Column("threadId"))).fetchAll(db) {
                byThread[message.threadId, default: []].append(message)
            }
        }
        var out: [String: ThreadUndo.TrashState] = [:]
        for id in threadIds {
            let messages = byThread[id] ?? []
            out[id] = ThreadUndo.TrashState(liveIds: liveIds(messages),
                                            trashedIds: trashedIds(messages))
        }
        return out
    }

    /// A Trash view restore: the stored (live) row and the ids to restore.
    struct RestoreTarget: Sendable {
        var row: MailThread
        var trashedIds: [String]
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
