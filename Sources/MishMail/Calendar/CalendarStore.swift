import Foundation
import GRDB

/// One account's Calendar grant: which scopes Google granted. The refresh
/// token itself is in the Keychain (`CalendarAuthorization.keychainKey`).
struct CalendarGrantRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarGrant"
    var accountId: String
    /// Space-separated, as the token response sent them.
    var scopes: String
    var grantedAt: Date

    var grant: CalendarGrant { CalendarGrant(grantedScopeField: scopes) }
}

/// A calendar of the account's Google calendar list.
struct CalendarSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarSource"
    var accountId: String
    var calendarId: String
    var summary: String?
    var timeZone: String?
    var isPrimary: Bool
    var accessRole: String?
    /// Whether its events count for availability. Defaults to what Google
    /// Calendar shows; which calendars count is a pending design decision.
    var isSelected: Bool
    /// Where the next incremental sync starts; nil = full sync next.
    var syncToken: String?
}

/// One event instance (recurrences expanded by Google). Only what the
/// availability check and the invitation card need.
struct CalendarEventRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarEvent"
    var accountId: String
    var calendarId: String
    var eventId: String
    var iCalUID: String?
    var summary: String?
    var status: String?
    var transparency: String?
    var selfResponse: String?
    var startAt: Date
    var endAt: Date
    var isAllDay: Bool

    init(accountId: String, calendarId: String, event: GCalendarEvent, span: CalendarSpan) {
        self.accountId = accountId
        self.calendarId = calendarId
        self.eventId = event.id
        self.iCalUID = event.iCalUID
        self.summary = event.summary
        self.status = event.status
        self.transparency = event.transparency
        self.selfResponse = event.selfResponse
        self.startAt = span.start
        self.endAt = span.end
        self.isAllDay = span.isAllDay
    }

    var busy: CalendarBusy {
        CalendarBusy(span: CalendarSpan(start: startAt, end: endAt, isAllDay: isAllDay),
                     source: .event(calendarId: calendarId, eventId: eventId, summary: summary))
    }
}

/// The Calendar tables (migration v61) and their writes. Everything
/// cascades from `account`, and events from their calendar, so removing an
/// account or withdrawing Calendar leaves nothing behind; the database's
/// `secure_delete` and WAL scrub (`DeletionObserver`) then overwrite the
/// deleted rows (DEC-019). Nothing here talks to Google.
enum CalendarStore {
    static func createTables(_ db: Database) throws {
        try db.create(table: CalendarGrantRecord.databaseTableName) { t in
            t.primaryKey("accountId", .text)
                .references("account", onDelete: .cascade)
            t.column("scopes", .text).notNull()
            t.column("grantedAt", .datetime).notNull()
        }
        try db.create(table: CalendarSourceRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("calendarId", .text).notNull()
            t.column("summary", .text)
            t.column("timeZone", .text)
            t.column("isPrimary", .boolean).notNull().defaults(to: false)
            t.column("accessRole", .text)
            t.column("isSelected", .boolean).notNull().defaults(to: true)
            t.column("syncToken", .text)
            t.primaryKey(["accountId", "calendarId"])
        }
        try db.create(table: CalendarEventRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("calendarId", .text).notNull()
            t.column("eventId", .text).notNull()
            t.column("iCalUID", .text)
            t.column("summary", .text)
            t.column("status", .text)
            t.column("transparency", .text)
            t.column("selfResponse", .text)
            t.column("startAt", .datetime).notNull()
            t.column("endAt", .datetime).notNull()
            t.column("isAllDay", .boolean).notNull().defaults(to: false)
            t.primaryKey(["accountId", "calendarId", "eventId"])
            t.foreignKey(["accountId", "calendarId"], references: CalendarSourceRecord.databaseTableName,
                         onDelete: .cascade)
        }
        // The overlap query: one account, events ending after a start.
        try db.create(index: "calendarEvent_on_accountId_endAt",
                      on: CalendarEventRecord.databaseTableName, columns: ["accountId", "endAt"])
        try db.create(index: "calendarEvent_on_accountId_iCalUID",
                      on: CalendarEventRecord.databaseTableName, columns: ["accountId", "iCalUID"])
    }

    // MARK: Grant

    static func saveGrant(_ db: Database, accountId: String, scopes: String, at date: Date) throws {
        try CalendarGrantRecord(accountId: accountId, scopes: scopes, grantedAt: date).save(db)
    }

    static func grant(_ db: Database, accountId: String) throws -> CalendarGrant? {
        try CalendarGrantRecord.fetchOne(db, key: accountId)?.grant
    }

    /// The user withdrew Calendar (or Google refused the grant): the grant,
    /// the calendars and every stored event of the account go. The caller
    /// deletes the Keychain token (`CalendarAuthorization.keychainKey`).
    static func forget(_ db: Database, accountId: String) throws {
        _ = try CalendarGrantRecord.deleteOne(db, key: accountId)
        _ = try CalendarSourceRecord.filter(Column("accountId") == accountId).deleteAll(db)
    }

    // MARK: Calendars

    /// Mirrors the calendar list. A calendar no longer listed goes with its
    /// events; a kept one keeps its sync token and the user's selection.
    static func replaceCalendars(_ db: Database, accountId: String,
                                 with entries: [GCalendarListEntry]) throws {
        let existing = try CalendarSourceRecord
            .filter(Column("accountId") == accountId).fetchAll(db)
        let byId = Dictionary(existing.map { ($0.calendarId, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = Set(entries.map(\.id))
        for gone in existing where !listed.contains(gone.calendarId) {
            try gone.delete(db)
        }
        for entry in entries {
            let old = byId[entry.id]
            try CalendarSourceRecord(
                accountId: accountId, calendarId: entry.id, summary: entry.summary,
                timeZone: entry.timeZone, isPrimary: entry.primary ?? false,
                accessRole: entry.accessRole,
                isSelected: old?.isSelected ?? (entry.selected ?? (entry.primary ?? false)),
                syncToken: old?.syncToken).save(db)
        }
    }

    // MARK: Events

    /// Applies one sync result. A full sync (no previous token) replaces
    /// every stored event of the calendar; an incremental one upserts and
    /// deletes cancelled events. Unreadable times are dropped.
    static func applySync(_ db: Database, accountId: String, calendarId: String,
                          result: CalendarSyncResult, isFullSync: Bool,
                          fallback: TimeZone = .current) throws {
        guard var source = try CalendarSourceRecord.fetchOne(
            db, key: ["accountId": accountId, "calendarId": calendarId]) else { return }
        let events = CalendarEventRecord.filter(Column("accountId") == accountId
                                                && Column("calendarId") == calendarId)
        if isFullSync { _ = try events.deleteAll(db) }
        let zone = result.calendarTimeZone ?? source.timeZone
        for event in result.events {
            let key: [String: (any DatabaseValueConvertible)?] = [
                "accountId": accountId, "calendarId": calendarId, "eventId": event.id]
            guard event.status != "cancelled",
                  let span = CalendarSpan.from(start: event.start, end: event.end,
                                               calendarTimeZone: zone, fallback: fallback) else {
                _ = try CalendarEventRecord.deleteOne(db, key: key)
                continue
            }
            try CalendarEventRecord(accountId: accountId, calendarId: calendarId,
                                    event: event, span: span).save(db)
        }
        source.syncToken = result.nextSyncToken
        if let zone { source.timeZone = zone }
        try source.update(db)
    }

    /// Google answered 410: the token is gone, so are the stored events.
    static func resetSync(_ db: Database, accountId: String, calendarId: String) throws {
        _ = try CalendarEventRecord.filter(Column("accountId") == accountId
                                           && Column("calendarId") == calendarId).deleteAll(db)
        try db.execute(sql: """
            UPDATE calendarSource SET syncToken = NULL WHERE accountId = ? AND calendarId = ?
            """, arguments: [accountId, calendarId])
    }

    /// Busy events of the selected calendars overlapping `window`, ready
    /// for `CalendarAvailability.check`. Same exclusions as
    /// `CalendarAvailability.busy`.
    static func busy(_ db: Database, accountId: String, overlapping window: DateInterval,
                     excludingUID inviteUID: String?) throws -> [CalendarBusy] {
        let rows = try CalendarEventRecord.fetchAll(db, sql: """
            SELECT e.* FROM calendarEvent e
            JOIN calendarSource s ON s.accountId = e.accountId AND s.calendarId = e.calendarId
            WHERE e.accountId = ? AND s.isSelected = 1
              AND e.endAt >= ? AND e.startAt <= ?
              AND IFNULL(e.status, '') != 'cancelled'
              AND IFNULL(e.transparency, '') != 'transparent'
              AND IFNULL(e.selfResponse, '') != 'declined'
            ORDER BY e.startAt
            """, arguments: [accountId, window.start, window.end])
        return rows.filter { inviteUID == nil || inviteUID == "" || $0.iCalUID != inviteUID }
            .map(\.busy)
    }
}
