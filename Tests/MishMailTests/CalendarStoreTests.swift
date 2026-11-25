import XCTest
import GRDB

/// The Calendar tables (v61): the grant, the chosen calendars (primary by
/// default) and each invitation's event, deleted with the account, the
/// message (and so its thread) or when Calendar is disconnected.
final class CalendarStoreTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
    }

    private func insertMessage(_ db: Database, account: String, gmailId: String) throws -> String {
        let id = "\(account):\(gmailId)"
        try Message(
            id: id, accountId: account, gmailId: gmailId, threadId: "\(account):t-\(gmailId)",
            fromHeader: "", toHeader: "", ccHeader: "", bccHeader: "", subject: "Invitation",
            date: Date(), snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: "", isUnread: false, hasAttachment: true).save(db)
        return id
    }

    private func entry(_ id: String, primary: Bool = false, role: String = "owner") -> GCalendarListEntry {
        GCalendarListEntry(id: id, summary: "Cal \(id)", timeZone: "Europe/Rome", primary: primary,
                           accessRole: role, selected: true)
    }

    private func inviteEvent(_ messageId: String, account: String) -> CalendarInviteEventRecord {
        CalendarInviteEventRecord(messageId: messageId, accountId: account, calendarId: "primary",
                                  eventId: "ev1", iCalUID: "uid-1", selfResponse: "needsAction",
                                  checkedAt: Date())
    }

    private let scopes = CalendarScope.recommended.joined(separator: " ")

    private func seed(_ db: Database, account: String) throws -> String {
        try insertAccount(db, account)
        try CalendarStore.saveGrant(db, accountId: account, scopes: scopes, at: Date(),
                                    calendars: [entry(account, primary: true), entry("team@group")])
        let message = try insertMessage(db, account: account, gmailId: "m1")
        try CalendarStore.saveInviteEvent(db, inviteEvent(message, account: account))
        return message
    }

    private func count(_ db: Database, _ table: String, account: String? = nil) throws -> Int {
        if let account {
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE accountId = ?",
                                    arguments: [account]) ?? -1
        }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }

    // MARK: - Schema

    func testMigrationCreatesTheCalendarTablesWithCascades() throws {
        let q = try makeDB()
        try q.read { db in
            for table in ["calendarGrant", "calendarSource", "calendarInviteEvent"] {
                XCTAssertTrue(try db.tableExists(table), table)
                let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
                XCTAssertTrue(keys.contains { $0["table"] as String? == "account" }, table)
                XCTAssertEqual(Set(keys.map { $0["on_delete"] as String? }), ["CASCADE"], table)
            }
            let inviteKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(calendarInviteEvent)")
            XCTAssertTrue(inviteKeys.contains { $0["table"] as String? == "message" })
            XCTAssertFalse(try db.tableExists("calendarEvent"), "no agenda events are stored")
        }
    }

    // MARK: - Chosen calendars

    func testFirstGrantChoosesOnlyThePrimaryCalendar() throws {
        let q = try makeDB()
        try q.write { db in
            _ = try self.seed(db, account: "a@x.com")
            XCTAssertEqual(try CalendarStore.chosenCalendars(db, accountId: "a@x.com").map(\.calendarId),
                           ["a@x.com"])
            // A later grant (reconnected) keeps the user's choice.
            try CalendarStore.setChosenCalendars(db, accountId: "a@x.com", [self.entry("team@group")])
            try CalendarStore.saveGrant(db, accountId: "a@x.com", scopes: self.scopes, at: Date(),
                                        calendars: [self.entry("a@x.com", primary: true)])
            XCTAssertEqual(try CalendarStore.chosenCalendars(db, accountId: "a@x.com").map(\.calendarId),
                           ["team@group"])
        }
    }

    func testWithoutAListThePrimaryAliasIsChosen() {
        XCTAssertEqual(CalendarStore.defaultChoice(from: []).map(\.id), ["primary"])
        XCTAssertEqual(CalendarStore.defaultChoice(from: [entry("x"), entry("me", primary: true)]).map(\.id), ["me"])
    }

    func testAnyVisibleCalendarCanBeChosenAndFreeBusyOnlyOnesAreMarked() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try CalendarStore.setChosenCalendars(db, accountId: "a@x.com", [
                self.entry("a@x.com", primary: true),
                self.entry("holidays#group", role: "reader"),
                self.entry("boss@y.com", role: "freeBusyReader"),
            ])
            let chosen = try CalendarStore.chosenCalendars(db, accountId: "a@x.com")
            XCTAssertEqual(chosen.map(\.calendarId), ["a@x.com", "boss@y.com", "holidays#group"],
                           "primary first")
            XCTAssertEqual(chosen.map(\.canReadEvents), [true, false, true])
        }
    }

    func testReconcileDropsUnlistedCalendarsAndRefreshesTheOthers() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try CalendarStore.setChosenCalendars(db, accountId: "a@x.com", [
                self.entry("primary", primary: true), self.entry("gone"), self.entry("kept")])
            try CalendarStore.reconcileChosenCalendars(db, accountId: "a@x.com", with: [
                GCalendarListEntry(id: "kept", summary: "Renamed", timeZone: "UTC", primary: false,
                                   accessRole: "reader", selected: true)])
            let chosen = try CalendarStore.chosenCalendars(db, accountId: "a@x.com")
            XCTAssertEqual(chosen.map(\.calendarId), ["primary", "kept"], "the alias stays")
            XCTAssertEqual(chosen.last?.summary, "Renamed")
            XCTAssertEqual(chosen.last?.accessRole, "reader")
        }
    }

    // MARK: - Deletion (DEC-019)

    func testAccountRemovalDeletesOnlyThatAccountsCalendarData() throws {
        let q = try makeDB()
        try q.write { db in
            _ = try self.seed(db, account: "a@x.com")
            _ = try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            for table in ["calendarGrant", "calendarSource", "calendarInviteEvent"] {
                XCTAssertEqual(try self.count(db, table, account: "a@x.com"), 0, table)
                XCTAssertGreaterThan(try self.count(db, table, account: "b@x.com"), 0, table)
            }
        }
    }

    func testDeletingTheMessageDeletesItsInvitationEvent() throws {
        let q = try makeDB()
        try q.write { db in
            let message = try self.seed(db, account: "a@x.com")
            XCTAssertNotNil(try CalendarStore.inviteEvent(db, messageId: message))
            _ = try Message.deleteOne(db, key: message)
            XCTAssertNil(try CalendarStore.inviteEvent(db, messageId: message))
            XCTAssertEqual(try self.count(db, "calendarGrant"), 1, "the grant is the account's")
        }
    }

    func testDisconnectingCalendarDeletesEverythingCalendarButNotMail() throws {
        let q = try makeDB()
        try q.write { db in
            _ = try self.seed(db, account: "a@x.com")
            XCTAssertEqual(try CalendarStore.grant(db, accountId: "a@x.com")?.canWriteEvents, true)
            try CalendarStore.forget(db, accountId: "a@x.com")
            XCTAssertNil(try CalendarStore.grant(db, accountId: "a@x.com"))
            for table in ["calendarGrant", "calendarSource", "calendarInviteEvent"] {
                XCTAssertEqual(try self.count(db, table), 0, table)
            }
            XCTAssertEqual(try Message.fetchCount(db), 1)
        }
    }

    func testRemovalDeletesTheCalendarTokenToo() throws {
        let source = try ForkIdentityTests.repoFile("Sources/MishMail/App/MailStore+Accounts.swift")
        let body = try XCTUnwrap(source.range(of: "private static func removeOutsideDatabase(accountId id: String)"))
        let rest = source[body.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"))
        let function = rest[..<end.lowerBound]
        XCTAssertTrue(function.contains("Keychain.delete(\"refreshToken.\\(id)\")"))
        XCTAssertTrue(function.contains("Keychain.delete(CalendarAuthorization.keychainKey(accountId: id))"))
        XCTAssertEqual(CalendarAuthorization.keychainKey(accountId: "a@x.com"), "calendarRefreshToken.a@x.com")
    }
}
