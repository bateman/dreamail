import Foundation
import GRDB

/// The last answer the user sent to a calendar invite, kept in the
/// encrypted database (it used to live in UserDefaults, a plain-text plist
/// that kept every answered UID after its mail was deleted).
///
/// Key: account, event UID and the RECURRENCE-ID line ("" for the whole
/// event), so one instance of a series is answered on its own. The row
/// names the message the answer was sent from and cascades with it and
/// with the account (DEC-019: deleted means gone, under the same
/// `secure_delete` and WAL scrub as the rest of the mail).
///
/// `sequence` is the invite's SEQUENCE when the user answered: an update
/// with a higher SEQUENCE (new time, new place) asks again, so the old
/// answer is not shown as current for it. Answering an older copy never
/// replaces the answer to a newer one.
///
/// `organizer` is the (lowercased) ORGANIZER the answer went to: a forged
/// invite that reuses a UID under another organizer does not show the
/// earlier answer as its own.
struct CalendarRSVPRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendarRSVP"
    var accountId: String
    var uid: String
    var recurrenceId: String
    var messageId: String
    var status: String
    var sequence: Int
    var organizer: String
}

enum CalendarRSVPStore {
    static func createTable(_ db: Database) throws {
        try db.create(table: CalendarRSVPRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("uid", .text).notNull()
            t.column("recurrenceId", .text).notNull()
            t.column("messageId", .text).notNull().indexed()
                .references("message", onDelete: .cascade)
            t.column("status", .text).notNull()
            t.column("sequence", .integer).notNull()
            t.column("organizer", .text).notNull()
            t.primaryKey(["accountId", "uid", "recurrenceId"])
        }
    }

    /// Records the answer sent for `invite` from `messageId`. Replaces an
    /// earlier answer to the same event (or instance) unless that one was
    /// for a higher SEQUENCE. A key past `CalendarInvite.Limits.maxEchoBytes`
    /// is not stored (such an invite is not answerable anyway).
    static func record(_ db: Database, status: CalendarInvite.RSVP,
                       invite: CalendarInvite, accountId: String,
                       messageId: String) throws {
        let recurrenceId = invite.recurrenceIdLine ?? ""
        let cap = CalendarInvite.Limits.maxEchoBytes
        guard invite.uid.utf8.count <= cap, recurrenceId.utf8.count <= cap else { return }
        try db.execute(sql: """
            INSERT INTO calendarRSVP
                (accountId, uid, recurrenceId, messageId, status, sequence, organizer)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accountId, uid, recurrenceId) DO UPDATE SET
                messageId = excluded.messageId,
                status = excluded.status,
                sequence = excluded.sequence,
                organizer = excluded.organizer
            WHERE excluded.sequence >= calendarRSVP.sequence
            """, arguments: [
                accountId, invite.uid, recurrenceId, messageId, status.rawValue,
                min(max(invite.sequence, 0), CalendarInvite.Limits.maxSequence),
                invite.organizerEmail.lowercased(),
            ])
    }

    /// The answer to show for `invite`: nil when none was sent, when it was
    /// sent for an older SEQUENCE than this invite's, or to another
    /// organizer.
    static func current(_ db: Database, invite: CalendarInvite,
                        accountId: String) throws -> CalendarInvite.RSVP? {
        guard let row = try CalendarRSVPRecord.fetchOne(db, key: [
            "accountId": accountId, "uid": invite.uid,
            "recurrenceId": invite.recurrenceIdLine ?? "",
        ]) else { return nil }
        guard row.sequence >= invite.sequence,
              row.organizer == invite.organizerEmail.lowercased() else { return nil }
        return CalendarInvite.RSVP(rawValue: row.status)
    }

    /// Account removal deletes its answers by name too (they also cascade).
    static func forget(_ db: Database, account: String) throws {
        try db.execute(sql: "DELETE FROM calendarRSVP WHERE accountId = ?",
                       arguments: [account])
    }

    /// Rows whose message or account is gone (left by a write with foreign
    /// keys off): the launch sweep deletes them.
    static func purgeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM calendarRSVP
            WHERE messageId NOT IN (SELECT id FROM message)
               OR accountId NOT IN (SELECT id FROM account)
            """)
    }

    /// Prefix of the answers earlier builds kept in UserDefaults
    /// (`CalendarInvite.rsvpDefaultsKey`).
    static let legacyDefaultsPrefix = "calendar.rsvp."

    /// Deletes every answer earlier builds kept in UserDefaults. They are
    /// not carried over: they name no message, so they could not follow
    /// its deletion. An answered invite only shows its buttons unselected.
    static func purgeLegacyDefaults(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(legacyDefaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
