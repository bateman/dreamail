import XCTest
import GRDB

/// Conversations snoozed in Gmail itself (`GmailSnoozed`, option B of the
/// snooze alignment): listed with `in:snoozed`, shown under Snoozed, never
/// woken by MishMail, cleared when Gmail puts INBOX back.
final class GmailSnoozedTests: XCTestCase {

    private let account = "a@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Account(id: "b@x.com", displayName: "B", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func thread(_ id: String, account: String? = nil, inInbox: Bool = false,
                        inTrash: Bool = false, inSpam: Bool = false,
                        snoozeUntil: Date? = nil, gmailSnoozed: Bool = false,
                        isUnread: Bool = false) -> MailThread {
        let acct = account ?? self.account
        var t = MailThread(
            id: "\(acct):\(id)", accountId: acct, gmailThreadId: id,
            subject: id, snippet: "", fromDisplay: "F", lastDate: Date(),
            isUnread: isUnread, isStarred: false, inInbox: inInbox, inTrash: inTrash,
            labelIds: inInbox ? "INBOX" : "", snoozeUntil: snoozeUntil,
            participants: "F", messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.inSpam = inSpam
        t.gmailSnoozed = gmailSnoozed
        return t
    }

    private func flagged(_ q: DatabaseQueue) throws -> [String] {
        try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM thread WHERE gmailSnoozed = 1 ORDER BY id
                """)
        }
    }

    // MARK: - Listing applied to the cache

    func testListingFlagsOnlyArchivedRowsOfTheAccount() throws {
        let q = try makeDB()
        try q.write { db in
            try self.thread("archived").insert(db)
            try self.thread("inbox", inInbox: true).insert(db)
            try self.thread("trash", inTrash: true).insert(db)
            try self.thread("spam", inSpam: true).insert(db)
            try self.thread("archived", account: "b@x.com").insert(db)
            try GmailSnoozed.apply(db, accountId: self.account,
                                   threadIds: ["archived", "inbox", "trash", "spam", "unknown"],
                                   complete: true)
        }
        // Inbox, trash and spam never flagged: a wrong listing cannot hide mail.
        XCTAssertEqual(try flagged(q), ["\(account):archived"])
    }

    func testCompleteListingUnflagsWhatGmailNoLongerLists() throws {
        let q = try makeDB()
        try q.write { db in
            try self.thread("t1", gmailSnoozed: true).insert(db)
            try self.thread("t2", gmailSnoozed: true).insert(db)
            try self.thread("t1", account: "b@x.com", gmailSnoozed: true).insert(db)
            try GmailSnoozed.apply(db, accountId: self.account, threadIds: ["t2"], complete: true)
        }
        XCTAssertEqual(try flagged(q), ["\(account):t2", "b@x.com:t1"])
        // An empty complete listing (nothing snoozed, or the operator gives
        // nothing) leaves the app as without option B.
        try q.write { db in
            try GmailSnoozed.apply(db, accountId: self.account, threadIds: [], complete: true)
        }
        XCTAssertEqual(try flagged(q), ["b@x.com:t1"])
    }

    func testCutOffListingOnlyAdds() throws {
        let q = try makeDB()
        try q.write { db in
            try self.thread("t1", gmailSnoozed: true).insert(db)
            try self.thread("t2").insert(db)
            try GmailSnoozed.apply(db, accountId: self.account, threadIds: ["t2"], complete: false)
        }
        XCTAssertEqual(try flagged(q), ["\(account):t1", "\(account):t2"])
    }

    func testCadenceAndBackoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(GmailSnoozed.nextCheck(after: now, succeeded: true),
                       now.addingTimeInterval(15 * 60))
        XCTAssertEqual(GmailSnoozed.nextCheck(after: now, succeeded: false),
                       now.addingTimeInterval(6 * 60 * 60))
        XCTAssertEqual(GmailSnoozed.query, "in:snoozed")
    }

    // MARK: - Derive

    private func msg(_ labels: String) -> Message {
        Message(id: "\(account):m1", accountId: account, gmailId: "m1",
                threadId: "\(account):t1", fromHeader: "x@y.com", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: labels,
                isUnread: false, hasAttachment: false)
    }

    private func derive(_ labels: String, existing: MailThread?) -> MailThread? {
        SyncEngine.deriveThread(threadKey: "\(account):t1", gmailThreadId: "t1",
                                accountId: account, messages: [msg(labels)], existing: existing)
    }

    func testDeriveKeepsFlagUntilInboxTrashOrSpam() throws {
        let asleep = thread("t1", gmailSnoozed: true)
        XCTAssertTrue(try XCTUnwrap(derive("UNREAD", existing: asleep)).gmailSnoozed)
        for labels in ["INBOX", "TRASH", "SPAM"] {
            XCTAssertFalse(try XCTUnwrap(derive(labels, existing: asleep)).gmailSnoozed, labels)
        }
        XCTAssertFalse(try XCTUnwrap(derive("", existing: nil)).gmailSnoozed)
    }

    // MARK: - Lists, counts, notifications

    func testNeverWokenByMishMailAndListedUnderSnoozed() throws {
        let q = try makeDB()
        let now = Date()
        try q.write { db in
            // Snoozed here and in Gmail: Gmail's snooze wins, MishMail never wakes it.
            try self.thread("both", snoozeUntil: now.addingTimeInterval(-60),
                            gmailSnoozed: true).insert(db)
            try self.thread("gmail", gmailSnoozed: true).insert(db)
            try self.thread("local", snoozeUntil: now.addingTimeInterval(60)).insert(db)
            try self.thread("trashed", inTrash: true, gmailSnoozed: true).insert(db)
            try self.thread("plain").insert(db)
        }
        try q.read { db in
            XCTAssertEqual(try ThreadListQuery.dueSnoozes(now: now).fetchAll(db), [])
            XCTAssertEqual(try ThreadListQuery.snoozed(now: now).fetchAll(db)
                .map(\.gmailThreadId).sorted(), ["both", "gmail", "local"])
            XCTAssertEqual(try ThreadListQuery.snoozesToRelease(accountId: self.account)
                .fetchAll(db).map(\.gmailThreadId), ["local"])
            let counts = try SidebarCounts.fetch(db: db, activeAccount: nil,
                                                 badgeAccount: nil, now: now)
            XCTAssertEqual(counts.counts["snoozed"], 3, "each snoozed row counted once")
        }
    }

    func testSleepingForBadgeAndNotifications() {
        let now = Date()
        // Defensive: even with INBOX (Gmail's labels while snoozed are not
        // verified) a Gmail snooze stays out of the Dock badge and alerts.
        let asleep = thread("t1", inInbox: true, gmailSnoozed: true, isUnread: true)
        XCTAssertTrue(SidebarCounts.isActivelySnoozed(asleep, now: now))
        XCTAssertFalse(DockBadge.counts(asleep, badgeAccount: nil, now: now))
        XCTAssertTrue(SidebarCounts.memberships(of: asleep, now: now).contains("snoozed"))
        var awake = asleep
        awake.gmailSnoozed = false
        XCTAssertTrue(DockBadge.counts(awake, badgeAccount: nil, now: now))
        XCTAssertEqual(DockBadge.delta(from: asleep, to: awake, badgeAccount: nil, now: now), 1)

        var candidate = NewMailNotifications.Candidate(
            id: "a:t1", fromEmail: "x@y.com", allFromEmails: "x@y.com",
            lastInboundDate: now, isUnread: true, inInbox: true, inTrash: false,
            inSpam: false, inPromotions: false, inSocial: false, snoozeUntil: nil)
        XCTAssertTrue(NewMailNotifications.isEligible(candidate, now: now))
        candidate.gmailSnoozed = true
        XCTAssertFalse(NewMailNotifications.isEligible(candidate, now: now))
    }

    func testNotificationCandidatesSkipGmailSnoozed() throws {
        let q = try makeDB()
        try q.write { db in
            try self.thread("asleep", inInbox: true, gmailSnoozed: true, isUnread: true).insert(db)
            try self.thread("awake", inInbox: true, isUnread: true).insert(db)
        }
        let ids = try q.read { try NewMailNotifications.unreadInboxCandidates($0, now: Date()) }
            .map(\.id)
        XCTAssertEqual(ids, ["\(account):awake"])
    }
}
