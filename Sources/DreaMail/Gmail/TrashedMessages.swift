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
        let trashed = messages.filter(isTrashed)
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

    /// Gmail ids of `messages` outside the trash (what a trash reaches).
    static func liveIds(_ messages: [Message]) -> [String] {
        messages.filter { !isTrashed($0) }.map(\.gmailId)
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
