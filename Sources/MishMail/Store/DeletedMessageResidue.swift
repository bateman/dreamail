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

    /// What the app may remove outside the database for `items`: only what
    /// is really gone. A deleted row is not always gone mail: a draft
    /// autosave replaces its row, one message of a thread goes while the
    /// thread stays, a pruned message can be synced again before the drain.
    struct MessageKey: Hashable {
        var accountId: String
        var gmailId: String
    }

    struct ThreadKey: Hashable {
        var accountId: String
        var threadId: String
    }

    struct Removal: Equatable {
        /// Messages no longer in the cache: their attachment copies go.
        var messages: [MessageKey]
        /// Threads with no message left: their notifications go.
        var threads: [ThreadKey]

        var isEmpty: Bool { messages.isEmpty && threads.isEmpty }
    }

    static func removal(_ db: Database, for items: [Item]) throws -> Removal {
        var messages: [MessageKey] = []
        var threads: [ThreadKey] = []
        var seenMessages = Set<MessageKey>()
        var seenThreads = Set<ThreadKey>()
        for item in items {
            let message = MessageKey(accountId: item.accountId, gmailId: item.gmailId)
            if seenMessages.insert(message).inserted,
               // `id` is "<account>:<gmail id>": the primary key, not a scan.
               try !exists(db, "SELECT 1 FROM message WHERE id = ?",
                           ["\(item.accountId):\(item.gmailId)"]) {
                messages.append(message)
            }
            let thread = ThreadKey(accountId: item.accountId, threadId: item.threadId)
            if seenThreads.insert(thread).inserted,
               try !exists(db, "SELECT 1 FROM message WHERE threadId = ?", [item.threadId]) {
                threads.append(thread)
            }
        }
        return Removal(messages: messages, threads: threads)
    }

    private static func exists(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> Bool {
        try Bool.fetchOne(db, sql: sql + " LIMIT 1", arguments: arguments) ?? false
    }

    /// Drops the queued rows of a removed account: the removal deletes its
    /// copies and notifications wholesale, and its address must not stay.
    static func forget(_ db: Database, account accountId: String) throws {
        try db.execute(sql: "DELETE FROM deletedMessage WHERE accountId = ?", arguments: [accountId])
    }

    static func forget(_ db: Database, _ items: [Item]) throws {
        guard let last = items.map(\.queueId).max() else { return }
        try db.execute(sql: "DELETE FROM deletedMessage WHERE id <= ?", arguments: [last])
    }
}
