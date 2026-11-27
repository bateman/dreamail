import Foundation
import GRDB

/// Sidebar unread / dock badge aggregates.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit). Prefer per-predicate `COUNT(*)` over a full-table
/// `SUM(CASE…)` so SQLite can use partial indexes from migration v21.
enum SidebarCounts {
    /// Gmail categories the Inbox can hide (`CategoryFilter.hide`). Like
    /// Gmail with no category tabs, the Inbox lists every INBOX conversation
    /// by default; only a hide the user turned on removes one, and then from
    /// the list, the Inbox unread, the Dock badge and the avatar badges
    /// alike. A star pins through a hide, as in `CategoryHide`.
    static let inboxHideableCategories: Set<String> = [
        "CATEGORY_PROMOTIONS",
        "CATEGORY_SOCIAL",
        "CATEGORY_UPDATES",
        "CATEGORY_FORUMS",
    ]

    /// SQL AND-clause matching inbox list `notSnoozed`: no future snooze.
    /// Bind `now` as the sole argument for this fragment.
    static let notActivelySnoozedSQL =
        " AND gmailSnoozed = 0 AND (snoozeUntil IS NULL OR snoozeUntil <= ?)"

    /// True while the thread is sleeping (list-hidden from Inbox): a future
    /// local snooze, or snoozed in Gmail itself (`GmailSnoozed`).
    static func isActivelySnoozed(_ thread: MailThread, now: Date = Date()) -> Bool {
        if thread.gmailSnoozed { return true }
        guard let until = thread.snoozeUntil else { return false }
        return until > now
    }

    /// In-memory counterpart of the SQL predicates below. Optimistic thread
    /// actions use this to keep sidebar badges in the same frame as the row;
    /// the coalesced database reconciliation remains the source of truth.
    ///
    /// `hideCategories` is the inbox "do not contain" set (empty by
    /// default): it removes a category from the inbox badge only.
    /// Actively snoozed mail is list-hidden from Inbox/Promo/Social and must
    /// not inflate those unread badges (it still counts under Snoozed).
    static func memberships(
        of thread: MailThread,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) -> Set<String> {
        var result = Set<String>()
        let sleeping = isActivelySnoozed(thread, now: now)
        // Unread tab badges track the visible lists — not while snoozed.
        if thread.isUnread && !thread.inTrash && !thread.inSpam && thread.inInbox
            && !sleeping {
            if thread.inPromotions {
                result.insert("promotions")
            }
            if thread.inSocial {
                result.insert("social")
            }
            // Inbox badge: every conversation the Inbox lists, whatever its
            // category, unless the user hides that category (star pins
            // through, as in the list).
            if !isHiddenFromInbox(thread, hide: hideCategories) {
                result.insert("inbox")
            }
        }
        if thread.reminderAt != nil {
            result.insert("reminders")
        }
        if thread.isStarred && !thread.inTrash {
            result.insert("starred")
        }
        if sleeping && !thread.inTrash {
            result.insert("snoozed")
        }
        if thread.inDrafts && !thread.inTrash {
            result.insert("drafts")
        }
        // Same predicates as `fetchLabelUnread` and the Spam count.
        if thread.isUnread && thread.inSpam {
            result.insert("spam")
        }
        if thread.isUnread && !thread.inTrash && !thread.inSpam {
            for labelId in thread.userLabelIds {
                result.insert(labelKey(accountId: thread.accountId, labelId: labelId))
            }
        }
        return result
    }

    /// The `counts` key of one user label's unread count:
    /// `label:<account>:<labelId>`, i.e. `label:` + `LabelRow.id`.
    static func labelKey(accountId: String, labelId: String) -> String {
        "label:\(accountId):\(labelId)"
    }

    /// Unread conversations per user label, Gmail-style: unread, not in
    /// trash or spam. One grouped query for every label (never one per
    /// label): it walks the `thread_unread_live` partial index (v65) and
    /// looks each thread up in `thread_label` by its primary key. Keyed by
    /// `labelKey`; a label with no unread mail is absent.
    static func fetchLabelUnread(db: Database, account: String?) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: labelUnreadQuery(scoped: account != nil),
                                    arguments: StatementArguments(account.map { [$0] } ?? []))
        var out: [String: Int] = [:]
        for row in rows {
            let accountId: String = row["accountId"]
            let labelId: String = row["labelId"]
            let n: Int = row["n"]
            out[labelKey(accountId: accountId, labelId: labelId)] = n
        }
        return out
    }

    /// The grouped query behind `fetchLabelUnread` (and its index-plan
    /// test). `scoped` binds one account id.
    static func labelUnreadQuery(scoped: Bool) -> String {
        let scope = scoped ? "thread.accountId = ? AND " : ""
        return """
            SELECT thread.accountId AS accountId, thread_label.labelId AS labelId,
                   COUNT(*) AS n
            FROM thread JOIN thread_label ON thread_label.threadId = thread.id
            WHERE \(scope)(\(labelUnreadSQL))
            GROUP BY thread.accountId, thread_label.labelId
            """
    }

    /// Matches the `thread_unread_live` partial index exactly, so SQLite
    /// can use it.
    static let labelUnreadSQL =
        "thread.isUnread = 1 AND thread.inTrash = 0 AND thread.inSpam = 0"

    /// Whether the inbox category hide set removes this thread from the
    /// Inbox list: in a hidden category and not starred (`CategoryHide`).
    static func isHiddenFromInbox(_ thread: MailThread, hide: Set<String>) -> Bool {
        guard !thread.isStarred else { return false }
        let labels = Set(thread.labels)
        for cat in hide where inboxHideableCategories.contains(cat) {
            switch cat {
            case "CATEGORY_PROMOTIONS": if thread.inPromotions { return true }
            case "CATEGORY_SOCIAL": if thread.inSocial { return true }
            default: if labels.contains(cat) { return true }
            }
        }
        return false
    }

    /// SQL fragment (AND-joined) with the same rule as `CategoryHide.apply`
    /// for the categories in `hide`. Empty when none apply (the default).
    static func inboxHideSQL(hide: Set<String>) -> String {
        var parts: [String] = []
        for cat in hide.sorted() where inboxHideableCategories.contains(cat) {
            switch cat {
            case "CATEGORY_PROMOTIONS": parts.append("(inPromotions = 0 OR isStarred = 1)")
            case "CATEGORY_SOCIAL": parts.append("(inSocial = 0 OR isStarred = 1)")
            default:
                // labelIds is space-separated; bound tokens are fixed Gmail
                // ids (not user text), so interpolating is safe and matches
                // CategoryHide.
                parts.append("(labelIds NOT LIKE '%\(cat)%' OR isStarred = 1)")
            }
        }
        return parts.isEmpty ? "" : " AND " + parts.joined(separator: " AND ")
    }

    /// `activeAccount`/`badgeAccount` nil = every account.
    /// Safe off MainActor. Sole source of truth for sidebar unread — do not
    /// merge Gmail `labelInfo` / CATEGORY_* totals (those include spam +
    /// archived and disagree with list filters).
    ///
    /// `hideCategories` is the inbox category-hide set (typically from
    /// `FilterChips` for the inbox view; empty by default). A category drops
    /// out of the Inbox count only when it is hidden.
    static func fetch(
        db: Database,
        activeAccount: String?,
        badgeAccount: String?,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) throws -> (counts: [String: Int], badge: Int) {
        let hideSQL = inboxHideSQL(hide: hideCategories)
        // Not actively snoozed — same gate as inbox list `notSnoozed`. A reply
        // on a sleeping thread used to keep UNREAD+INBOX while list-hidden,
        // inflating the badge with nothing visible under is:unread.
        let awake = notActivelySnoozedSQL
        // Every unread conversation the Inbox lists (matches memberships).
        let inbox = try count(db, account: activeAccount,
                              where: primaryUnreadSQL(hideSQL: hideSQL),
                              arguments: [now])
        let promotions = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inPromotions = 1\(awake)
            """, arguments: [now])
        let social = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inSocial = 1\(awake)
            """, arguments: [now])
        let reminders = try count(db, account: activeAccount, where: """
            reminderAt IS NOT NULL
            """)
        let starred = try count(db, account: activeAccount, where: """
            isStarred = 1 AND inTrash = 0
            """)
        // Two counts so each reads its own partial index; the second skips
        // rows the first already counted.
        let snoozed = try count(db, account: activeAccount, where: """
            snoozeUntil IS NOT NULL AND snoozeUntil > ? AND inTrash = 0
            """, arguments: [now]) + count(db, account: activeAccount, where: """
            gmailSnoozed = 1 AND inTrash = 0 AND (snoozeUntil IS NULL OR snoozeUntil <= ?)
            """, arguments: [now])
        let drafts = try count(db, account: activeAccount, where: """
            inDrafts = 1 AND inTrash = 0
            """)
        // Unread spam, the number Gmail shows on its Spam row
        // (`thread_unread_spam`, v65).
        let spam = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inSpam = 1
            """)

        // Dock badge uses the same primary-inbox predicate as `inbox`, but
        // may scope to a different account. Reuse when scopes match.
        let badge: Int
        if badgeAccount == activeAccount {
            badge = inbox
        } else {
            badge = try count(db, account: badgeAccount,
                              where: primaryUnreadSQL(hideSQL: hideSQL),
                              arguments: [now])
        }

        var counts = [
            "inbox": inbox,
            "promotions": promotions,
            "social": social,
            "reminders": reminders,
            "starred": starred,
            "snoozed": snoozed,
            "drafts": drafts,
            "spam": spam,
        ]
        // The sidebar's label tree reads these by `labelKey`.
        counts.merge(try fetchLabelUnread(db: db, account: activeAccount)) { $1 }
        return (counts, badge)
    }

    /// The Inbox unread predicate behind the inbox count, the Dock badge and
    /// the per-account avatar badges: one definition, so they cannot drift.
    /// Same rows as the Inbox list (`ThreadListQuery.inbox` + `CategoryHide`),
    /// unread and out of spam. Bind `now` as its sole argument.
    static func primaryUnreadSQL(hideSQL: String) -> String {
        """
        isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1\(hideSQL)\(notActivelySnoozedSQL)
        """
    }

    /// Unread count per account (same predicate as the Dock badge); an
    /// account with none is absent. The per-account badges add up to the
    /// Dock badge when it counts every account.
    static func fetchUnreadByAccount(
        db: Database,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) throws -> [String: Int] {
        let predicate = primaryUnreadSQL(hideSQL: inboxHideSQL(hide: hideCategories))
        let rows = try Row.fetchAll(db, sql: """
            SELECT accountId, COUNT(*) AS n FROM thread
            WHERE (\(predicate)) GROUP BY accountId
            """, arguments: [now])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["accountId"] as String, $0["n"] as Int) })
    }

    /// `COUNT(*)` with optional account scope. `where` is raw SQL predicates
    /// only (no user text) — arguments bind separately.
    private static func count(
        _ db: Database,
        account: String?,
        where predicate: String,
        arguments: [any DatabaseValueConvertible] = []
    ) throws -> Int {
        if let account {
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM thread WHERE accountId = ? AND (\(predicate))",
                arguments: StatementArguments([account] + arguments)
            ) ?? 0
        }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM thread WHERE (\(predicate))",
            arguments: StatementArguments(arguments)
        ) ?? 0
    }
}
