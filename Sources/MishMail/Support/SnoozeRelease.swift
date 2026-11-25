import Foundation

/// Before an account is removed, its MishMail snoozes go back to Gmail's
/// Inbox: the snooze date lives only in this Mac's database, so once the
/// account is gone nothing would ever wake them and they would stay archived
/// on Gmail for good. Conversations snoozed in Gmail itself are left to
/// Gmail (`ThreadListQuery.snoozesToRelease`).
enum SnoozeRelease {
    /// Adds INBOX to each Gmail thread id in order and stops at the first
    /// failure: offline or an expired sign-in fails every later call the same
    /// way, and the removal must not wait on a run of timeouts. Returns how
    /// many were not put back. `reachable` false sends nothing.
    static func release(_ gmailThreadIds: [String], reachable: Bool,
                        addInbox: (String) async throws -> Void) async -> Int {
        guard reachable else { return gmailThreadIds.count }
        for (i, id) in gmailThreadIds.enumerated() {
            do { try await addInbox(id) } catch { return gmailThreadIds.count - i }
        }
        return 0
    }

    /// What the user is told after the removal when some could not be put
    /// back; nil when all were. The removal itself goes ahead either way.
    static func notReleasedMessage(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let what = count == 1 ? "1 conversation snoozed in MishMail"
                              : "\(count) conversations snoozed in MishMail"
        return "The account was removed, but Gmail couldn't be reached to put \(what) "
            + "back in the Inbox. In Gmail \(count == 1 ? "it stays" : "they stay") archived: "
            + "find \(count == 1 ? "it" : "them") in All Mail."
    }
}
