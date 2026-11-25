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
    // shortcut: the cap counts messages, not threads; a mailbox with over
    // 2000 snoozed messages gets a partial Snoozed list (only adds).
    static let maxPages = 4

    /// Cadence of the listing (one `messages.list`, 5 quota units).
    static let interval: TimeInterval = 15 * 60
    /// Wait after Gmail refused the listing (400, 403): no retry loop
    /// against an operator or account that refuses it.
    static let backoff: TimeInterval = 6 * 60 * 60

    /// When the next listing may run. Only a refusal (HTTP 400 or 403) backs
    /// off; offline, 5xx, 429 or a cancelled sync retry at the normal cadence.
    static func nextCheck(after now: Date, failure: Error?) -> Date {
        if case GmailError.http(let code, _)? = failure, code == 400 || code == 403 {
            return now.addingTimeInterval(backoff)
        }
        return now.addingTimeInterval(interval)
    }

    /// Thread ids of the listing, paging through at most `maxPages`.
    /// `complete` false when it stopped at the cap.
    static func listThreadIds(
        fetchPage: (_ pageToken: String?) async throws -> GMessageList
    ) async throws -> (threadIds: Set<String>, complete: Bool) {
        var threadIds = Set<String>()
        var pageToken: String?
        var pages = 0
        repeat {
            let page = try await fetchPage(pageToken)
            threadIds.formUnion((page.messages ?? []).map(\.threadId))
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < maxPages
        return (threadIds, pageToken == nil)
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
                WHERE accountId = ? AND gmailSnoozed = 0 AND snoozeUntil IS NULL
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
