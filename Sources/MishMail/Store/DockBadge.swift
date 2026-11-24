import Foundation

/// Rules of the Dock badge, kept free of AppKit so the hostless suite runs
/// them. `Notifier.setBadge` paints what these return; `MailStore` is the
/// only caller and decides when.
///
/// What it counts (Gmail's rule): unread conversations in the primary
/// Inbox — not archived, trashed, spam, Promotions/Social, actively snoozed,
/// nor Updates/Forums while the inbox filter hides them. It is the
/// `"inbox"` sidebar count, scoped by `Scope` instead of the sidebar focus.
enum DockBadge {
    /// What the badge counts. Stored in UserDefaults ("badgeScope"): every
    /// account, the inbox currently focused in the sidebar, or one specific
    /// account ("account:<email>").
    enum Scope: RawRepresentable, Hashable {
        case all
        case focused
        case account(String)

        init?(rawValue: String) {
            switch rawValue {
            case "all": self = .all
            case "focused": self = .focused
            default:
                guard rawValue.hasPrefix("account:") else { return nil }
                self = .account(String(rawValue.dropFirst("account:".count)))
            }
        }

        var rawValue: String {
            switch self {
            case .all: return "all"
            case .focused: return "focused"
            case .account(let id): return "account:\(id)"
            }
        }

        /// The stored preference; missing or unreadable means every account.
        static func stored(_ raw: String?) -> Scope {
            raw.flatMap(Scope.init(rawValue:)) ?? .all
        }
    }

    /// Largest number shown; anything above reads "999+".
    static let cap = 999

    /// Text for `NSDockTile.badgeLabel`. Empty removes the badge.
    static func label(for count: Int) -> String {
        if count <= 0 { return "" }
        return count > cap ? "\(cap)+" : String(count)
    }

    /// Number for the notification-center badge, which takes no text.
    static func systemCount(for count: Int) -> Int {
        min(max(count, 0), cap)
    }

    /// The account the badge counts; nil = every account. "Focused"
    /// follows the sidebar (unified view = every account).
    static func account(for scope: Scope, focused: String?) -> String? {
        switch scope {
        case .all: return nil
        case .focused: return focused
        case .account(let id): return id
        }
    }

    /// Whether `thread` counts toward a badge scoped to `badgeAccount`.
    static func counts(
        _ thread: MailThread,
        badgeAccount: String?,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) -> Bool {
        if let badgeAccount, thread.accountId != badgeAccount { return false }
        return SidebarCounts.memberships(
            of: thread, now: now, hideCategories: hideCategories
        ).contains("inbox")
    }

    /// Change in the badge when a local action turns `old` into `new`:
    /// -1, 0 or +1. Lets the badge move in the same frame as the row,
    /// before the database recount confirms it.
    static func delta(
        from old: MailThread,
        to new: MailThread,
        badgeAccount: String?,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) -> Int {
        let before = counts(old, badgeAccount: badgeAccount, now: now,
                            hideCategories: hideCategories)
        let after = counts(new, badgeAccount: badgeAccount, now: now,
                           hideCategories: hideCategories)
        return (after ? 1 : 0) - (before ? 1 : 0)
    }
}
