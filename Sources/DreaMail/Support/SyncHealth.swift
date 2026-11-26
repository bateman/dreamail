import Foundation

/// Whether each account's last sync pass failed, and what the sync control
/// and Settings → Accounts say about it. A failure never moves "last synced":
/// that is `Account.lastSyncAt`, stamped only by a pass that completed. The
/// text is generic: no error detail, no mail data. Pure — unit-tested.
struct SyncHealth: Equatable {
    /// When each account's latest pass failed; cleared by its next success.
    private(set) var failedAt: [String: Date] = [:]

    mutating func recordFailure(account: String, at date: Date = Date()) {
        failedAt[account] = date
    }

    mutating func recordSuccess(account: String) {
        failedAt.removeValue(forKey: account)
    }

    /// An account the app no longer has (removed while a pass ran).
    mutating func forget(account: String) {
        failedAt.removeValue(forKey: account)
    }

    /// The account's latest pass did not complete, or Google refuses its
    /// saved sign-in (background passes then skip it until the user acts).
    func failed(account: String, needsReauth: Bool) -> Bool {
        needsReauth || failedAt[account] != nil
    }

    func anyFailed(accounts: [String], needingReauth: Set<String>) -> Bool {
        accounts.contains { failed(account: $0, needsReauth: needingReauth.contains($0)) }
    }

    // MARK: - Text

    /// The sync control's label: when the oldest account last synced, and
    /// that the last pass failed when it did. nil: nothing to say (never
    /// synced, no failure).
    static func toolbarText(lastSuccess: Date?, failed: Bool, now: Date,
                            locale: Locale = .current) -> String? {
        let when = lastSuccess.map { relative($0, now: now, locale: locale) }
        guard failed else { return when }
        guard let when else { return "Sync failed" }
        return "Sync failed · last synced \(when)"
    }

    /// The line under an account in Settings → Accounts.
    static func settingsText(lastSuccess: Date?, failed: Bool, now: Date,
                             locale: Locale = .current) -> String? {
        let when = lastSuccess.map { relative($0, now: now, locale: locale) }
        guard failed else { return when.map { "Last sync \($0)" } }
        guard let when else { return "Last sync failed" }
        return "Last sync failed · last successful sync \(when)"
    }

    /// "now", "3 minutes ago", "3 hours ago". A future date (a clock
    /// moved back) reads as now.
    static func relative(_ date: Date, now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// How often the label is redrawn so its relative time keeps moving
    /// while no pass ends (a static "now" once hid hours without a sync).
    static let refreshInterval: TimeInterval = 30
}
