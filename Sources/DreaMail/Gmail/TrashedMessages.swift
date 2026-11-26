import Foundation

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

    /// SQL for the same rule, for queries joining `message` to a thread
    /// row aliased `thread`.
    static func shownSQL(thread: String = "thread", message: String = "message") -> String {
        "(\(thread).inTrash = 1 OR (' ' || \(message).labelIds || ' ') NOT LIKE '% TRASH %')"
    }
}
