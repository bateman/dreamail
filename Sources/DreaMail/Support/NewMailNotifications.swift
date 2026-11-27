import Foundation
import GRDB

/// Which unread inbox threads deserve a "new mail" notification.
///
/// Session state, keyed by thread id, holding the newest *inbound* message
/// date already accounted for. A plain id set could only grow: once a thread
/// had notified (or was unread at launch) a later reply in it stayed silent
/// for the rest of the session. Comparing dates lets that reply through while
/// a manual mark-unread — same date — stays quiet.
///
/// Pure so the rules are unit-tested; `MailStore.notifyNewMail` only reads
/// the rows and posts.
struct NewMailNotifications {
    /// The thread columns the decision needs. Property names match the
    /// `thread` columns so the call site can fetch this projection directly.
    struct Candidate: Equatable, Decodable, FetchableRecord {
        var id: String
        var fromEmail: String
        var allFromEmails: String
        var lastInboundDate: Date?
        var isUnread: Bool
        var inInbox: Bool
        var inTrash: Bool
        var inSpam: Bool
        var inPromotions: Bool
        var inSocial: Bool
        var snoozeUntil: Date?
        var gmailSnoozed: Bool = false
        /// A star pins a thread through an Inbox category hide (`CategoryHide`).
        var isStarred: Bool = false
        /// Space-separated Gmail label ids, for an Updates / Forums hide.
        var labelIds: String = ""
    }

    /// False until the launch baseline (or the first sync pass, whichever
    /// comes first) has been adopted.
    private(set) var isSeeded = false
    private var knownInbound: [String: Date] = [:]
    /// Per account: mail that arrived before this is backlog (a first sync
    /// downloading what was there before the account was added).
    private var backlogBefore: [String: Date] = [:]

    /// A first sync of `accountId` starts (or a wider "Keep mail from"
    /// downloads older mail): threads it brings in whose newest
    /// inbound message is older than `date` are recorded without notifying.
    /// The earliest date is kept, so a resumed first sync still notifies
    /// for mail that arrived after the first attempt began.
    mutating func quietBacklog(accountId: String, before date: Date) {
        backlogBefore[accountId] = min(backlogBefore[accountId] ?? date, date)
    }

    func hasBacklog(accountId: String) -> Bool {
        backlogBefore[accountId] != nil
    }

    /// The backlog is downloaded (or the account removed, DEC-019): later
    /// first-seen threads notify as before, e.g. a snoozed thread waking.
    mutating func forgetBacklog(accountId: String) {
        backlogBefore[accountId] = nil
    }

    /// The account part of a thread id (`accountId:gmailThreadId`).
    static func accountId(ofThread id: String) -> String {
        guard let colon = id.range(of: ":", options: .backwards) else { return id }
        return String(id[..<colon.lowerBound])
    }

    /// Unread and awake in the Inbox, whatever its Gmail category.
    /// `unreadInboxCandidates` narrows the read in SQL; this is the rule of
    /// record. An Inbox category hide does not make a thread ineligible: it
    /// only silences it (`isHidden`), so the thread is still recorded and
    /// lifting the hide or starring it later does not replay old mail.
    static func isEligible(_ c: Candidate, now: Date) -> Bool {
        guard c.isUnread, c.inInbox, !c.inTrash, !c.inSpam else { return false }
        if let until = c.snoozeUntil, until > now { return false }
        return !c.gmailSnoozed
    }

    /// Whether the user's Inbox category hide (`hide`, empty by default)
    /// keeps the thread out of the Inbox list: same rule as the list and its
    /// unread badge (`SidebarCounts.isHiddenFromInbox`), a star pins through.
    static func isHidden(_ c: Candidate, hide: Set<String>,
                         categoryRowsOff: Set<String> = []) -> Bool {
        SidebarCounts.isHiddenFromInbox(
            hide: CategoryRows.hide(hide, account: accountId(ofThread: c.id),
                                    off: categoryRowsOff), isStarred: c.isStarred, inPromotions: c.inPromotions,
            inSocial: c.inSocial, labelIds: c.labelIds)
    }

    /// Adopts `current` as already known, so none of it notifies.
    mutating func seed(_ current: [Candidate]) {
        for c in current { record(c) }
        isSeeded = true
    }

    /// Ids to notify for, in `current` order, and records them as known.
    ///
    /// Silent when: this is the first pass (it becomes the baseline), the
    /// thread is first seen and its mail is backlog (`quietBacklog`), demo
    /// mode, the thread has no inbound message (own sent mail), the inbound
    /// date did not advance, a blocked sender wrote in the thread, or the
    /// user's Inbox category hide (`hide`) keeps it out of the Inbox list.
    /// Silent passes still record what they saw, so unblocking a sender,
    /// leaving the demo, lifting a hide or starring hidden mail does not
    /// replay old mail as new.
    mutating func fresh(current: [Candidate], now: Date, demoMode: Bool,
                        hide: Set<String> = [],
                        categoryRowsOff: Set<String> = [],
                        isBlocked: (String) -> Bool) -> [String] {
        guard isSeeded else {
            seed(current.filter { Self.isEligible($0, now: now) })
            return []
        }
        var ids: [String] = []
        for c in current where Self.isEligible(c, now: now) {
            guard let inbound = c.lastInboundDate else { continue }
            if let known = knownInbound[c.id], inbound <= known { continue }
            let unseen = knownInbound[c.id] == nil
            knownInbound[c.id] = inbound
            if unseen, !backlogBefore.isEmpty,
               let cutoff = backlogBefore[Self.accountId(ofThread: c.id)], inbound < cutoff {
                continue
            }
            if demoMode || Self.hasBlockedSender(c, isBlocked: isBlocked)
                || Self.isHidden(c, hide: hide, categoryRowsOff: categoryRowsOff) { continue }
            ids.append(c.id)
        }
        return ids
    }

    private mutating func record(_ c: Candidate) {
        // No inbound date: nothing to compare a later reply against, and the
        // first inbound message in the thread should notify.
        guard let inbound = c.lastInboundDate else { return }
        knownInbound[c.id] = max(knownInbound[c.id] ?? inbound, inbound)
    }

    /// Any-message match, like `MailStore.applyBlocklist`.
    private static func hasBlockedSender(_ c: Candidate,
                                         isBlocked: (String) -> Bool) -> Bool {
        if isBlocked(c.fromEmail) { return true }
        return c.allFromEmails.split(separator: " ").contains { isBlocked(String($0)) }
    }

    // MARK: - Read

    /// The current candidates. A narrow projection — `fetchAll()` of whole
    /// rows decoded every column of every unread inbox thread (participants,
    /// snippet, label blob) just to throw nearly all of it away. `select`
    /// pushes the projection into SQL, so SQLCipher only decrypts what the
    /// decision needs.
    static func unreadInboxCandidates(_ db: Database, now: Date) throws -> [Candidate] {
        // Every unread Inbox thread, any category: the Inbox lists them all
        // by default. An Inbox category hide only silences (`fresh`).
        // Match inbox badge / inbox list: skip actively snoozed rows so
        // a sleeping unread does not notify or seed the baseline.
        try MailThread
            .filter(Column("isUnread") == true)
            .filter(Column("inInbox") == true)
            .filter(Column("inTrash") == false)
            .filter(Column("inSpam") == false)
            .filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
            .filter(Column("gmailSnoozed") == false)
            .select(Column("id"), Column("fromEmail"), Column("allFromEmails"),
                    Column("lastInboundDate"), Column("isUnread"), Column("inInbox"),
                    Column("inTrash"), Column("inSpam"), Column("inPromotions"),
                    Column("inSocial"), Column("snoozeUntil"), Column("gmailSnoozed"),
                    Column("isStarred"), Column("labelIds"))
            .asRequest(of: Candidate.self)
            .fetchAll(db)
    }
}
