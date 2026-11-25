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
}
