import XCTest
import GRDB

/// Messages a history catch-up could not download are kept and retried,
/// so one that still exists in Gmail is not lost for good.
final class MissingMessagesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAMissedIdIsRetriedAfterItsWaitAndDoneOnceStored() {
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: false, now: t0)
        XCTAssertEqual(m.due(now: t0.addingTimeInterval(30)), [], "waits before the first retry")
        XCTAssertEqual(m.due(now: t0.addingTimeInterval(60)), ["a"])
        m.resolve(stored: ["a"], notFound: [], failed: [], now: t0.addingTimeInterval(60))
        XCTAssertTrue(m.isEmpty)
    }

    func testTheWaitGrowsAndIsCapped() {
        XCTAssertEqual(MissingMessages.backoff(attempts: 1), 60)
        XCTAssertEqual(MissingMessages.backoff(attempts: 2), 120)
        XCTAssertEqual(MissingMessages.backoff(attempts: 3), 240)
        XCTAssertEqual(MissingMessages.backoff(attempts: 50), MissingMessages.maxBackoff)
    }

    /// The reported lead: a 404 is not final at once. Only a second 404 at
    /// least ten minutes after the first drops the id.
    func testA404IsFinalOnlyWhenItRepeatsAfterTheGrace() {
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: true, now: t0)
        m.resolve(stored: [], notFound: ["a"], failed: [], now: t0.addingTimeInterval(60))
        XCTAssertEqual(m.count, 1, "a second 404 within the grace keeps it")
        m.resolve(stored: [], notFound: ["a"], failed: [], now: t0.addingTimeInterval(11 * 60))
        XCTAssertTrue(m.isEmpty)
    }

    /// A message that answered 404 once and is there a moment later is stored.
    func testA404ThenFoundIsStored() {
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: true, now: t0)
        m.resolve(stored: ["a"], notFound: [], failed: [], now: t0.addingTimeInterval(60))
        XCTAssertTrue(m.isEmpty)
    }

    /// Other failures are never dropped: they wait longer and longer.
    func testOtherFailuresStayUntilTheySucceed() {
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: false, now: t0)
        var now = t0
        for _ in 0..<12 {
            now = now.addingTimeInterval(MissingMessages.maxBackoff)
            m.resolve(stored: [], notFound: [], failed: ["a"], now: now)
        }
        XCTAssertEqual(m.count, 1)
        // A 404 after a non-404 failure starts the grace check, not a drop.
        m.resolve(stored: [], notFound: ["a"], failed: [], now: now)
        XCTAssertEqual(m.count, 1)
    }

    func testDueIsOldestFirstAndBounded() {
        var m = MissingMessages()
        for i in 0..<(MissingMessages.retryBatch + 5) {
            m.noteMissed(["id\(i)"], notFound: false, now: t0.addingTimeInterval(Double(i)))
        }
        let due = m.due(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(due.count, MissingMessages.retryBatch)
        XCTAssertEqual(due.first, "id0")
    }

    func testTheListIsBounded() {
        var m = MissingMessages()
        for i in 0..<(MissingMessages.maxEntries + 3) {
            m.noteMissed(["id\(i)"], notFound: false, now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(m.count, MissingMessages.maxEntries)
        XCTAssertNil(m.entries["id0"], "the oldest give way")
    }

    func testStoredPerAccountAndRemovedWithIt() throws {
        let suite = "missing-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: false, now: t0)
        m.save(accountId: "you@example.com", defaults: d)
        XCTAssertEqual(MissingMessages.load(accountId: "you@example.com", defaults: d), m)
        XCTAssertTrue(MissingMessages.load(accountId: "other@example.com", defaults: d).isEmpty)
        XCTAssertTrue(AccountLifecycle.accountDefaultsKeys(accountId: "you@example.com", in: d)
                        .contains(MissingMessages.defaultsKey(accountId: "you@example.com")))
        MissingMessages().save(accountId: "you@example.com", defaults: d)
        XCTAssertNil(d.object(forKey: MissingMessages.defaultsKey(accountId: "you@example.com")))
    }

    func testStatusSaysHowManyCouldNotBeDownloaded() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(SyncHealth.toolbarText(lastSuccess: t0, failed: false, undownloaded: 2,
                                              now: t0, locale: en),
                       "now · 2 messages could not be downloaded")
        XCTAssertEqual(SyncHealth.settingsText(lastSuccess: t0, failed: false, undownloaded: 1,
                                               now: t0, locale: en),
                       "Last sync now · 1 message could not be downloaded")
        XCTAssertEqual(SyncHealth.toolbarText(lastSuccess: t0, failed: false, undownloaded: 0,
                                              now: t0, locale: en), "now")
        var health = SyncHealth()
        XCTAssertTrue(health.setUndownloaded(account: "a", count: 2))
        XCTAssertFalse(health.setUndownloaded(account: "a", count: 2), "no change, no republish")
        XCTAssertEqual(health.undownloadedCount(accounts: ["a", "b"]), 2)
        health.forget(account: "a")
        XCTAssertEqual(health, SyncHealth())
    }
}

/// Q6: normal deletions are not shown as failures, and nothing stays for ever.
final class MissingMessagesCountTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testA404IsNotCountedAsUndownloaded() {
        var m = MissingMessages()
        m.noteMissed(["deleted"], notFound: true, now: t0)
        m.noteMissed(["refused"], notFound: false, now: t0)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.undownloadedCount, 1)
    }

    func testMessagesGmailReportsDeletedAreForgotten() {
        var m = MissingMessages()
        m.noteMissed(["a", "b"], notFound: false, now: t0)
        m.forget(Set(["a"]))
        XCTAssertEqual(Array(m.entries.keys), ["b"])
    }

    func testFailuresEndAfterThirtyDays() {
        var m = MissingMessages()
        m.noteMissed(["a"], notFound: false, now: t0)
        let later = t0.addingTimeInterval(MissingMessages.maxAge + 1)
        XCTAssertEqual(m.due(now: later), [])
        m.resolve(stored: [], notFound: [], failed: [], now: later)
        XCTAssertTrue(m.isEmpty)
    }
}

/// Q7d: the retry stores a message the catch-up missed and re-derives its
/// conversation, so the row shows the newest date (the owner's symptom:
/// a conversation listed with an older time than in Gmail).
final class MissingMessagesRetryTests: XCTestCase {
    private let account = "you@example.com"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func gmessage(_ id: String, at date: Date) throws -> GMessage {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        let json = """
            {"id":"\(id)","threadId":"t1","labelIds":["INBOX","UNREAD"],
             "snippet":"snippet-\(id)","internalDate":"\(millis)",
             "payload":{"mimeType":"text/plain",
               "headers":[{"name":"From","value":"Ann <ann@example.com>"},
                          {"name":"Subject","value":"Plans"},
                          {"name":"Message-ID","value":"<\(id)@example.com>"}],
               "body":{"data":"aGVsbG8","size":5}}}
            """
        return try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
    }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let old = Message(
            id: "\(account):m1", accountId: account, gmailId: "m1", threadId: "\(account):t1",
            fromHeader: "Ann <ann@example.com>", toHeader: account, ccHeader: "", bccHeader: "",
            subject: "Plans", date: now.addingTimeInterval(-3600), snippet: "snippet-m1",
            bodyText: "", bodyHTML: nil, messageIdHeader: "<m1@example.com>",
            referencesHeader: "", labelIds: "INBOX", isUnread: false, hasAttachment: false)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try old.insert(db)
            try SyncEngine.deriveThreads(db, for: ["\(self.account):t1"], accountId: self.account)
        }
        return q
    }

    func testARetriedMessageIsStoredAndItsConversationShowsItsDate() async throws {
        let q = try makeDB()
        var missing = MissingMessages()
        missing.noteMissed(["m2"], notFound: false, now: now.addingTimeInterval(-120))
        let newest = try gmessage("m2", at: now.addingTimeInterval(-60))
        let result = try await SyncEngine.retryMissingMessages(
            missing, accountId: account, db: q, now: now) { ids in
                XCTAssertEqual(ids, ["m2"])
                return MessageFetchReport(messages: [newest])
            }
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.touched, ["\(account):t1"])
        let thread = try await q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        let row = try XCTUnwrap(thread)
        XCTAssertEqual(row.messageCount, 2)
        XCTAssertEqual(row.lastDate.timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(row.snippet, "snippet-m2")
        XCTAssertTrue(row.isUnread)
    }

    func testANotFoundWithinTheGraceIsKeptAndNothingIsWritten() async throws {
        let q = try makeDB()
        var missing = MissingMessages()
        missing.noteMissed(["m2"], notFound: true, now: now.addingTimeInterval(-120))
        let result = try await SyncEngine.retryMissingMessages(
            missing, accountId: account, db: q, now: now) { _ in
                MessageFetchReport(notFoundIds: ["m2"])
            }
        XCTAssertEqual(result.missing.count, 1)
        XCTAssertEqual(result.touched, [])
        XCTAssertEqual(result.missing.undownloadedCount, 0, "a 404 is not shown as a failure")
    }

    func testAnIdAlreadyStoredIsDoneWithoutADownload() async throws {
        let q = try makeDB()
        var missing = MissingMessages()
        missing.noteMissed(["m1"], notFound: false, now: now.addingTimeInterval(-120))
        let result = try await SyncEngine.retryMissingMessages(
            missing, accountId: account, db: q, now: now) { _ in
                XCTFail("nothing to download")
                return MessageFetchReport()
            }
        XCTAssertTrue(result.missing.isEmpty)
    }
}
