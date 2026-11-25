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

/// A calendar the user chose to count for availability and conflicts.
/// Only chosen calendars are stored; the full list is read from Google
/// when the user changes the choice. The primary one is chosen by default.
struct CalendarSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarSource"
    var accountId: String
    var calendarId: String
    var summary: String?
    var timeZone: String?
    var isPrimary: Bool
    /// "freeBusyReader" | "reader" | "writer" | "owner": decides whether
    /// its events can be read or only its busy periods.
    var accessRole: String?
    /// Unused in this release (no agenda): where an incremental sync
    /// would resume, kept so a later agenda needs no schema change.
    var syncToken: String?

    init(accountId: String, entry: GCalendarListEntry) {
        self.accountId = accountId
        self.calendarId = entry.id
        self.summary = entry.summary
        self.timeZone = entry.timeZone
        self.isPrimary = entry.primary ?? false
        self.accessRole = entry.accessRole
        self.syncToken = nil
    }

    /// Event details (and so the invitation's own UID) are readable; a
    /// free/busy-only calendar gives busy periods.
    var canReadEvents: Bool { accessRole != "freeBusyReader" }
}

/// Where the event of one invitation message is in the user's Google
/// Calendar, and the user's answer there. One row per message; it goes
/// with the message (and so with its thread and account).
struct CalendarInviteEventRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarInviteEvent"
    var messageId: String
    var accountId: String
    var calendarId: String
    var eventId: String
    var iCalUID: String
    /// "needsAction" | "accepted" | "declined" | "tentative", as Google has it.
    var selfResponse: String?
    var checkedAt: Date
}

/// The Calendar tables (migration v61) and their writes. Everything
/// cascades from `account`, invitation events also from their `message`,
/// so removing an account, a message or its thread, or disconnecting
/// Calendar leaves nothing behind; the database's `secure_delete` and WAL
/// scrub (`DeletionObserver`) then overwrite the deleted rows (DEC-019).
/// No event of the agenda is stored: availability is computed in memory.
/// Nothing here talks to Google.
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
            t.column("syncToken", .text)
            t.primaryKey(["accountId", "calendarId"])
        }
        try db.create(table: CalendarInviteEventRecord.databaseTableName) { t in
            t.primaryKey("messageId", .text)
                .references("message", onDelete: .cascade)
            t.column("accountId", .text).notNull().indexed()
                .references("account", onDelete: .cascade)
            t.column("calendarId", .text).notNull()
            t.column("eventId", .text).notNull()
            t.column("iCalUID", .text).notNull()
            t.column("selfResponse", .text)
            t.column("checkedAt", .datetime).notNull()
        }
    }

    // MARK: Grant

    /// A new grant. The first one also chooses the primary calendar.
    static func saveGrant(_ db: Database, accountId: String, scopes: String, at date: Date,
                          calendars: [GCalendarListEntry] = []) throws {
        let first = try CalendarGrantRecord.fetchOne(db, key: accountId) == nil
        try CalendarGrantRecord(accountId: accountId, scopes: scopes, grantedAt: date).save(db)
        if first, try chosenCalendars(db, accountId: accountId).isEmpty {
            try setChosenCalendars(db, accountId: accountId, defaultChoice(from: calendars))
        }
    }

    static func grant(_ db: Database, accountId: String) throws -> CalendarGrant? {
        try CalendarGrantRecord.fetchOne(db, key: accountId)?.grant
    }

    /// The user disconnected Calendar (or Google refused the grant): the
    /// grant, the chosen calendars and the invitation events of the account
    /// go. The caller deletes the Keychain token.
    static func forget(_ db: Database, accountId: String) throws {
        _ = try CalendarGrantRecord.deleteOne(db, key: accountId)
        _ = try CalendarSourceRecord.filter(Column("accountId") == accountId).deleteAll(db)
        _ = try CalendarInviteEventRecord.filter(Column("accountId") == accountId).deleteAll(db)
    }

    // MARK: Chosen calendars

    /// The primary calendar; with no primary in the list, the calendar the
    /// API calls "primary" (always the user's own).
    static func defaultChoice(from list: [GCalendarListEntry]) -> [GCalendarListEntry] {
        let primary = list.filter { $0.primary == true }
        return primary.isEmpty
            ? [GCalendarListEntry(id: "primary", summary: nil, timeZone: nil, primary: true,
                                  accessRole: "owner", selected: true)]
            : primary
    }

    static func chosenCalendars(_ db: Database, accountId: String) throws -> [CalendarSourceRecord] {
        try CalendarSourceRecord.filter(Column("accountId") == accountId)
            .order(Column("isPrimary").desc, Column("calendarId")).fetchAll(db)
    }

    /// Replaces the user's choice. Any calendar the user can see may count,
    /// read-only, shared and subscribed ones included.
    static func setChosenCalendars(_ db: Database, accountId: String,
                                   _ entries: [GCalendarListEntry]) throws {
        _ = try CalendarSourceRecord.filter(Column("accountId") == accountId).deleteAll(db)
        for entry in entries {
            try CalendarSourceRecord(accountId: accountId, entry: entry).save(db)
        }
    }

    /// After reading the calendar list again: a chosen calendar that is no
    /// longer listed (unsubscribed, deleted) stops counting; the others get
    /// their current name, zone and access.
    static func reconcileChosenCalendars(_ db: Database, accountId: String,
                                         with list: [GCalendarListEntry]) throws {
        let listed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for var chosen in try chosenCalendars(db, accountId: accountId) {
            // "primary" is the API's alias for the user's own calendar.
            if let entry = listed[chosen.calendarId] {
                chosen.summary = entry.summary
                chosen.timeZone = entry.timeZone
                chosen.accessRole = entry.accessRole
                try chosen.update(db)
            } else if chosen.calendarId != "primary" {
                try chosen.delete(db)
            }
        }
    }

    // MARK: Invitation events

    static func saveInviteEvent(_ db: Database, _ record: CalendarInviteEventRecord) throws {
        try record.save(db)
    }

    static func inviteEvent(_ db: Database, messageId: String) throws -> CalendarInviteEventRecord? {
        try CalendarInviteEventRecord.fetchOne(db, key: messageId)
    }

    /// The event was not (or no longer) found in Google Calendar.
    static func forgetInviteEvent(_ db: Database, messageId: String) throws {
        _ = try CalendarInviteEventRecord.deleteOne(db, key: messageId)
    }
}
