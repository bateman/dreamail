import XCTest
import GRDB

/// Deleted means gone (DEC-019) inside a conversation: messages in the
/// trash stay out of a live conversation, and the one-time repair of rows
/// stored by the old trash rule never undoes a trash made here.
final class TrashedConversationTests: XCTestCase {
    private let account = "you@example.com"
    private var thread: String { "\(account):t1" }

    private func msg(_ id: String, minutesAgo: Double, labels: String,
                     from: String = "Ann <ann@example.com>", subject: String = "Plans",
                     unread: Bool = false) -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: thread, fromHeader: from, toHeader: account,
                ccHeader: "", bccHeader: "", subject: subject,
                date: Date(timeIntervalSinceNow: -minutesAgo * 60),
                snippet: "snippet-\(id)", bodyText: "body-\(id)", bodyHTML: nil,
                messageIdHeader: "<\(id)@example.com>", referencesHeader: "",
                labelIds: labels, isUnread: unread, hasAttachment: false)
    }

    /// Newest first, as sync passes them.
    private func derive(_ messages: [Message]) throws -> MailThread {
        try XCTUnwrap(SyncEngine.deriveThread(
            threadKey: thread, gmailThreadId: "t1", accountId: account,
            messages: messages.sorted { $0.date > $1.date }, existing: nil))
    }

    private func makeDB(_ messages: [Message], storedInTrash: Bool? = nil) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for m in messages { try m.insert(db) }
            var row = try self.derive(messages)
            if let storedInTrash { row.inTrash = storedInTrash }
            try row.insert(db)
        }
        return q
    }

    // MARK: - Scenario A: a deleted conversation brought back by a reply

    private var revived: [Message] {
        [msg("old1", minutesAgo: 600, labels: "TRASH", subject: "Secret plan"),
         msg("old2", minutesAgo: 500, labels: "TRASH SENT", from: "Me <you@example.com>"),
         msg("new", minutesAgo: 1, labels: "INBOX UNREAD", subject: "Re: Plans", unread: true)]
    }

    func testRevivedConversationRowCountsOnlyItsLiveMessages() throws {
        let t = try derive(revived)
        XCTAssertFalse(t.inTrash)
        XCTAssertTrue(t.inInbox)
        XCTAssertEqual(t.messageCount, 1)
        XCTAssertEqual(t.snippet, "snippet-new")
        XCTAssertEqual(t.subject, "Re: Plans", "the deleted first message does not name it")
        XCTAssertFalse(t.inSent, "the deleted sent reply does not list it in Sent")
        XCTAssertFalse(t.participants.contains("me"))
    }

    func testReaderOfARevivedConversationLeavesTheDeletedMessagesOut() throws {
        let q = try makeDB(revived)
        let payload = try q.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: self.thread, db: db)
        }
        XCTAssertEqual(payload.messages.map(\.gmailId), ["new"])
    }

    func testSearchDoesNotMatchADeletedMessageOfALiveConversation() throws {
        let q = try makeDB(revived)
        try q.read { db in
            let secret = try SearchFTS.filter(MailThread.all(), db: db, text: "secret")
                .fetchAll(db)
            XCTAssertEqual(secret, [], "only the deleted message says 'Secret'")
            let reply = try SearchFTS.filter(MailThread.all(), db: db, text: "plans")
                .fetchAll(db).map(\.id)
            XCTAssertEqual(reply, [self.thread])
        }
    }

    /// A conversation in the trash still shows (and matches) everything.
    func testFullyTrashedConversationKeepsAllItsMessages() throws {
        let messages = [msg("a", minutesAgo: 600, labels: "TRASH", subject: "Secret plan"),
                        msg("b", minutesAgo: 500, labels: "TRASH")]
        let q = try makeDB(messages)
        try q.read { db in
            let payload = try ThreadDetailRepository.fetchPayload(threadId: self.thread, db: db)
            XCTAssertEqual(payload.messages.map(\.gmailId), ["a", "b"])
            XCTAssertEqual(try SearchFTS.filter(MailThread.all(), db: db, text: "secret")
                            .fetchAll(db).map(\.id), [self.thread])
        }
    }

    // MARK: - Scenario B: a new message deleted on arrival (filter, other client)

    func testMessageDeletedOnArrivalDoesNotMakeTheConversationNewMail() throws {
        let live = msg("live", minutesAgo: 120, labels: "INBOX")
        let deleted = msg("spam", minutesAgo: 1, labels: "TRASH UNREAD",
                          from: "Promo <promo@example.com>", unread: true)
        let before = try derive([live])
        let after = try derive([live, deleted])
        XCTAssertFalse(after.isUnread, "no unread badge or count from a deleted message")
        XCTAssertEqual(after.snippet, "snippet-live")
        XCTAssertEqual(after.lastDate, live.date, "the row does not jump to the top")
        XCTAssertEqual(after.lastInboundDate, before.lastInboundDate)
        XCTAssertEqual(after.fromEmail, "ann@example.com")
        XCTAssertEqual(after.messageCount, 1)

        // The notification decision: the inbound date did not advance.
        var notifications = NewMailNotifications()
        notifications.seed([candidate(before)])
        XCTAssertEqual(notifications.fresh(current: [candidate(after)], now: Date(),
                                           demoMode: false, isBlocked: { _ in false }), [])
    }

    private func candidate(_ t: MailThread) -> NewMailNotifications.Candidate {
        NewMailNotifications.Candidate(
            id: t.id, fromEmail: t.fromEmail, allFromEmails: t.allFromEmails,
            lastInboundDate: t.lastInboundDate, isUnread: t.isUnread, inInbox: t.inInbox,
            inTrash: t.inTrash, inSpam: t.inSpam, inPromotions: t.inPromotions,
            inSocial: t.inSocial, snoozeUntil: t.snoozeUntil, gmailSnoozed: t.gmailSnoozed)
    }

    // MARK: - One-time repair (F2)

    /// A trash made here and still queued offline: the message rows have
    /// no TRASH yet, but the repair must not bring the conversation back.
    func testRepairSkipsAConversationWithAQueuedEdit() throws {
        let q = try makeDB([msg("m1", minutesAgo: 10, labels: "INBOX")], storedInTrash: true)
        XCTAssertEqual(try q.read { db in
            try SyncEngine.trashedThreadKeysWithLiveMail(db, accountId: self.account)
        }, [thread])
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO pendingThreadOp (accountId, gmailThreadId, changeJSON, createdAt, updatedAt)
                VALUES (?, 't1', x'7B7D', ?, ?)
                """, arguments: [self.account, Date(), Date()])
        }
        XCTAssertEqual(try q.read { db in
            try SyncEngine.trashedThreadKeysWithLiveMail(db, accountId: self.account)
        }, [])
    }

    // MARK: - Account removal (F4)

    func testRepairFlagGoesWithTheAccount() {
        let defaults = UserDefaults(suiteName: "trash-repair-\(UUID())")!
        XCTAssertTrue(AccountLifecycle.accountDefaultsKeys(accountId: account, in: defaults)
                        .contains(SyncEngine.revivedTrashRepairKey(accountId: account)))
    }
}
