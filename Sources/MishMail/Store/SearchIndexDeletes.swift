import GRDB

/// How mail deletes reach the full-text index (`message_fts`).
///
/// The index deletes securely (migration v49): each deleted message's terms
/// are cut out of the segment that holds them, at most of a millisecond per
/// message under SQLCipher. That is nothing for the few rows a sync pass
/// removes, but it turns a bulk delete (pruning local mail, removing an
/// account, a mass delete in Gmail) into a write transaction of many
/// seconds. For those, the per-row work is suspended for the transaction and
/// the index is rebuilt from the messages that remain: `rebuild` drops every
/// index block (zeroed, `secure_delete`) and indexes the remaining rows
/// afresh, so no deleted term can survive it. `optimize` is not used: with
/// the setting switched off and on in one transaction it left deleted terms
/// in the merged segment. The setting is stored in the index's config
/// table, so a rollback restores it with everything else.
enum SearchIndexDeletes {
    /// Deleted messages from which the bulk path may be used.
    static let bulkThreshold = 500

    /// Rebuilding costs per remaining message; deleting securely costs per
    /// deleted message, roughly this many times more. The bulk path is used
    /// only while the rebuild is the cheaper of the two.
    static let rebuildCostRatio = 100

    /// Whether deleting `messages` of `total` message rows takes the bulk
    /// path. Pure, for the tests.
    static func usesBulkPath(deleting messages: Int, of total: Int) -> Bool {
        messages >= bulkThreshold && max(total - messages, 0) <= messages * rebuildCostRatio
    }

    /// Runs `body`, which deletes about `messages` message rows, on the
    /// path that suits that many. Must run inside a write transaction.
    static func deleting<T>(_ db: Database, messages: Int, _ body: () throws -> T) throws -> T {
        guard messages >= bulkThreshold else { return try body() }
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0
        guard usesBulkPath(deleting: messages, of: total) else { return try body() }
        try setSecureDelete(db, on: false)
        let result = try body()
        try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        try setSecureDelete(db, on: true)
        return result
    }

    private static func setSecureDelete(_ db: Database, on: Bool) throws {
        try db.execute(
            sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', ?)",
            arguments: [on ? 1 : 0])
    }
}
