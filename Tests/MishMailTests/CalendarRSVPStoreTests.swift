import XCTest
import GRDB

/// The answers sent to calendar invites (`CalendarRSVPStore`): kept in the
/// encrypted database per event and instance, shown only for the SEQUENCE
/// they answered, and gone with their message or account (DEC-019).
final class CalendarRSVPStoreTests: XCTestCase {
    private let me = "me@example.com"
    private let other = "other@example.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func addMessage(_ db: Database, account: String, gmailId: String,
                            thread: String = "t1") throws {
        if try !Account.exists(db, key: account) {
            try Account(id: account, displayName: account, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        let message = Message(
            id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
            threadId: "\(account):\(thread)",
            fromHeader: "Ada <ada@example.com>", toHeader: account, ccHeader: "",
            subject: "Invitation", date: Date(), snippet: "", bodyText: "Invitation",
            bodyHTML: nil, messageIdHeader: "<\(gmailId)@example.com>",
            referencesHeader: "", labelIds: "INBOX", isUnread: false, hasAttachment: true)
        _ = try SyncEngine.upsertPending(
            db, items: [.init(message: message, attachments: [], headersOnly: false)])
        try SyncEngine.deriveThreads(db, for: [message.threadId], accountId: account)
    }

    private func invite(_ ics: String) throws -> CalendarInvite {
        try XCTUnwrap(CalendarInvite.parse(ICSCorpus.crlf(ics)))
    }

    private func rowCount(_ q: DatabaseQueue) throws -> Int {
        try q.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM calendarRSVP") ?? 0 }
    }

    func testAnswerIsKeptAndReplaced() throws {
        let q = try makeDB()
        let inv = try invite(ICSCorpus.google)
        try q.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1")
            XCTAssertNil(try CalendarRSVPStore.current(db, invite: inv, accountId: self.me))
            try CalendarRSVPStore.record(db, status: .accepted, invite: inv,
                                         accountId: self.me, messageId: "\(self.me):m1")
            XCTAssertEqual(try CalendarRSVPStore.current(db, invite: inv, accountId: self.me), .accepted)
            try CalendarRSVPStore.record(db, status: .declined, invite: inv,
                                         accountId: self.me, messageId: "\(self.me):m1")
            XCTAssertEqual(try CalendarRSVPStore.current(db, invite: inv, accountId: self.me), .declined)
            XCTAssertNil(try CalendarRSVPStore.current(db, invite: inv, accountId: self.other),
                         "never answers for another account")
        }
        XCTAssertEqual(try rowCount(q), 1)
    }

    func testAnswerIsPerInstance() throws {
        let q = try makeDB()
        let all = CalendarInvite.parseAll(ICSCorpus.crlf(ICSCorpus.seriesWithException))
        let master = try XCTUnwrap(all.first { $0.recurrenceIdLine == nil })
        let instance = try XCTUnwrap(all.first { $0.recurrenceIdLine != nil })
        try q.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1")
            try CalendarRSVPStore.record(db, status: .tentative, invite: instance,
                                         accountId: self.me, messageId: "\(self.me):m1")
            XCTAssertNil(try CalendarRSVPStore.current(db, invite: master, accountId: self.me))
            XCTAssertEqual(try CalendarRSVPStore.current(db, invite: instance, accountId: self.me),
                           .tentative)
        }
    }

    /// The organizer moved the meeting (higher SEQUENCE): the old answer is
    /// not shown as the answer to the new time.
    func testAnUpdateAsksAgain() throws {
        let q = try makeDB()
        let first = try invite(ICSCorpus.google)
        let update = try invite(ICSCorpus.googleUpdated)
        try q.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1")
            try CalendarRSVPStore.record(db, status: .accepted, invite: first,
                                         accountId: self.me, messageId: "\(self.me):m1")
            XCTAssertNil(try CalendarRSVPStore.current(db, invite: update, accountId: self.me))
            XCTAssertEqual(try CalendarRSVPStore.current(db, invite: first, accountId: self.me), .accepted)
            try CalendarRSVPStore.record(db, status: .declined, invite: update,
                                         accountId: self.me, messageId: "\(self.me):m1")
            XCTAssertEqual(try CalendarRSVPStore.current(db, invite: update, accountId: self.me), .declined)
        }
    }

    // MARK: - Deleted means gone

    func testDeletingTheMessageDeletesItsAnswer() throws {
        let q = try makeDB()
        let inv = try invite(ICSCorpus.google)
        try q.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1")
            try self.addMessage(db, account: self.me, gmailId: "k1", thread: "kept")
            try CalendarRSVPStore.record(db, status: .accepted, invite: inv,
                                         accountId: self.me, messageId: "\(self.me):m1")
            try CalendarRSVPStore.record(db, status: .accepted, invite: try self.invite(ICSCorpus.apple),
                                         accountId: self.me, messageId: "\(self.me):k1")
            _ = try SyncEngine.deleteLocalMessage(db, messageId: "\(self.me):m1",
                                                  threadId: "\(self.me):t1", accountId: self.me)
            XCTAssertNil(try CalendarRSVPStore.current(db, invite: inv, accountId: self.me))
        }
        XCTAssertEqual(try rowCount(q), 1)
        _ = try q.write { db in try SyncEngine.deleteMessages(db, localIds: ["\(self.me):k1"]) }
        XCTAssertEqual(try rowCount(q), 0, "the sync delete path too")
    }

    func testRemovingTheAccountDeletesOnlyItsAnswers() throws {
        let q = try makeDB()
        let inv = try invite(ICSCorpus.google)
        try q.write { db in
            for account in [self.me, self.other] {
                try self.addMessage(db, account: account, gmailId: "m1")
                try CalendarRSVPStore.record(db, status: .accepted, invite: inv,
                                             accountId: account, messageId: "\(account):m1")
            }
            try AccountLifecycle.purgeAccount(db, id: self.me)
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT accountId FROM calendarRSVP"),
                           [self.other])
        }
    }

    func testLaunchSweepDeletesOrphans() throws {
        let q = try makeDB()
        try q.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1")
            try CalendarRSVPStore.record(db, status: .accepted, invite: try self.invite(ICSCorpus.google),
                                         accountId: self.me, messageId: "\(self.me):m1")
        }
        try q.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM message")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        XCTAssertEqual(try rowCount(q), 1, "fixture: an orphaned row")
        try q.write { db in try AccountLifecycle.purgeOrphanRows(db) }
        XCTAssertEqual(try rowCount(q), 0)
    }

    func testLegacyDefaultsArePurged() throws {
        let suite = "CalendarRSVPStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = CalendarInvite.rsvpDefaultsKey(
            accountId: me, uid: "0a1b2c3d4e5f@google.com",
            recurrenceIdLine: "RECURRENCE-ID:20261214T090000Z")
        defaults.set("ACCEPTED", forKey: legacy)
        defaults.set(30, forKey: "syncWindowDays.\(me)")
        CalendarRSVPStore.purgeLegacyDefaults(defaults)
        XCTAssertNil(defaults.object(forKey: legacy))
        XCTAssertEqual(defaults.integer(forKey: "syncWindowDays.\(me)"), 30)
    }

    func testV59AddsTheTableToAV54Database() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v54")
        try q.read { db in XCTAssertFalse(try db.tableExists("calendarRSVP")) }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertEqual(Set(try db.columns(in: "calendarRSVP").map(\.name)),
                           ["accountId", "uid", "recurrenceId", "messageId", "status", "sequence"])
            XCTAssertEqual(try db.primaryKey("calendarRSVP").columns,
                           ["accountId", "uid", "recurrenceId"])
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(calendarRSVP)")
            let cascades = Set(keys.filter { ($0["on_delete"] as String) == "CASCADE" }
                .map { $0["table"] as String })
            XCTAssertEqual(cascades, ["message", "account"])
        }
    }
}
