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

    // MARK: - Count state

    /// The count on the Dock and what it was counted for. Two writers:
    /// database recounts (authoritative) and local actions (optimistic
    /// deltas). `MailStore` holds one and paints whatever it accepts.
    struct Counter: Equatable {
        /// Last accepted count; nil until the first recount lands.
        private(set) var count: Int?
        /// The badge account `count` was counted for (nil = every account).
        private(set) var account: String?
        /// Bumped by every local action, so a recount whose read started
        /// before it cannot undo its delta.
        private(set) var epoch = 0

        /// Taken when a recount's read starts.
        struct Ticket: Equatable {
            let epoch: Int
            let account: String?
        }

        func ticket(account: String?) -> Ticket {
            Ticket(epoch: epoch, account: account)
        }

        /// A database recount. Rejected when a local action happened after
        /// its read started: that read may predate the action's write, and
        /// the action's own reconciliation recount follows.
        @discardableResult
        mutating func applyRecount(_ value: Int, ticket: Ticket) -> Bool {
            guard ticket.epoch == epoch else { return false }
            count = max(0, value)
            account = ticket.account
            return true
        }

        /// A local action, `delta` summed over every thread it touched.
        /// Applied only to a count of the same scope: right after a scope,
        /// focus or account change the count belongs to the old one, and
        /// the recount that change starts will set it.
        @discardableResult
        mutating func applyDelta(_ delta: Int, account: String?) -> Bool {
            epoch += 1
            guard delta != 0, let current = count, self.account == account else {
                return false
            }
            count = max(0, current + delta)
            return true
        }
    }

    // MARK: - Per-account counts

    /// Unread per account, for the badge on each account's avatar. Same
    /// predicate as the Dock badge (`SidebarCounts.fetchUnreadByAccount`)
    /// and the same two writers: recounts (authoritative) and local
    /// actions (optimistic deltas, via `delta`).
    struct AccountCounts: Equatable {
        private(set) var counts: [String: Int] = [:]
        /// Bumped by every local action, so a recount whose read started
        /// before it cannot undo its delta.
        private(set) var epoch = 0

        /// Unread for one account; 0 when unknown or none.
        func unread(for account: String) -> Int { counts[account] ?? 0 }

        /// A database recount, taken with the `epoch` read before it began.
        /// Accounts missing from it (none unread, or removed) drop out.
        @discardableResult
        mutating func applyRecount(_ new: [String: Int], epoch: Int) -> Bool {
            guard epoch == self.epoch else { return false }
            counts = new.filter { $0.value > 0 }
            return true
        }

        /// A local action: `delta` per account, summed over its threads.
        mutating func applyDelta(_ delta: [String: Int]) {
            epoch += 1
            for (account, d) in delta where d != 0 {
                let value = max(0, (counts[account] ?? 0) + d)
                counts[account] = value > 0 ? value : nil
            }
        }
    }

    // MARK: - What macOS allows

    /// The app's notification permission, reduced to what the badge needs.
    enum Authorization: Equatable {
        case notDetermined
        case denied
        case allowed
    }

    /// Why the badge may not be visible, from the notification settings and
    /// the last badge call. Codes only, never mail content.
    enum SystemStatus: Equatable {
        case unknown
        case notAsked
        case allowed
        case badgesOff
        case notificationsOff
        case failed(code: Int)
    }

    static func status(
        authorization: Authorization, badgeEnabled: Bool, lastErrorCode: Int?
    ) -> SystemStatus {
        switch authorization {
        case .denied: return .notificationsOff
        case .notDetermined: return .notAsked
        case .allowed:
            if !badgeEnabled { return .badgesOff }
            if let lastErrorCode { return .failed(code: lastErrorCode) }
            return .allowed
        }
    }

    /// One line for Settings; `problem` asks for the System Settings button.
    static func summary(_ status: SystemStatus) -> (text: String, problem: Bool) {
        switch status {
        case .unknown:
            return ("Checking…", false)
        case .notAsked:
            return ("Notification permission not asked yet", false)
        case .allowed:
            return ("Badges allowed", false)
        case .badgesOff:
            return ("Off in System Settings ▸ Notifications: turn on “Badge application icon”", true)
        case .notificationsOff:
            return ("Notifications are off in System Settings; macOS may hide the badge", true)
        case .failed(let code):
            return ("macOS refused the badge (error \(code))", true)
        }
    }
}
