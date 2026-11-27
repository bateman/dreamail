import Foundation
import GRDB

/// The per-account setting "Show Promotions and Social" (DEC-056: settings per
/// account). On by default. Off, the two views and everything that offers
/// them are closed for that account; the mail itself is never touched: it
/// stays in the Inbox, All Mail, search, counts, badges and notifications.
///
/// Kept in UserDefaults like the account's other local options (only the off
/// state is stored; `AccountLifecycle.accountDefaultsKeys` clears it). Pure
/// and hostless-tested (`CategoryRowsTests`).
enum CategoryRows {
    static func defaultsKey(accountId: String) -> String {
        "categoryRows.\(accountId)"
    }

    /// The two Gmail categories the setting covers.
    static let categories: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]

    static func isOn(accountId: String, _ defaults: UserDefaults = .standard) -> Bool {
        let key = defaultsKey(accountId: accountId)
        // `bool(forKey:)` also reads a launch argument (`-key NO`) as a Bool.
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// On is the default: only the off state is stored.
    static func setOn(_ on: Bool, accountId: String, _ defaults: UserDefaults = .standard) {
        if on {
            defaults.removeObject(forKey: defaultsKey(accountId: accountId))
        } else {
            defaults.set(false, forKey: defaultsKey(accountId: accountId))
        }
    }

    /// The accounts of `accounts` that have the setting off.
    static func off(accounts: [String], _ defaults: UserDefaults = .standard) -> Set<String> {
        Set(accounts.filter { !isOn(accountId: $0, defaults) })
    }

    static func isCategoryView(_ view: MailboxView) -> Bool {
        view == .promotions || view == .social
    }

    /// Whether the two views exist for the sidebar in `scope` (one account,
    /// or nil for "All accounts"): an account shows them when its setting is
    /// on; the all-accounts view shows them when any account does.
    static func shown(accounts: [String], scope: String?, off: Set<String>) -> Bool {
        let inScope = scope.map { [$0] } ?? accounts
        return inScope.isEmpty || inScope.contains { !off.contains($0) }
    }

    /// `view`, or the Inbox when it is one of the two closed views.
    static func view(_ view: MailboxView, shown: Bool) -> MailboxView {
        !shown && isCategoryView(view) ? .inbox : view
    }

    /// The Inbox category filter with the two categories taken out while they
    /// are closed: a stored pick for them has no effect (and stays stored).
    static func scoped(_ filter: CategoryFilter, shown: Bool) -> CategoryFilter {
        guard !shown else { return filter }
        var scoped = filter
        scoped.hide.subtract(categories)
        scoped.show.subtract(categories)
        return scoped
    }

    /// `edited` (what the user just picked while the two are closed) with the
    /// stored pick for them put back, so turning the setting on again finds it.
    static func restoring(_ edited: CategoryFilter, from stored: CategoryFilter?,
                          shown: Bool) -> CategoryFilter {
        guard !shown, let stored else { return edited }
        var result = edited
        result.hide.formUnion(stored.hide.intersection(categories))
        result.show.formUnion(stored.show.intersection(categories))
        return result
    }

    /// The Promotions and Social lists of the all-accounts view hold the mail
    /// of the accounts that have the setting on only.
    static func restrict(_ query: QueryInterfaceRequest<MailThread>, view: MailboxView,
                         activeAccount: String?, off: Set<String>)
        -> QueryInterfaceRequest<MailThread> {
        guard activeAccount == nil, isCategoryView(view), !off.isEmpty else { return query }
        return query.filter(!off.contains(Column("accountId")))
    }
}
