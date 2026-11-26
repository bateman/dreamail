import XCTest

/// The sync control and Settings → Accounts must say when the last pass
/// failed, keep "last synced" at the last pass that completed, and keep the
/// relative time moving (a label drawn once read "now" for hours).
final class SyncHealthTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "you@example.com"

    func testFailureMarksTheAccountUntilTheNextSuccess() {
        var health = SyncHealth()
        XCTAssertFalse(health.failed(account: account, needsReauth: false))
        health.recordFailure(account: account)
        XCTAssertTrue(health.failed(account: account, needsReauth: false))
        XCTAssertTrue(health.anyFailed(accounts: [account], needingReauth: []))
        health.recordSuccess(account: account)
        XCTAssertFalse(health.failed(account: account, needsReauth: false))
    }

    func testRefusedSignInCountsAsFailed() {
        let health = SyncHealth()
        XCTAssertTrue(health.failed(account: account, needsReauth: true))
        XCTAssertTrue(health.anyFailed(accounts: [account], needingReauth: [account]))
    }

    func testARemovedAccountNoLongerCounts() {
        var health = SyncHealth()
        health.recordFailure(account: account)
        XCTAssertFalse(health.anyFailed(accounts: ["other@example.com"], needingReauth: []))
        XCTAssertEqual(health.failing(accounts: ["other@example.com", account], needingReauth: []),
                       [account])
        health.forget(account: account)
        XCTAssertEqual(health, SyncHealth())
    }

    func testToolbarSaysWhenTheLastCompletedPassWas() {
        let threeHoursAgo = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(SyncHealth.toolbarText(lastSuccess: threeHoursAgo, failed: false,
                                              now: now, locale: en), "3 hours ago")
        XCTAssertEqual(SyncHealth.toolbarText(lastSuccess: threeHoursAgo, failed: true,
                                              now: now, locale: en),
                       "Sync failed · last synced 3 hours ago")
        XCTAssertEqual(SyncHealth.toolbarText(lastSuccess: nil, failed: true,
                                              now: now, locale: en), "Sync failed")
        XCTAssertNil(SyncHealth.toolbarText(lastSuccess: nil, failed: false, now: now, locale: en))
    }

    /// The same stamp reads differently as time passes: the label is a
    /// function of the clock, not drawn once.
    func testRelativeTimeMovesWithTheClock() {
        let stamp = now
        XCTAssertEqual(SyncHealth.relative(stamp, now: now, locale: en), "now")
        XCTAssertEqual(SyncHealth.relative(stamp, now: now.addingTimeInterval(3 * 3600), locale: en),
                       "3 hours ago")
        // A clock set back never reads as "in 5 minutes".
        XCTAssertEqual(SyncHealth.relative(now.addingTimeInterval(300), now: now, locale: en), "now")
    }

    func testSettingsLineNamesTheLastSuccessfulSync() {
        let oneHourAgo = now.addingTimeInterval(-3600)
        XCTAssertEqual(SyncHealth.settingsText(lastSuccess: oneHourAgo, failed: false,
                                               now: now, locale: en), "Last sync 1 hour ago")
        XCTAssertEqual(SyncHealth.settingsText(lastSuccess: oneHourAgo, failed: true,
                                               now: now, locale: en),
                       "Last sync failed · last successful sync 1 hour ago")
        XCTAssertEqual(SyncHealth.settingsText(lastSuccess: nil, failed: true,
                                               now: now, locale: en), "Last sync failed")
    }
}
