import XCTest

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
