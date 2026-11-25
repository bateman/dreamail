import GRDB
import XCTest

/// "Show sender and subject in notifications" is a setting of each account
/// (`Account.notificationDetails`, migration v64). Existing accounts take the
/// app-wide value of earlier builds once; a new account starts off
/// (DEC-014); the setting goes with the account row (DEC-019).
final class AccountNotificationDetailsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "AccountNotificationDetailsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    /// A database at v61 with two accounts, as an earlier build left it.
    private func legacyDatabase() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator(defaults: defaults).migrate(q, upTo: "v61")
        try q.write { db in
            XCTAssertFalse(try db.columns(in: "account").map(\.name)
                .contains("notificationDetails"))
            try db.execute(sql: """
                INSERT INTO account (id, displayName, senderName)
                VALUES ('w@x.com', 'Work', ''), ('h@x.com', 'Home', '')
                """)
        }
        return q
    }

    private func flags(_ q: DatabaseQueue) throws -> [String: Bool] {
        try q.read { db in
            Dictionary(uniqueKeysWithValues: try Account.fetchAll(db)
                .map { ($0.id, $0.notificationDetails) })
        }
    }

    func testExistingAccountsTakeTheAppWideChoiceWhenItWasOn() throws {
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        let q = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(q)
        XCTAssertEqual(try flags(q), ["w@x.com": true, "h@x.com": true])
    }

    func testExistingAccountsStayGenericWhenTheChoiceWasOffOrNeverMade() throws {
        let never = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(never)
        XCTAssertEqual(try flags(never), ["w@x.com": false, "h@x.com": false])

        defaults.set(false, forKey: NotificationContent.legacyShowDetailsKey)
        let off = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(off)
        XCTAssertEqual(try flags(off), ["w@x.com": false, "h@x.com": false])
    }

    /// The copy happens once: a later change of an account, or a later
    /// account, is not overwritten by the old app-wide value.
    func testTheCopyRunsOnceAndANewAccountStartsOff() throws {
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        let q = try legacyDatabase()
        let migrator = AppDatabase.migrator(defaults: defaults)
        try migrator.migrate(q)
        try q.write { db in
            try db.execute(sql: "UPDATE account SET notificationDetails = 0 WHERE id = 'h@x.com'")
            try AccountLifecycle.accountAfterSignIn(email: "n@x.com", name: "New", existing: nil)
                .insert(db)
        }
        try migrator.migrate(q)
        XCTAssertEqual(try flags(q), ["w@x.com": true, "h@x.com": false, "n@x.com": false])
    }

    /// The old key stays: another database of the same install (demo,
    /// UI tests) migrating first must not take the choice away from the
    /// real one.
    func testTheAppWideKeyIsLeftForTheOtherDatabases() throws {
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        let demo = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(demo)
        let real = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(real)
        XCTAssertEqual(try flags(real), ["w@x.com": true, "h@x.com": true])
    }

    /// DEC-019: the setting is a column of the account row, so removing the
    /// account leaves nothing of it behind.
    func testTheSettingGoesWithTheAccount() throws {
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        let q = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(q)
        try q.write { db in _ = try Account.deleteOne(db, key: "w@x.com") }
        XCTAssertEqual(try flags(q), ["h@x.com": true])
    }

    // MARK: - The decision is read from the database (R1)

    private func migrated() throws -> DatabaseQueue {
        let q = try legacyDatabase()
        try AppDatabase.migrator(defaults: defaults).migrate(q)
        return q
    }

    func testDetailAccountsAreReadFromTheAccountRows() throws {
        let q = try migrated()
        try q.read { db in XCTAssertEqual(NotificationContent.detailAccounts(db), []) }
        XCTAssertEqual(try setDetails(q, "w@x.com", true), [])
        try q.read { db in XCTAssertEqual(NotificationContent.detailAccounts(db), ["w@x.com"]) }
    }

    /// A read that fails decides "generic", never "detailed".
    func testAFailedReadGivesGenericNotifications() throws {
        let q = try legacyDatabase()   // no notificationDetails column yet
        try q.read { db in XCTAssertEqual(NotificationContent.detailAccounts(db), []) }
    }

    /// An off-main account reload that started before a change and ends
    /// after it is dropped, so the published toggle does not jump back.
    func testAnOlderAccountReloadNeverReplacesANewerOne() {
        var reloads = LatestOnly()
        let offMain = reloads.begin()      // post-sync reload, read pending
        _ = reloads.begin()                // the toggle's own reload
        XCTAssertFalse(reloads.isCurrent(offMain))
        let next = reloads.begin()
        XCTAssertTrue(reloads.isCurrent(next))
    }

    // MARK: - Turning it off withdraws delivered notifications (R2)

    private func setDetails(_ q: DatabaseQueue, _ id: String, _ on: Bool) throws -> [String] {
        try q.write { db -> [String] in
            var withdrawn: [String] = []
            try NotificationContent.setDetails(db, accountId: id, on: on) { withdrawn.append($0) }
            return withdrawn
        }
    }

    func testTurningOffWithdrawsTheAccountsNotifications() throws {
        let q = try migrated()
        XCTAssertEqual(try setDetails(q, "w@x.com", true), [], "turning it on removes nothing")
        XCTAssertEqual(try flags(q), ["w@x.com": true, "h@x.com": false])
        XCTAssertEqual(try setDetails(q, "w@x.com", false), ["w@x.com"])
        XCTAssertEqual(try flags(q), ["w@x.com": false, "h@x.com": false])
    }

    // MARK: - The old switch is retired by the real mailbox only (S3)

    func testOnlyAMigratedRealMailboxRetiresTheOldSwitch() {
        XCTAssertTrue(NotificationContent.retiresLegacySwitch(isRealMailbox: true, migrated: true))
        XCTAssertFalse(NotificationContent.retiresLegacySwitch(isRealMailbox: true, migrated: false),
                       "a read-only plaintext cache has not run v64 yet")
        XCTAssertFalse(NotificationContent.retiresLegacySwitch(isRealMailbox: false, migrated: true),
                       "demo and UI-test databases leave it for the real one")
    }

    /// Once retired, a restored older database migrates to generic: the
    /// frozen old value cannot turn its accounts back on.
    func testARestoredOlderDatabaseAfterRetirementStaysGeneric() throws {
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        let real = try migrated()
        XCTAssertEqual(try flags(real), ["w@x.com": true, "h@x.com": true])
        NotificationContent.retireLegacySwitch(defaults)
        let restored = try migrated()
        XCTAssertEqual(try flags(restored), ["w@x.com": false, "h@x.com": false])
    }

    // MARK: - Which account the filters pane shows (R4)

    func testFiltersPaneAccount() {
        let ids = ["a@x.com", "b@x.com"]
        XCTAssertEqual(FiltersPaneAccount.shown(chosen: "b@x.com", active: "a@x.com",
                                                accounts: ids), "b@x.com")
        XCTAssertEqual(FiltersPaneAccount.shown(chosen: "gone@x.com", active: nil,
                                                accounts: ids), "a@x.com",
                       "a removed account falls back to the first")
        XCTAssertEqual(FiltersPaneAccount.shown(chosen: nil, active: "b@x.com",
                                                accounts: ids), "b@x.com",
                       "nothing chosen: the account open in the main window")
        XCTAssertEqual(FiltersPaneAccount.shown(chosen: nil, active: nil, accounts: ids),
                       "a@x.com", "unified inbox: the first")
        XCTAssertEqual(FiltersPaneAccount.shown(chosen: "gone@x.com", active: "gone@x.com",
                                                accounts: ids), "a@x.com")
        XCTAssertNil(FiltersPaneAccount.shown(chosen: nil, active: nil, accounts: []))
    }
}
