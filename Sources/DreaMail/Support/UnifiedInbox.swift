import Foundation

/// Settings → Appearance: show the unified inbox ("All accounts"). One
/// global switch. Off, nothing in the app reaches the unified scope (the
/// rail's entry, ⌘1, saved views of all accounts): the list is always one
/// account's. The rules are here, on primitive types, so the hostless suite
/// can test them; `MailStore` applies them.
enum UnifiedInbox {
    static let enabledKey = "showUnifiedInbox"
    static let enabledDefault = true

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        // `object(forKey:)` is a string for a `-showUnifiedInbox NO` launch argument.
        defaults.object(forKey: enabledKey) == nil ? enabledDefault : defaults.bool(forKey: enabledKey)
    }

    /// The account filter to apply for a requested one. Unified off: no
    /// request (nil = every account) stands; the first account in rail order
    /// does. nil only when there is no account at all. A request for an account
    /// that is not in the rail counts as no request.
    static func scope(requested: String?, enabled: Bool, railOrder: [String]) -> String? {
        // An account that is gone (removed, or the demo left) is no request.
        let known = requested.flatMap { railOrder.contains($0) ? $0 : nil }
        if known != nil || enabled { return known }
        return railOrder.first
    }

    /// The account of a view being saved. Off, "all accounts" is not on
    /// offer: the account on screen, else the first.
    static func accountForNewView(requested: String?, enabled: Bool,
                                  active: String?, railOrder: [String]) -> String? {
        if requested != nil || enabled { return requested }
        return scope(requested: active, enabled: false, railOrder: railOrder)
    }

    /// The saved views the setting lets through (sidebar, Go menu, palette).
    static func visible<T>(_ views: [T], accountId: (T) -> String?, enabled: Bool) -> [T] {
        views.filter { savedViewVisible(accountId: accountId($0), enabled: enabled) }
    }

    /// The rail's "All accounts" entry: with one account it never shows
    /// (the account is the whole mailbox).
    static func railShowsEntry(enabled: Bool, accountCount: Int) -> Bool {
        enabled && accountCount > 1
    }

    /// A saved view scoped to all accounts (`accountId` nil) is part of the
    /// unified scope: hidden while it is off, never deleted.
    static func savedViewVisible(accountId: String?, enabled: Bool) -> Bool {
        enabled || accountId != nil
    }

    /// What ⌘1…⌘9 select. On: ⌘1 is All accounts, ⌘2… the accounts in rail
    /// order. Off: ⌘1… are the accounts.
    enum Shortcut: Equatable {
        case unified
        case account(String)
        case none
    }

    static func shortcut(digit: Int, enabled: Bool, railOrder: [String]) -> Shortcut {
        if enabled, digit == 1 { return .unified }
        let index = digit - (enabled ? 2 : 1)
        return railOrder.indices.contains(index) && index >= 0 ? .account(railOrder[index]) : .none
    }

    /// The digit of the account at `index` in the rail (its tooltip).
    static func shortcutDigit(forAccountAt index: Int, enabled: Bool) -> Int {
        index + (enabled ? 2 : 1)
    }
}
