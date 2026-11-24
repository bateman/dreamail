import GRDB

/// How mail deletes reach the full-text index (`message_fts`).
///
/// The index deletes securely (migration v49): each deleted message's terms
/// are cut out of the segment that holds them. That costs per deleted
/// message, which is nothing for the few rows a sync pass removes but makes
/// a bulk delete (pruning local mail, removing an account, a mass delete in
/// Gmail) a long write transaction. When it is cheaper, a bulk delete
/// suspends the per-row work for its transaction and rebuilds the index from
/// the messages that remain: `rebuild` drops every index block (zeroed,
/// `secure_delete`) and indexes the remaining rows afresh, so no deleted term
/// can survive it. `optimize` is not used: with the setting switched off and
/// on in one transaction it left deleted terms in the merged segment.
///
/// The setting is stored in the index's config table. It is restored on the
/// way out whatever happens, and checked again every time the database opens
/// (`ensureSecureDelete`).
enum SearchIndexDeletes {
    /// Deleted messages below which the per-row path is always used.
    static let bulkThreshold = 500

    /// Cost of deleting one message securely from the index, in units of the
    /// cost of reindexing one remaining message during a rebuild. Measured in
    /// CI on a 50,000-message raw-keyed file (`SecureDeleteCostTests`,
    /// `MISHMAIL_BENCHMARK=1`).
    static let rebuildCostRatio = 5

    /// Whether deleting `messages` of `total` message rows takes the bulk
    /// path: only when rebuilding what remains costs less than deleting the
    /// rows one by one. Pure, for the tests.
    static func usesBulkPath(deleting messages: Int, of total: Int) -> Bool {
        messages >= bulkThreshold && max(total - messages, 0) < messages * rebuildCostRatio
    }

    /// Runs `body`, which deletes about `messages` message rows, on the
    /// path that suits that many. Must run inside a write transaction.
    static func deleting<T>(_ db: Database, messages: Int, _ body: () throws -> T) throws -> T {
        guard messages >= bulkThreshold else { return try body() }
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0
        guard usesBulkPath(deleting: messages, of: total) else { return try body() }
        try setSecureDelete(db, on: false)
        // Restored even when `body` throws and the caller commits anyway.
        defer { try? setSecureDelete(db, on: true) }
        let result = try body()
        try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        return result
    }

    /// Turns the index's secure-delete back on if it is off. Writes only
    /// then; called at every open.
    static func ensureSecureDelete(_ db: Database) throws {
        guard try db.tableExists("message_fts_config") else { return }
        let value = try Int.fetchOne(db, sql: """
            SELECT v FROM message_fts_config WHERE k = 'secure-delete'
            """)
        if value != 1 { try setSecureDelete(db, on: true) }
    }

    private static func setSecureDelete(_ db: Database, on: Bool) throws {
        try db.execute(
            sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', ?)",
            arguments: [on ? 1 : 0])
    }

    // MARK: Deferred rebuild

    private static let rebuildTask = "searchIndexRebuild"

    /// Asks for a one-time rebuild at the next deferred startup work.
    static func requestRebuild(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pendingMaintenance (task TEXT PRIMARY KEY NOT NULL)
            """)
        try db.execute(sql: "INSERT OR IGNORE INTO pendingMaintenance (task) VALUES (?)",
                       arguments: [rebuildTask])
    }

    static func rebuildIsPending(_ db: Database) throws -> Bool {
        guard try db.tableExists("pendingMaintenance") else { return false }
        return try Bool.fetchOne(db, sql: "SELECT 1 FROM pendingMaintenance WHERE task = ?",
                                 arguments: [rebuildTask]) ?? false
    }

    /// Runs the requested rebuild, if any, and clears the request, in the
    /// caller's transaction: an interrupted rebuild leaves the request.
    static func rebuildIfPending(_ db: Database) throws {
        guard try rebuildIsPending(db) else { return }
        try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        try db.execute(sql: "DELETE FROM pendingMaintenance WHERE task = ?",
                       arguments: [rebuildTask])
    }
}
