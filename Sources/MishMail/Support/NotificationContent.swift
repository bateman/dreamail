import Foundation

/// What a system notification says, and the identifier it is posted under
/// (F-11).
///
/// A delivered notification lives in Notification Center, outside the
/// encrypted cache, and macOS may show it on the lock screen. By default it
/// therefore names no sender, subject or snippet: "New mail", "Follow-up
/// reminder", "Scheduled message sent", or a count. Sender and subject come
/// back only when the user turns on `showDetailsKey`. The snippet is never
/// shown.
///
/// Every identifier names the account(s) it is about, so removing an
/// account can withdraw exactly its notifications (F-04).
enum NotificationContent {
    /// UserDefaults key, off by default.
    static let showDetailsKey = "notifications.showSenderAndSubject"

    static func showsDetails(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showDetailsKey)
    }

    struct Request: Equatable {
        var id: String
        var title: String
        var body: String
    }

    struct MailItem: Equatable {
        var accountId: String
        var threadId: String
        var sender: String
        var subject: String
    }

    /// Detailed mode posts this many threads one by one, then a count for
    /// the rest. Same cap as before the setting existed.
    static let detailedMailLimit = 3

    static func newMail(_ items: [MailItem], showDetails: Bool) -> [Request] {
        guard !items.isEmpty else { return [] }
        let batch = Request(
            id: identifier(kind: .mail, accounts: items.map(\.accountId), key: "batch"),
            title: "\(items.count) new messages", body: "")
        guard showDetails else {
            guard items.count == 1, let only = items.first else { return [batch] }
            return [Request(
                id: identifier(kind: .mail, accounts: [only.accountId], key: only.threadId),
                title: "New mail", body: "")]
        }
        var requests = items.prefix(detailedMailLimit).map { item in
            Request(id: identifier(kind: .mail, accounts: [item.accountId], key: item.threadId),
                    title: item.sender, body: subjectLine(item.subject))
        }
        if items.count > detailedMailLimit {
            requests.append(Request(id: batch.id, title: "MishMail",
                                    body: "\(items.count) new messages"))
        }
        return requests
    }

    static func reminders(_ items: [MailItem], showDetails: Bool) -> [Request] {
        guard !items.isEmpty else { return [] }
        guard showDetails else {
            guard items.count == 1, let only = items.first else {
                return [Request(
                    id: identifier(kind: .reminder, accounts: items.map(\.accountId), key: "batch"),
                    title: "\(items.count) follow-up reminders", body: "")]
            }
            return [Request(
                id: identifier(kind: .reminder, accounts: [only.accountId], key: only.threadId),
                title: "Follow-up reminder", body: "")]
        }
        return items.map { item in
            Request(id: identifier(kind: .reminder, accounts: [item.accountId], key: item.threadId),
                    title: "Follow up: \(item.sender)", body: subjectLine(item.subject))
        }
    }

    static func scheduledSent(accountId: String, rowId: Int64, subject: String,
                              showDetails: Bool) -> Request {
        Request(id: identifier(kind: .scheduled, accounts: [accountId], key: String(rowId)),
                title: "Scheduled message sent",
                body: showDetails ? subjectLine(subject) : "")
    }

    private static func subjectLine(_ subject: String) -> String {
        subject.isEmpty ? "(no subject)" : subject
    }

    // MARK: - Identifiers

    enum Kind: String, CaseIterable {
        case mail, reminder, scheduled
    }

    /// `<kind>/<account>[,<account>…]/<key>`. Accounts are percent-encoded
    /// down to letters and digits, so `/`, `,` and `.` inside an address can
    /// neither split the identifier nor make one address a prefix of another.
    static func identifier(kind: Kind, accounts: [String], key: String) -> String {
        var seen = Set<String>()
        let encoded = accounts.map(encode).filter { seen.insert($0).inserted }
        return "\(kind.rawValue)/\(encoded.joined(separator: ","))/\(key)"
    }

    /// True when the notification `identifier` must go once `accountId` is
    /// removed: it names that account, or it predates account-scoped
    /// identifiers and cannot say which account it was about.
    static func belongs(_ identifier: String, toAccount accountId: String) -> Bool {
        let parts = identifier.split(separator: "/", maxSplits: 2,
                                     omittingEmptySubsequences: false)
        if parts.count == 3, Kind(rawValue: String(parts[0])) != nil {
            return parts[1].split(separator: ",").contains { String($0) == encode(accountId) }
        }
        return isLegacy(identifier)
    }

    /// Earlier builds posted `mail.<threadId>`, `mail.batch`,
    /// `reminder.<threadId>` and `scheduled.<rowId>`. A thread id starts with
    /// its account, but an address can be a prefix of another one, so these
    /// are all withdrawn on any removal.
    static func isLegacy(_ identifier: String) -> Bool {
        ["mail.", "reminder.", "scheduled."].contains { identifier.hasPrefix($0) }
    }

    private static func encode(_ accountId: String) -> String {
        accountId.addingPercentEncoding(withAllowedCharacters: alphanumerics) ?? accountId
    }

    /// ASCII only: `CharacterSet.alphanumerics` also admits non-ASCII
    /// letters, which then pass through unencoded.
    private static let alphanumerics = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
}
