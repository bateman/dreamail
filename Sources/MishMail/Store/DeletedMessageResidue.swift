import GRDB

/// Messages deleted from the cache whose copies outside it (attachment
/// copies in the temp cache, delivered notifications) still have to go.
///
/// A trigger on `message` queues the ids of every deleted row, whatever
/// deleted it: a sync pass, a local prune, a discarded draft, an account
/// removal's cascade. The scrub that follows a deletion hands the queue to
/// the app (`AppDatabase.deletedMessageHandler`) and then empties it. Only
/// ids are queued, never content, and the rows themselves are deleted
/// securely like any other.
enum DeletedMessageResidue {
    struct Item: Equatable {
        var queueId: Int64
        var accountId: String
        var gmailId: String
        var threadId: String
    }

    static let batchSize = 500

    static func createQueue(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE deletedMessage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                accountId TEXT NOT NULL,
                gmailId TEXT NOT NULL,
                threadId TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER deletedMessage_queue AFTER DELETE ON message
            BEGIN
                INSERT INTO deletedMessage (accountId, gmailId, threadId)
                VALUES (old.accountId, old.gmailId, old.threadId);
            END
            """)
    }

    static func pending(_ db: Database, limit: Int = batchSize) throws -> [Item] {
        try Row.fetchAll(db, sql: """
            SELECT id, accountId, gmailId, threadId FROM deletedMessage
            ORDER BY id LIMIT ?
            """, arguments: [limit]).map {
            Item(queueId: $0["id"], accountId: $0["accountId"],
                 gmailId: $0["gmailId"], threadId: $0["threadId"])
        }
    }

    static func forget(_ db: Database, _ items: [Item]) throws {
        guard let last = items.map(\.queueId).max() else { return }
        try db.execute(sql: "DELETE FROM deletedMessage WHERE id <= ?", arguments: [last])
    }
}
