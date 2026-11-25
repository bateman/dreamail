import CryptoKit
import Foundation
import GRDB

/// What a system notification says, and the identifier it is posted under
/// (F-11).
///
/// A delivered notification lives in Notification Center, outside the
/// encrypted cache, and macOS may show it on the lock screen. By default it
/// therefore names no sender, subject or snippet: "New mail", "Follow-up
/// reminder", "Scheduled message sent", or a count. Sender and subject come
/// back only for the accounts whose "Show sender and subject in
/// notifications" is on (`Account.notificationDetails`, Settings ▸
/// Accounts). The decision is made per account of the mail notified: a
/// notification about one account's mail follows that account, and one that
/// covers several accounts shows details only if all of them allow it. The
/// snippet is never shown.
///
/// Every identifier names the account(s) it is about, so removing an
/// account can withdraw exactly its notifications (F-04). The system keeps
/// identifiers in its notification database whatever the setting, so the
/// account and the thread appear only as salted hashes.
enum NotificationContent {
    /// UserDefaults key of the app-wide switch of earlier builds, off by
    /// default. Read once, by migration v64, which copies it onto every
    /// account then; nothing writes it any more.
    static let legacyShowDetailsKey = "notifications.showSenderAndSubject"

    static func legacyShowsDetails(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: legacyShowDetailsKey)
    }

    /// Only the real mailbox retires the old switch, once it has run v64:
    /// a restored older copy of it must not turn accounts back on from a
    /// key no screen can change any more. The demo and UI-test databases
    /// leave it for the real one, which may migrate after them.
    static func retiresLegacySwitch(isRealMailbox: Bool, migrated: Bool) -> Bool {
        isRealMailbox && migrated
    }

    static func retireLegacySwitch(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyShowDetailsKey)
    }

    /// The ids of the accounts whose notifications may show sender and
    /// subject, read from the database at the time of notifying, never
    /// from a published copy that can lag behind a change. Every place that
    /// posts a notification decides through this. A failed read gives no
    /// account: generic.
    static func detailAccounts(_ db: Database) -> Set<String> {
        (try? Set(String.fetchAll(
            db, sql: "SELECT id FROM account WHERE notificationDetails = 1"))) ?? []
    }

    /// Stores an account's choice. Turning it off also withdraws what
    /// Notification Center still holds for the account (`withdraw`,
    /// `Notifier.removeNotifications(forAccount:)`), so no detail stays
    /// there after the user said none should.
    static func setDetails(_ db: Database, accountId: String, on: Bool,
                           withdraw: (String) -> Void) throws {
        try db.execute(sql: "UPDATE account SET notificationDetails = ? WHERE id = ?",
                       arguments: [on, accountId])
        if !on { withdraw(accountId) }
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

    /// Mail of the accounts in `detailAccounts` is posted with sender and
    /// subject, the rest generically. The two groups never share a
    /// notification, so a count covers only accounts of one kind.
    static func newMail(_ items: [MailItem], detailAccounts: Set<String>,
                        salt: String = identifierSalt) -> [Request] {
        let (detailed, generic) = split(items, detailAccounts)
        return detailedMail(detailed, salt: salt) + genericMail(generic, salt: salt)
    }

    private static func genericMail(_ items: [MailItem], salt: String) -> [Request] {
        guard !items.isEmpty else { return [] }
        guard items.count == 1, let only = items.first else {
            return [Request(
                id: identifier(kind: .mail, accounts: items.map(\.accountId), key: "batch",
                               salt: salt),
                title: "\(items.count) new messages", body: "")]
        }
        return [Request(id: threadIdentifier(kind: .mail, item: only, salt: salt),
                        title: "New mail", body: "")]
    }

    private static func detailedMail(_ items: [MailItem], salt: String) -> [Request] {
        guard !items.isEmpty else { return [] }
        var requests = items.prefix(detailedMailLimit).map { item in
            Request(id: threadIdentifier(kind: .mail, item: item, salt: salt),
                    title: item.sender, body: subjectLine(item.subject))
        }
        if items.count > detailedMailLimit {
            requests.append(Request(
                id: identifier(kind: .mail, accounts: items.map(\.accountId), key: "batch",
                               salt: salt),
                title: "DreaMail", body: "\(items.count) new messages"))
        }
        return requests
    }

    /// Same split as `newMail`.
    static func reminders(_ items: [MailItem], detailAccounts: Set<String>,
                          salt: String = identifierSalt) -> [Request] {
        let (detailed, generic) = split(items, detailAccounts)
        let shown = detailed.map { item in
            Request(id: threadIdentifier(kind: .reminder, item: item, salt: salt),
                    title: "Follow up: \(item.sender)", body: subjectLine(item.subject))
        }
        guard !generic.isEmpty else { return shown }
        guard generic.count == 1, let only = generic.first else {
            return shown + [Request(
                id: identifier(kind: .reminder, accounts: generic.map(\.accountId),
                               key: "batch", salt: salt),
                title: "\(generic.count) follow-up reminders", body: "")]
        }
        return shown + [Request(
            id: threadIdentifier(kind: .reminder, item: only, salt: salt),
            title: "Follow-up reminder", body: "")]
    }

    /// `showDetails`: the setting of the account that sent it.
    static func scheduledSent(accountId: String, rowId: Int64, subject: String,
                              showDetails: Bool, salt: String = identifierSalt) -> Request {
        Request(id: identifier(kind: .scheduled, accounts: [accountId], key: String(rowId),
                               salt: salt),
                title: "Scheduled message sent",
                body: showDetails ? subjectLine(subject) : "")
    }

    /// Items of accounts that allow details, then the others; order kept.
    private static func split(_ items: [MailItem], _ detailAccounts: Set<String>)
        -> (detailed: [MailItem], generic: [MailItem]) {
        (items.filter { detailAccounts.contains($0.accountId) },
         items.filter { !detailAccounts.contains($0.accountId) })
    }

    private static func subjectLine(_ subject: String) -> String {
        subject.isEmpty ? "(no subject)" : subject
    }

    // MARK: - Identifiers

    enum Kind: String, CaseIterable {
        case mail, reminder, scheduled
    }

    /// `<kind>/<account>[,<account>…]/<key>`, each account as a salted hash
    /// (`hashed`), sorted so the same set of accounts always gives the same
    /// identifier and a newer count replaces an older one. Hashes are hex, so
    /// they can neither split the identifier nor match another account's.
    static func identifier(kind: Kind, accounts: [String], key: String,
                           salt: String = identifierSalt) -> String {
        let encoded = Set(accounts.map { hashed($0, salt: salt) }).sorted()
        return "\(kind.rawValue)/\(encoded.joined(separator: ","))/\(key)"
    }

    /// A per-thread identifier. The thread id starts with the address, so it
    /// is hashed too.
    private static func threadIdentifier(kind: Kind, item: MailItem, salt: String) -> String {
        identifier(kind: kind, accounts: [item.accountId],
                   key: hashed(item.threadId, salt: salt), salt: salt)
    }

    /// The identifiers a thread's own notifications are posted under (new
    /// mail, follow-up reminder), so they can be withdrawn once the thread's
    /// mail is deleted. Counts ("3 new messages") name no thread and stay.
    static func threadIdentifiers(accountId: String, threadId: String,
                                  salt: String = identifierSalt) -> [String] {
        let item = MailItem(accountId: accountId, threadId: threadId, sender: "", subject: "")
        return [Kind.mail, .reminder].map { threadIdentifier(kind: $0, item: item, salt: salt) }
    }

    /// True when the notification `identifier` must go once `accountId` is
    /// removed: it names that account, or it predates account-scoped
    /// identifiers and cannot say which account it was about.
    static func belongs(_ identifier: String, toAccount accountId: String,
                        salt: String = identifierSalt) -> Bool {
        let parts = identifier.split(separator: "/", maxSplits: 2,
                                     omittingEmptySubsequences: false)
        if parts.count == 3, Kind(rawValue: String(parts[0])) != nil {
            let target = hashed(accountId, salt: salt)
            return parts[1].split(separator: ",").contains { String($0) == target }
        }
        return isLegacy(identifier)
    }

    /// 16 hex chars of SHA-256(salt, value). Exact match on the value:
    /// account ids are stored as Google returns them.
    static func hashed(_ value: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "\u{0}" + value).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static let saltKey = "NotificationIdentifierSalt"
    /// Random per-install salt, created on first use, as `DiagnosticLog`
    /// does for its account tag. Separate from that salt, so a log tag and
    /// a notification identifier cannot be matched with each other.
    static let identifierSalt: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: saltKey), !existing.isEmpty { return existing }
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let salt = Data(bytes).base64EncodedString()
        defaults.set(salt, forKey: saltKey)
        return salt
    }()

    /// Earlier builds posted `mail.<threadId>`, `mail.batch`,
    /// `reminder.<threadId>` and `scheduled.<rowId>`. A thread id starts with
    /// its account, but an address can be a prefix of another one, so these
    /// are all withdrawn on any removal.
    static func isLegacy(_ identifier: String) -> Bool {
        ["mail.", "reminder.", "scheduled."].contains { identifier.hasPrefix($0) }
    }
}
