import XCTest
import GRDB

/// The Calendar tables (v61): sync writes, the 410 reset, the overlap query,
/// and deletion with the account or when Calendar is disconnected.
final class CalendarStoreTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
    }

    private func entry(_ id: String, primary: Bool = false, selected: Bool? = nil) -> GCalendarListEntry {
        GCalendarListEntry(id: id, summary: "Cal \(id)", timeZone: "Europe/Rome", primary: primary,
                           accessRole: "owner", selected: selected)
    }

    private func event(_ id: String, _ start: String, _ end: String, status: String = "confirmed",
                       uid: String? = nil, summary: String = "Private title") -> GCalendarEvent {
        GCalendarEvent(id: id, status: status, summary: summary, iCalUID: uid,
                       start: GEventDateTime(dateTime: start), end: GEventDateTime(dateTime: end))
    }

    private func eventIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT eventId FROM calendarEvent ORDER BY eventId")
    }

    private func seed(_ db: Database, account: String = "a@x.com") throws {
        try insertAccount(db, account)
        try CalendarStore.saveGrant(db, accountId: account, scopes: CalendarScope.recommended.joined(separator: " "),
                                    at: Date())
        try CalendarStore.replaceCalendars(db, accountId: account, with: [entry("primary", primary: true)])
        try CalendarStore.applySync(db, accountId: account, calendarId: "primary", result: CalendarSyncResult(
            events: [event("e1", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z"),
                     event("e2", "2026-01-06T10:00:00Z", "2026-01-06T11:00:00Z")],
            nextSyncToken: "s1"), isFullSync: true)
    }

    // MARK: - Schema

    func testMigrationCreatesTheCalendarTablesWithCascades() throws {
        let q = try makeDB()
        try q.read { db in
            for table in ["calendarGrant", "calendarSource", "calendarEvent"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
            let eventKeys = try db.foreignKeys(on: "calendarEvent")
            XCTAssertTrue(eventKeys.contains { $0.destinationTable == "account" })
            XCTAssertTrue(eventKeys.contains { $0.destinationTable == "calendarSource"
                && $0.originColumns == ["accountId", "calendarId"] })
            for table in ["calendarGrant", "calendarSource"] {
                XCTAssertTrue(try db.foreignKeys(on: table).contains { $0.destinationTable == "account" }, table)
            }
            let onDelete = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(calendarEvent)")
                .map { $0["on_delete"] as String? }
            XCTAssertEqual(Set(onDelete), ["CASCADE"])
        }
    }

    // MARK: - Sync writes

    func testFullThenIncrementalSync() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db)
            XCTAssertEqual(try self.eventIds(db), ["e1", "e2"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncToken FROM calendarSource"), "s1")

            // Incremental: e1 moved, e2 cancelled, e3 new, an unreadable one dropped.
            try CalendarStore.applySync(db, accountId: "a@x.com", calendarId: "primary", result: CalendarSyncResult(
                events: [event("e1", "2026-01-05T12:00:00Z", "2026-01-05T13:00:00Z"),
                         GCalendarEvent(id: "e2", status: "cancelled", start: nil, end: nil),
                         event("e3", "2026-01-07T10:00:00Z", "2026-01-07T11:00:00Z"),
                         GCalendarEvent(id: "bad", start: nil, end: nil)],
                nextSyncToken: "s2"), isFullSync: false)
            XCTAssertEqual(try self.eventIds(db), ["e1", "e3"])
            let moved = try XCTUnwrap(try CalendarEventRecord.fetchOne(
                db, key: ["accountId": "a@x.com", "calendarId": "primary", "eventId": "e1"]))
            XCTAssertEqual(moved.startAt, CalendarClient.parseDateTime("2026-01-05T12:00:00Z"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncToken FROM calendarSource"), "s2")

            // A new full sync replaces everything.
            try CalendarStore.applySync(db, accountId: "a@x.com", calendarId: "primary", result: CalendarSyncResult(
                events: [event("e9", "2026-01-08T10:00:00Z", "2026-01-08T11:00:00Z")],
                nextSyncToken: "s3"), isFullSync: true)
            XCTAssertEqual(try self.eventIds(db), ["e9"])
        }
    }

    func testExpiredSyncTokenDropsTheCalendarsEventsAndToken() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db)
            try CalendarStore.resetSync(db, accountId: "a@x.com", calendarId: "primary")
            XCTAssertEqual(try self.eventIds(db), [])
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT syncToken FROM calendarSource"))
        }
    }

    func testCalendarListMirrorKeepsSelectionAndTokenAndDropsRemovedCalendars() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db)
            try CalendarStore.replaceCalendars(db, accountId: "a@x.com",
                                               with: [entry("other", selected: true), entry("hidden")])
            XCTAssertEqual(try self.eventIds(db), [], "a calendar no longer listed takes its events")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT calendarId FROM calendarSource ORDER BY calendarId"),
                           ["hidden", "other"])
            XCTAssertEqual(try Bool.fetchAll(db, sql: "SELECT isSelected FROM calendarSource ORDER BY calendarId"),
                           [false, true], "defaults follow Google Calendar's own list")

            try db.execute(sql: "UPDATE calendarSource SET isSelected = 1, syncToken = 'keep' WHERE calendarId = 'hidden'")
            try CalendarStore.replaceCalendars(db, accountId: "a@x.com",
                                               with: [entry("other", selected: true), entry("hidden")])
            let hidden = try Row.fetchOne(db, sql: "SELECT isSelected, syncToken FROM calendarSource WHERE calendarId = 'hidden'")
            XCTAssertEqual(hidden?["isSelected"] as Bool?, true)
            XCTAssertEqual(hidden?["syncToken"] as String?, "keep")
        }
    }

    func testSyncForAnUnknownCalendarWritesNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try CalendarStore.applySync(db, accountId: "a@x.com", calendarId: "nope", result: CalendarSyncResult(
                events: [event("e1", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z")]), isFullSync: true)
            XCTAssertEqual(try self.eventIds(db), [])
        }
    }

    // MARK: - Overlap query

    func testBusyQueryUsesSelectedCalendarsAndTheSameExclusions() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try CalendarStore.replaceCalendars(db, accountId: "a@x.com",
                                               with: [entry("primary", primary: true), entry("muted", selected: false)])
            try CalendarStore.applySync(db, accountId: "a@x.com", calendarId: "primary", result: CalendarSyncResult(
                events: [event("in", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z"),
                         event("itself", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", uid: "uid-1"),
                         event("before", "2026-01-04T10:00:00Z", "2026-01-04T11:00:00Z"),
                         GCalendarEvent(id: "free", start: GEventDateTime(dateTime: "2026-01-05T10:00:00Z"),
                                        end: GEventDateTime(dateTime: "2026-01-05T11:00:00Z"),
                                        transparency: "transparent"),
                         GCalendarEvent(id: "declined", start: GEventDateTime(dateTime: "2026-01-05T10:00:00Z"),
                                        end: GEventDateTime(dateTime: "2026-01-05T11:00:00Z"),
                                        attendees: [GEventAttendee(email: "a@x.com", isSelf: true,
                                                                   responseStatus: "declined")])]),
                isFullSync: true)
            try CalendarStore.applySync(db, accountId: "a@x.com", calendarId: "muted", result: CalendarSyncResult(
                events: [event("muted", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z")]), isFullSync: true)

            let window = DateInterval(start: CalendarClient.parseDateTime("2026-01-05T00:00:00Z")!, duration: 86_400)
            let busy = try CalendarStore.busy(db, accountId: "a@x.com", overlapping: window, excludingUID: "uid-1")
            XCTAssertEqual(busy.map(\.source), [.event(calendarId: "primary", eventId: "in", summary: "Private title")])
            let invite = CalendarSpan(start: CalendarClient.parseDateTime("2026-01-05T10:30:00Z")!,
                                      end: CalendarClient.parseDateTime("2026-01-05T11:30:00Z")!, isAllDay: false)
            XCTAssertEqual(CalendarAvailability.check(invite: invite, against: busy).conflicts.count, 1)
        }
    }

    // MARK: - Deletion (DEC-019)

    func testAccountRemovalDeletesOnlyThatAccountsCalendarData() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "a@x.com")
            try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            for table in ["calendarGrant", "calendarSource", "calendarEvent"] {
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT accountId FROM \(table)"),
                               ["b@x.com"], table)
            }
        }
    }

    func testDisconnectingCalendarDeletesGrantCalendarsAndEventsButNotMail() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db)
            XCTAssertEqual(try CalendarStore.grant(db, accountId: "a@x.com")?.canRespond, true)
            try CalendarStore.forget(db, accountId: "a@x.com")
            XCTAssertNil(try CalendarStore.grant(db, accountId: "a@x.com"))
            for table in ["calendarGrant", "calendarSource", "calendarEvent"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0, table)
            }
            XCTAssertEqual(try Account.fetchCount(db), 1)
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
