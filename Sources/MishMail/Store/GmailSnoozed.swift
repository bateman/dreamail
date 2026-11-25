import Foundation
import GRDB

/// Conversations snoozed in Gmail itself (web or phone), shown under
/// Snoozed with no wake-up time. Gmail's API documents no snooze: the list
/// comes from the `in:snoozed` search operator, which `messages.list` `q`
/// accepts like the Gmail search box. Gmail wakes these, never MishMail.
///
/// Fail-safe by construction: a flag is set only on a row that is already
/// out of the Inbox, trash and spam, so a listing that returns the wrong
/// mail can at most file an archived conversation under Snoozed; it never
/// hides Inbox mail or changes anything on Gmail.
enum GmailSnoozed {
    static let query = "in:snoozed"

    /// Pages of 500 per listing. A larger set is marked partly and never
    /// unmarked from a cut-off listing.
    static let maxPages = 4

    /// Cadence of the listing (one `messages.list`, 5 quota units).
    static let interval: TimeInterval = 15 * 60
    /// Wait after a failed listing: no retry loop against an operator or
    /// account that refuses it.
    static let backoff: TimeInterval = 6 * 60 * 60

    static func nextCheck(after now: Date, succeeded: Bool) -> Date {
        now.addingTimeInterval(succeeded ? interval : backoff)
    }

    /// Replaces the account's flags with the listing. `complete` false (the
    /// listing stopped at `maxPages`): only adds, since an unlisted row may
    /// be on a page not read.
    static func apply(_ db: Database, accountId: String,
                      threadIds: Set<String>, complete: Bool) throws {
        if complete {
            let flagged = try String.fetchAll(db, sql: """
                SELECT gmailThreadId FROM thread WHERE accountId = ? AND gmailSnoozed = 1
                """, arguments: [accountId])
            let gone = flagged.filter { !threadIds.contains($0) }
            for chunk in chunks(gone) {
                try db.execute(sql: """
                    UPDATE thread SET gmailSnoozed = 0
                    WHERE accountId = ? AND gmailThreadId IN (\(placeholders(chunk.count)))
                    """, arguments: StatementArguments([accountId] + chunk))
            }
        }
        for chunk in chunks(threadIds.sorted()) {
            try db.execute(sql: """
                UPDATE thread SET gmailSnoozed = 1
                WHERE accountId = ? AND gmailSnoozed = 0
                AND inInbox = 0 AND inTrash = 0 AND inSpam = 0
                AND gmailThreadId IN (\(placeholders(chunk.count)))
                """, arguments: StatementArguments([accountId] + chunk))
        }
    }

    private static func chunks(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }
}
